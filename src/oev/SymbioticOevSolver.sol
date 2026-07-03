// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.28;

import {DISCOUNT_PRECISION, ILiquidLaneAdapter} from "../interfaces/ILiquidLaneAdapter.sol";
import {IOperationCallback} from "./interfaces/IOperationCallback.sol";
import {
    IIrm,
    IOracle,
    Id,
    IMorpho,
    IMorphoLiquidateCallback,
    Market,
    MarketParams,
    Position
} from "./interfaces/IMorpho.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IOevLiquidLaneAdapter is ILiquidLaneAdapter {
    function minDiscount(address tokenToRedeem) external view returns (uint256 ppm);
    function getMaxAssets(address tokenToRedeem) external returns (uint256 amount);
    function getAmountOut(address tokenToRedeem, uint256 amountIn) external view returns (uint256 amountOut);
}

/// @title SymbioticOevSolver
/// @notice RedStone OEV callback that liquidates Morpho Blue positions and exits seized collateral through a
///         Symbiotic LiquidLane adapter.
contract SymbioticOevSolver is IOperationCallback, IMorphoLiquidateCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* ERRORS */

    error InvalidAuth();
    error NotExecutor();
    error NotMorpho();
    error NotOwner();
    error TransferFailed();

    /* CONSTANTS */

    uint256 internal constant WAD = 1e18;
    uint256 internal constant ORACLE_PRICE_SCALE = 1e36;
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;
    uint256 internal constant LIQUIDATION_CURSOR = 0.3e18;
    uint256 internal constant MAX_LIQUIDATION_INCENTIVE_FACTOR = 1.15e18;

    bytes32 internal constant AUTH_DOMAIN = keccak256("SYMBIOTIC_OEV_AUTH_V1");

    uint8 internal constant STATUS_SUCCESS = 1;
    uint8 internal constant STATUS_SKIPPED = 2;
    uint8 internal constant STATUS_REVERTED = 3;

    uint8 internal constant REASON_NONE = 0;
    uint8 internal constant REASON_NO_DEBT = 1;
    uint8 internal constant REASON_HEALTHY = 2;
    uint8 internal constant REASON_NO_SEIZE = 3;
    uint8 internal constant REASON_NO_LIQUIDITY = 4;
    uint8 internal constant REASON_PROFIT_BELOW_MIN = 5;
    uint8 internal constant REASON_PREVIEW_REVERT = 6;
    uint8 internal constant REASON_MORPHO_REVERT = 7;

    /* IMMUTABLES */

    /// @notice RedStone's on-chain Executor. The only authorized caller of `liquidate` / `payBid`.
    address public immutable EXECUTOR;
    /// @notice Morpho Blue lending market.
    address public immutable MORPHO;
    /// @notice Symbiotic LiquidLane adapter used as the RWA exit venue.
    address public immutable LIQUID_LANE_ADAPTER;
    /// @notice Signer that authorizes callback operationData in addition to RedStone's executor signature.
    address public immutable AUTH_SIGNER;

    /* STATE */

    address public owner;
    mapping(bytes32 auctionKey => bool used) public usedAuctionKey;

    bytes32 private payBidAuctionKey;
    uint256 private authorizedBidAmount;
    bool private payBidReady;

    uint256 private lastLegProfit;

    /* EVENTS */

    event LegResult(
        bytes32 indexed auctionKey,
        Id indexed marketId,
        address indexed borrower,
        uint256 code,
        uint256 seizedAssets,
        uint256 repaidAssets,
        uint256 profitLoan
    );
    event PayBidResult(bytes32 indexed auctionKey, uint256 bidAmount, bool paid);
    event OwnerUpdated(address indexed previous, address indexed next);

    /* STRUCTS */

    struct OperationData {
        Auth auth;
        LiquidationLeg[] legs;
        bytes authSig;
    }

    struct Auth {
        bytes32 auctionKey;
        uint256 bidAmount;
        uint256 loanPerEth;
    }

    struct LiquidationLeg {
        Id marketId;
        address borrower;
        uint256 maxSeizeAssets;
        uint32 gasUnits;
    }

    struct CallbackContext {
        address loanToken;
        address collateralToken;
        uint256 seizedAssets;
        uint256 loanPerEth;
        uint32 gasUnits;
    }

    struct Preview {
        MarketParams params;
        Position position;
        uint256 price;
        uint256 seizedAssets;
        uint256 repaidAssets;
        uint256 amountOut;
        uint256 minProfit;
        uint8 status;
        uint8 reason;
    }

    /* MODIFIERS */

    modifier onlyExecutor() {
        if (msg.sender != EXECUTOR) revert NotExecutor();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) revert InvalidAuth();
        _;
    }

    /* CONSTRUCTOR */

    constructor(address executor, address morpho, address liquidLaneAdapter, address authSigner, address initialOwner) {
        EXECUTOR = executor;
        MORPHO = morpho;
        LIQUID_LANE_ADAPTER = liquidLaneAdapter;
        AUTH_SIGNER = authSigner;
        owner = initialOwner;
        emit OwnerUpdated(address(0), initialOwner);
    }

    /* RECEIVE */

    receive() external payable {}

    /* IOperationCallback */

    /// @inheritdoc IOperationCallback
    function liquidate(uint256 bidAmount, address, bytes calldata operationData) external onlyExecutor {
        OperationData memory op = abi.decode(operationData, (OperationData));
        _authorize(op, bidAmount);

        usedAuctionKey[op.auth.auctionKey] = true;
        payBidAuctionKey = op.auth.auctionKey;
        authorizedBidAmount = bidAmount;
        payBidReady = true;

        for (uint256 i; i < op.legs.length; ++i) {
            _runLeg(op.auth, op.legs[i], i);
        }
    }

    /// @inheritdoc IOperationCallback
    function payBid(uint256 bidAmount) external onlyExecutor {
        bytes32 auctionKey = payBidAuctionKey;
        bool pay = payBidReady && bidAmount == authorizedBidAmount;
        payBidReady = false;
        authorizedBidAmount = 0;
        payBidAuctionKey = bytes32(0);

        if (!pay) {
            emit PayBidResult(auctionKey, bidAmount, false);
            return;
        }

        (bool ok,) = payable(msg.sender).call{value: bidAmount}("");
        if (!ok) revert TransferFailed();
        emit PayBidResult(auctionKey, bidAmount, true);
    }

    /* IMorphoLiquidateCallback */

    /// @inheritdoc IMorphoLiquidateCallback
    function onMorphoLiquidate(uint256 repaidAssets, bytes calldata data) external nonReentrant {
        if (msg.sender != MORPHO) revert NotMorpho();
        CallbackContext memory ctx = abi.decode(data, (CallbackContext));

        uint256 seizedBalance = IERC20(ctx.collateralToken).balanceOf(address(this));
        if (seizedBalance < ctx.seizedAssets) revert TransferFailed();
        uint256 loanBefore = IERC20(ctx.loanToken).balanceOf(address(this));

        IERC20(ctx.collateralToken).safeTransfer(LIQUID_LANE_ADAPTER, ctx.seizedAssets);

        uint256 amountOut = _adapterOut(ctx.collateralToken, ctx.seizedAssets);
        ILiquidLaneAdapter(LIQUID_LANE_ADAPTER)
            .swap(
                ILiquidLaneAdapter.Swap({
                    recipient: address(this),
                    tokenIn: ctx.collateralToken,
                    amountIn: ctx.seizedAssets,
                    amountOut: amountOut
                })
            );

        uint256 gained = IERC20(ctx.loanToken).balanceOf(address(this)) - loanBefore;
        uint256 minProfit = _nativeToLoanUp(uint256(ctx.gasUnits) * tx.gasprice, ctx.loanPerEth);
        if (gained < repaidAssets + minProfit) revert TransferFailed();

        lastLegProfit = gained - repaidAssets;
        IERC20(ctx.loanToken).forceApprove(MORPHO, repaidAssets);
    }

    /* PREVIEW */

    function previewLeg(Auth calldata auth, LiquidationLeg calldata leg) external onlySelf returns (Preview memory p) {
        p.params = IMorpho(MORPHO).idToMarketParams(leg.marketId);
        p.position = IMorpho(MORPHO).position(leg.marketId, leg.borrower);
        if (p.position.borrowShares == 0) return _skip(p, REASON_NO_DEBT);
        if (p.position.collateral == 0 || leg.maxSeizeAssets == 0) return _skip(p, REASON_NO_SEIZE);

        p.price = IOracle(p.params.oracle).price();
        if (p.price == 0) return _skip(p, REASON_HEALTHY);

        Market memory market = _accruedMarket(p.params, IMorpho(MORPHO).market(leg.marketId));
        if (_isHealthy(p.position, market, p.params.lltv, p.price)) return _skip(p, REASON_HEALTHY);

        uint256 seize = _min(leg.maxSeizeAssets, uint256(p.position.collateral));
        uint256 maxForDebt =
            _maxSeizeForDebt(p.position.borrowShares, p.price, _liquidationIncentiveFactor(p.params.lltv), market);
        seize = _min(seize, maxForDebt);
        if (seize == 0) return _skip(p, REASON_NO_SEIZE);

        uint256 amountOut = _adapterOut(p.params.collateralToken, seize);
        uint256 maxAssets = IOevLiquidLaneAdapter(LIQUID_LANE_ADAPTER).getMaxAssets(p.params.collateralToken);
        if (maxAssets == 0) return _skip(p, REASON_NO_LIQUIDITY);
        if (amountOut > maxAssets) {
            seize = Math.mulDiv(seize, maxAssets, amountOut);
            if (seize == 0) return _skip(p, REASON_NO_LIQUIDITY);
            amountOut = _adapterOut(p.params.collateralToken, seize);
        }

        p.repaidAssets = _repaidAssetsForSeize(seize, p.price, _liquidationIncentiveFactor(p.params.lltv), market);
        p.minProfit = _nativeToLoanUp(uint256(leg.gasUnits) * tx.gasprice, auth.loanPerEth);
        if (amountOut < p.repaidAssets + p.minProfit) return _skip(p, REASON_PROFIT_BELOW_MIN);

        p.seizedAssets = seize;
        p.amountOut = amountOut;
        p.status = STATUS_SUCCESS;
        p.reason = REASON_NONE;
    }

    /* OWNER */

    function withdrawERC20(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
    }

    function withdrawNative(address to, uint256 amount) external onlyOwner {
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    function transferOwnership(address newOwner) external onlyOwner {
        emit OwnerUpdated(owner, newOwner);
        owner = newOwner;
    }

    /* INTERNAL */

    function _authorize(OperationData memory op, uint256 bidAmount) internal view {
        if (op.auth.bidAmount != bidAmount || op.auth.loanPerEth == 0 || usedAuctionKey[op.auth.auctionKey]) {
            revert InvalidAuth();
        }
        bytes32 legsHash = keccak256(abi.encode(op.legs));
        bytes32 digest = _authDigest(op.auth, legsHash);
        if (ECDSA.recover(digest, op.authSig) != AUTH_SIGNER) revert InvalidAuth();
    }

    function _authDigest(Auth memory auth, bytes32 legsHash) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                AUTH_DOMAIN,
                block.chainid,
                address(this),
                EXECUTOR,
                auth.auctionKey,
                auth.bidAmount,
                auth.loanPerEth,
                legsHash
            )
        );
    }

    function _runLeg(Auth memory auth, LiquidationLeg memory leg, uint256 index) internal {
        Preview memory p;
        try this.previewLeg(auth, leg) returns (Preview memory preview) {
            p = preview;
        } catch (bytes memory err) {
            emit LegResult(
                auth.auctionKey,
                leg.marketId,
                leg.borrower,
                _code(index, STATUS_REVERTED, REASON_PREVIEW_REVERT, _selector(err)),
                0,
                0,
                0
            );
            return;
        }

        if (p.status != STATUS_SUCCESS) {
            emit LegResult(
                auth.auctionKey,
                leg.marketId,
                leg.borrower,
                _code(index, STATUS_SKIPPED, p.reason, bytes4(0)),
                p.seizedAssets,
                p.repaidAssets,
                0
            );
            return;
        }

        lastLegProfit = 0;
        bytes memory cbData = abi.encode(
            CallbackContext({
                loanToken: p.params.loanToken,
                collateralToken: p.params.collateralToken,
                seizedAssets: p.seizedAssets,
                loanPerEth: auth.loanPerEth,
                gasUnits: leg.gasUnits
            })
        );
        bytes memory callData =
            abi.encodeCall(IMorpho.liquidate, (p.params, leg.borrower, p.seizedAssets, uint256(0), cbData));
        (bool ok, bytes memory ret) = MORPHO.call(callData);
        if (!ok) {
            emit LegResult(
                auth.auctionKey,
                leg.marketId,
                leg.borrower,
                _code(index, STATUS_REVERTED, REASON_MORPHO_REVERT, _selector(ret)),
                0,
                0,
                0
            );
            return;
        }
        (uint256 seizedAssets, uint256 repaidAssets) = abi.decode(ret, (uint256, uint256));
        emit LegResult(
            auth.auctionKey,
            leg.marketId,
            leg.borrower,
            _code(index, STATUS_SUCCESS, REASON_NONE, bytes4(0)),
            seizedAssets,
            repaidAssets,
            lastLegProfit
        );
    }

    function _skip(Preview memory p, uint8 reason) internal pure returns (Preview memory) {
        p.status = STATUS_SKIPPED;
        p.reason = reason;
        return p;
    }

    function _adapterOut(address collateralToken, uint256 seizedAssets) internal view returns (uint256 amountOut) {
        uint256 raw = IOevLiquidLaneAdapter(LIQUID_LANE_ADAPTER).getAmountOut(collateralToken, seizedAssets);
        uint256 discount = IOevLiquidLaneAdapter(LIQUID_LANE_ADAPTER).minDiscount(collateralToken);
        return Math.mulDiv(raw, DISCOUNT_PRECISION - discount, DISCOUNT_PRECISION);
    }

    function _accruedMarket(MarketParams memory params, Market memory market) internal view returns (Market memory) {
        uint256 elapsed = block.timestamp - market.lastUpdate;
        if (elapsed == 0 || params.irm == address(0)) return market;
        uint256 borrowRate = IIrm(params.irm).borrowRateView(params, market);
        uint256 interest = _wMulDown(market.totalBorrowAssets, _wTaylorCompounded(borrowRate, elapsed));
        market.totalBorrowAssets += uint128(interest);
        market.totalSupplyAssets += uint128(interest);
        return market;
    }

    function _isHealthy(Position memory position, Market memory market, uint256 lltv, uint256 price)
        internal
        pure
        returns (bool)
    {
        uint256 borrowed = _toAssetsUp(position.borrowShares, market.totalBorrowAssets, market.totalBorrowShares);
        uint256 maxBorrow = _wMulDown(Math.mulDiv(position.collateral, price, ORACLE_PRICE_SCALE), lltv);
        return maxBorrow >= borrowed;
    }

    function _liquidationIncentiveFactor(uint256 lltv) internal pure returns (uint256) {
        uint256 denom = WAD - _wMulDown(LIQUIDATION_CURSOR, WAD - lltv);
        uint256 lif = _wDivDown(WAD, denom);
        return _min(lif, MAX_LIQUIDATION_INCENTIVE_FACTOR);
    }

    function _repaidAssetsForSeize(uint256 seizedAssets, uint256 price, uint256 lif, Market memory market)
        internal
        pure
        returns (uint256)
    {
        uint256 seizedQuoted = Math.mulDiv(seizedAssets, price, ORACLE_PRICE_SCALE, Math.Rounding.Ceil);
        uint256 repaidShares =
            _toSharesUp(_wDivUp(seizedQuoted, lif), market.totalBorrowAssets, market.totalBorrowShares);
        return _toAssetsUp(repaidShares, market.totalBorrowAssets, market.totalBorrowShares);
    }

    function _maxSeizeForDebt(uint256 borrowShares, uint256 price, uint256 lif, Market memory market)
        internal
        pure
        returns (uint256)
    {
        uint256 debtAssets = _toAssetsDown(borrowShares, market.totalBorrowAssets, market.totalBorrowShares);
        return Math.mulDiv(_wMulDown(debtAssets, lif), ORACLE_PRICE_SCALE, price);
    }

    function _nativeToLoanUp(uint256 nativeAmount, uint256 loanPerEth) internal pure returns (uint256) {
        return Math.mulDiv(nativeAmount, loanPerEth, WAD, Math.Rounding.Ceil);
    }

    function _toSharesUp(uint256 assets, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return Math.mulDiv(assets, totalShares + VIRTUAL_SHARES, totalAssets + VIRTUAL_ASSETS, Math.Rounding.Ceil);
    }

    function _toAssetsDown(uint256 shares, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return Math.mulDiv(shares, totalAssets + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES);
    }

    function _toAssetsUp(uint256 shares, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return Math.mulDiv(shares, totalAssets + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES, Math.Rounding.Ceil);
    }

    function _wMulDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return Math.mulDiv(x, y, WAD);
    }

    function _wDivDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return Math.mulDiv(x, WAD, y);
    }

    function _wDivUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return Math.mulDiv(x, WAD, y, Math.Rounding.Ceil);
    }

    function _wTaylorCompounded(uint256 x, uint256 n) internal pure returns (uint256) {
        uint256 firstTerm = x * n;
        uint256 secondTerm = Math.mulDiv(firstTerm, firstTerm, 2 * WAD);
        uint256 thirdTerm = Math.mulDiv(secondTerm, firstTerm, 3 * WAD);
        return firstTerm + secondTerm + thirdTerm;
    }

    function _code(uint256 index, uint8 status, uint8 reason, bytes4 selector) internal pure returns (uint256) {
        return (uint256(uint32(selector)) << 224) | (index << 16) | (uint256(status) << 8) | reason;
    }

    function _selector(bytes memory ret) internal pure returns (bytes4 selector) {
        if (ret.length >= 4) {
            assembly ("memory-safe") {
                selector := mload(add(ret, 32))
            }
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
