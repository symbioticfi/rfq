// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.28;

import {DISCOUNT_PRECISION, ILiquidLaneAdapter} from "../interfaces/ILiquidLaneAdapter.sol";
import {IOperationCallback} from "./interfaces/IOperationCallback.sol";
import {Id, IMorpho, IMorphoLiquidateCallback, MarketParams, Position} from "./interfaces/IMorpho.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IOevLiquidLaneAdapter is ILiquidLaneAdapter {
    function minDiscount(address tokenToRedeem) external view returns (uint256 ppm);
    function getAmountOut(address tokenToRedeem, uint256 amountIn) external view returns (uint256 amountOut);
    function getMaxAssets(address tokenToRedeem) external returns (uint256 assets);
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
    error InsufficientLoanProceeds();
    error ProfitBelowMin();
    error SwapOutputBelowMin();
    error TransferFailed();
    error ZeroAddress();

    /* CONSTANTS */

    bytes32 internal constant AUTH_DOMAIN = keccak256("SYMBIOTIC_OEV_AUTH_V1");

    uint8 internal constant STATUS_SUCCESS = 1;
    uint8 internal constant STATUS_SKIPPED = 2;
    uint8 internal constant STATUS_REVERTED = 3;

    uint8 internal constant REASON_NONE = 0;
    uint8 internal constant REASON_SWAP_OUTPUT_BELOW_MIN = 1;
    uint8 internal constant REASON_INSUFFICIENT_LOAN_PROCEEDS = 2;
    uint8 internal constant REASON_PROFIT_BELOW_MIN = 3;
    uint8 internal constant REASON_MORPHO_REVERT = 4;
    uint8 internal constant REASON_NO_COLLATERAL = 5;

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

    uint256 private transient lastLegProfit;

    /* EVENTS */

    event LegResult(
        bytes32 indexed auctionKey,
        Id indexed marketId,
        address indexed borrower,
        uint256 code,
        uint256 seizedAssets,
        uint256 repaidAssets,
        uint256 profitLoan,
        uint256 gasUsed
    );
    event BundleResult(
        bytes32 indexed auctionKey, uint256 totalProfitLoan, uint256 minProfitLoan, uint256 gasUsed, bool bidAuthorized
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
        uint256 minBundleProfit;
        uint256 deadline;
    }

    struct LiquidationLeg {
        Id marketId;
        address borrower;
        uint256 maxSeizeAssets;
        uint256 minProfit;
    }

    struct CallbackContext {
        address loanToken;
        address collateralToken;
        uint256 seizedAssets;
        uint256 minProfit;
    }

    struct LegOutcome {
        uint256 code;
        uint256 seizedAssets;
        uint256 repaidAssets;
        uint256 profitLoan;
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

    /* CONSTRUCTOR */

    constructor(address executor, address morpho, address liquidLaneAdapter, address authSigner, address initialOwner) {
        if (
            executor == address(0) || morpho == address(0) || liquidLaneAdapter == address(0)
                || authSigner == address(0) || initialOwner == address(0)
        ) revert ZeroAddress();
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
        uint256 startGas = gasleft();
        OperationData memory op = abi.decode(operationData, (OperationData));
        _authorize(op, bidAmount);

        payBidReady = false;
        authorizedBidAmount = 0;
        payBidAuctionKey = bytes32(0);
        usedAuctionKey[op.auth.auctionKey] = true;
        uint256 totalProfit = _settleLegs(op.auth.auctionKey, op.legs);
        // Intentionally authorize the bid only if the settled bundle clears the signed floor. This protects
        // against callback/accounting bugs; operators can reconcile partner bids manually if needed.
        bool bidAuthorized = totalProfit >= op.auth.minBundleProfit && address(this).balance >= bidAmount;
        emit BundleResult(op.auth.auctionKey, totalProfit, op.auth.minBundleProfit, startGas - gasleft(), bidAuthorized);
        if (!bidAuthorized) return;

        payBidAuctionKey = op.auth.auctionKey;
        authorizedBidAmount = bidAmount;
        payBidReady = true;
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
        emit PayBidResult(auctionKey, bidAmount, ok);
    }

    /* IMorphoLiquidateCallback */

    /// @inheritdoc IMorphoLiquidateCallback
    function onMorphoLiquidate(uint256 repaidAssets, bytes calldata data) external nonReentrant {
        if (msg.sender != MORPHO) revert NotMorpho();
        CallbackContext memory ctx = abi.decode(data, (CallbackContext));

        uint256 seizedBalance = IERC20(ctx.collateralToken).balanceOf(address(this));
        if (seizedBalance < ctx.seizedAssets) revert TransferFailed();

        uint256 amountOut = _adapterOut(ctx);
        uint256 minLoanOut = repaidAssets + ctx.minProfit;
        if (amountOut < minLoanOut) revert SwapOutputBelowMin();

        uint256 loanBefore = IERC20(ctx.loanToken).balanceOf(address(this));
        IERC20(ctx.collateralToken).safeTransfer(LIQUID_LANE_ADAPTER, ctx.seizedAssets);

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
        if (gained < repaidAssets) revert InsufficientLoanProceeds();

        uint256 profit = gained - repaidAssets;
        if (profit < ctx.minProfit) revert ProfitBelowMin();

        lastLegProfit = profit;
        IERC20(ctx.loanToken).forceApprove(MORPHO, repaidAssets);
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
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnerUpdated(owner, newOwner);
        owner = newOwner;
    }

    /* INTERNAL */

    function _authorize(OperationData memory op, uint256 bidAmount) internal view {
        if (
            op.auth.bidAmount != bidAmount || op.auth.minBundleProfit == 0 || block.timestamp > op.auth.deadline
                || usedAuctionKey[op.auth.auctionKey]
        ) {
            revert InvalidAuth();
        }
        bytes32 legsHash = keccak256(abi.encode(op.legs));
        bytes32 digest = _authDigest(op.auth, legsHash);
        if (!SignatureChecker.isValidSignatureNow(AUTH_SIGNER, digest, op.authSig)) revert InvalidAuth();
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
                auth.minBundleProfit,
                auth.deadline,
                legsHash
            )
        );
    }

    function _settleLegs(bytes32 auctionKey, LiquidationLeg[] memory legs) internal returns (uint256 totalProfit) {
        for (uint256 i; i < legs.length; ++i) {
            uint256 startGas = gasleft();
            LegOutcome memory outcome = _runLeg(legs[i], i);
            uint256 usedGas = startGas - gasleft();
            emit LegResult(
                auctionKey,
                legs[i].marketId,
                legs[i].borrower,
                outcome.code,
                outcome.seizedAssets,
                outcome.repaidAssets,
                outcome.profitLoan,
                usedGas
            );
            totalProfit += outcome.profitLoan;
        }
    }

    function _runLeg(LiquidationLeg memory leg, uint256 index) internal returns (LegOutcome memory outcome) {
        MarketParams memory params = IMorpho(MORPHO).idToMarketParams(leg.marketId);
        uint256 seizeAssets = _clampedSeizeAssets(leg);
        if (seizeAssets == 0) {
            return LegOutcome({
                code: _code(index, STATUS_SKIPPED, REASON_NO_COLLATERAL, bytes4(0)),
                seizedAssets: 0,
                repaidAssets: 0,
                profitLoan: 0
            });
        }
        lastLegProfit = 0;
        bytes memory cbData = abi.encode(
            CallbackContext({
                loanToken: params.loanToken,
                collateralToken: params.collateralToken,
                seizedAssets: seizeAssets,
                minProfit: leg.minProfit
            })
        );
        try IMorpho(MORPHO).liquidate(params, leg.borrower, seizeAssets, 0, cbData) returns (
            uint256 seizedAssets, uint256 repaidAssets
        ) {
            return LegOutcome({
                code: _code(index, STATUS_SUCCESS, REASON_NONE, bytes4(0)),
                seizedAssets: seizedAssets,
                repaidAssets: repaidAssets,
                profitLoan: lastLegProfit
            });
        } catch (bytes memory err) {
            (uint8 status, uint8 reason) = _failureCode(err);
            return LegOutcome({
                code: _code(index, status, reason, _selector(err)), seizedAssets: 0, repaidAssets: 0, profitLoan: 0
            });
        }
    }

    function _clampedSeizeAssets(LiquidationLeg memory leg) internal view returns (uint256) {
        Position memory current = IMorpho(MORPHO).position(leg.marketId, leg.borrower);
        // Cheap compromise: clamp by live collateral so a stale signed exact seize can still partially fill
        // after another liquidation. This is intentionally not full Morpho debt replay; over-repay and health
        // drift are still left to Morpho and caught fail-soft by the leg try/catch.
        return Math.min(leg.maxSeizeAssets, current.collateral);
    }

    function _adapterOut(CallbackContext memory ctx) internal returns (uint256 amountOut) {
        uint256 rateOut = _adapterRateOut(ctx.collateralToken, ctx.seizedAssets);
        uint256 maxAssets = IOevLiquidLaneAdapter(LIQUID_LANE_ADAPTER).getMaxAssets(ctx.collateralToken);
        return Math.min(rateOut, maxAssets);
    }

    function _adapterRateOut(address collateralToken, uint256 seizedAssets) internal view returns (uint256 amountOut) {
        uint256 raw = IOevLiquidLaneAdapter(LIQUID_LANE_ADAPTER).getAmountOut(collateralToken, seizedAssets);
        uint256 discount = IOevLiquidLaneAdapter(LIQUID_LANE_ADAPTER).minDiscount(collateralToken);
        return Math.mulDiv(raw, DISCOUNT_PRECISION - discount, DISCOUNT_PRECISION);
    }

    function _failureCode(bytes memory err) internal pure returns (uint8 status, uint8 reason) {
        bytes4 selector = _selector(err);
        if (selector == SwapOutputBelowMin.selector) return (STATUS_SKIPPED, REASON_SWAP_OUTPUT_BELOW_MIN);
        if (selector == InsufficientLoanProceeds.selector) {
            return (STATUS_SKIPPED, REASON_INSUFFICIENT_LOAN_PROCEEDS);
        }
        if (selector == ProfitBelowMin.selector) return (STATUS_SKIPPED, REASON_PROFIT_BELOW_MIN);
        return (STATUS_REVERTED, REASON_MORPHO_REVERT);
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
}
