// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.28;

import {ILiquidLaneAdapter} from "../interfaces/ILiquidLaneAdapter.sol";
import {Id, IMorpho, IMorphoLiquidateCallback, MarketParams} from "./interfaces/IMorpho.sol";
import {IOperationCallback} from "./interfaces/IOperationCallback.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title SymbioticOevSolver
/// @notice OEV liquidation callback that routes seized RWA collateral through a Symbiotic
///         LiquidLane adapter to source the loan token in-flight, avoiding a flash loan.
/// @dev    Designed for the Morpho Blue liquidation callback flow described in
///         https://github.com/redstone-finance/redstone-evm-examples/blob/main/oev/solver-example/Solver.sol
contract SymbioticOevSolver is IOperationCallback, IMorphoLiquidateCallback {
    using SafeERC20 for IERC20;

    /* ERRORS */

    error NotExecutor();
    error NotMorpho();
    error NotOwner();
    error InsufficientLoanProceeds();
    error TransferFailed();

    /* IMMUTABLES */

    /// @notice RedStone's on-chain Executor. The only authorized caller of `liquidate` / `payBid`.
    address public immutable EXECUTOR;
    /// @notice Morpho Blue lending market.
    address public immutable MORPHO;
    /// @notice Symbiotic LiquidLane adapter used as the RWA exit venue.
    address public immutable LIQUID_LANE_ADAPTER;

    /* STATE */

    address public owner;

    /* EVENTS */

    event Liquidated(Id indexed marketId, address indexed borrower, uint256 seizedAssets, uint256 repaidAssets);
    event BidPaid(uint256 amount);
    event OwnerUpdated(address indexed previous, address indexed next);

    /* STRUCTS */

    /// @notice One liquidation leg the solver wants to execute in this auction.
    /// @param marketId        Morpho market identifier.
    /// @param borrower        Borrower being liquidated.
    /// @param seizedAssets    Collateral to seize. Set to zero if `repaidShares` is used instead.
    /// @param repaidShares    Borrow shares to repay. Set to zero if `seizedAssets` is used instead.
    /// @param swapAmountOut   Loan-token amount requested from the adapter (must respect `getMaxRate`).
    struct LiquidationLeg {
        Id marketId;
        address borrower;
        uint256 seizedAssets;
        uint256 repaidShares;
        uint256 swapAmountOut;
    }

    /// @dev Encoded into Morpho's callback `data` so `onMorphoLiquidate` knows what to do.
    struct CallbackContext {
        LiquidationLeg leg;
        address loanToken;
        address collateralToken;
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

    constructor(address executor, address morpho, address liquidLaneAdapter, address initialOwner) {
        EXECUTOR = executor;
        MORPHO = morpho;
        LIQUID_LANE_ADAPTER = liquidLaneAdapter;
        owner = initialOwner;
        emit OwnerUpdated(address(0), initialOwner);
    }

    /* RECEIVE */

    receive() external payable {}

    /* IOperationCallback */

    /// @inheritdoc IOperationCallback
    function liquidate(uint256, address, bytes calldata operationData) external onlyExecutor {
        LiquidationLeg[] memory legs = abi.decode(operationData, (LiquidationLeg[]));
        for (uint256 i; i < legs.length; ++i) {
            _runLeg(legs[i]);
        }
    }

    /// @inheritdoc IOperationCallback
    function payBid(uint256 bidAmount) external onlyExecutor {
        (bool ok,) = payable(msg.sender).call{value: bidAmount}("");
        if (!ok) revert TransferFailed();
        emit BidPaid(bidAmount);
    }

    /* IMorphoLiquidateCallback */

    /// @inheritdoc IMorphoLiquidateCallback
    /// @dev Invoked by Morpho mid-`liquidate` after the seized collateral lands in this contract and
    ///      before Morpho pulls `repaidAssets` of the loan token back. We use this window to convert the
    ///      seized RWA into the loan token via the Symbiotic LiquidLane adapter.
    function onMorphoLiquidate(uint256 repaidAssets, bytes calldata data) external {
        if (msg.sender != MORPHO) revert NotMorpho();
        CallbackContext memory ctx = abi.decode(data, (CallbackContext));

        uint256 seizedBalance = IERC20(ctx.collateralToken).balanceOf(address(this));

        // Push the seized RWA to the LiquidLane adapter, which expects the token to already be in place.
        IERC20(ctx.collateralToken).safeTransfer(LIQUID_LANE_ADAPTER, seizedBalance);

        // Pull vault collateral (the loan token) out of the adapter. amountOut must respect getMaxRate.
        ILiquidLaneAdapter(LIQUID_LANE_ADAPTER)
            .swap(
                ILiquidLaneAdapter.Swap({
                recipient: address(this),
                tokenIn: ctx.collateralToken,
                amountIn: seizedBalance,
                amountOut: ctx.leg.swapAmountOut
            })
            );

        uint256 loanBalance = IERC20(ctx.loanToken).balanceOf(address(this));
        if (loanBalance < repaidAssets) revert InsufficientLoanProceeds();

        // Approve Morpho to pull repaidAssets when the callback returns.
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
        emit OwnerUpdated(owner, newOwner);
        owner = newOwner;
    }

    /* INTERNAL */

    function _runLeg(LiquidationLeg memory leg) internal {
        (address loanToken, address collateralToken, address oracle, address irm, uint256 lltv) =
            IMorpho(MORPHO).idToMarketParams(leg.marketId);

        bytes memory cbData =
            abi.encode(CallbackContext({leg: leg, loanToken: loanToken, collateralToken: collateralToken}));

        (uint256 assetsSeized, uint256 assetsRepaid) = IMorpho(MORPHO)
            .liquidate(
                MarketParams({
                loanToken: loanToken, collateralToken: collateralToken, oracle: oracle, irm: irm, lltv: lltv
            }),
                leg.borrower,
                leg.seizedAssets,
                leg.repaidShares,
                cbData
            );

        emit Liquidated(leg.marketId, leg.borrower, assetsSeized, assetsRepaid);
    }
}
