// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.0;

import {MarketParams} from "../oev/interfaces/IMorpho.sol";

/// @notice User-directed one-transaction leverage looping against Morpho Blue, unwound through a
///         registered LiquidLane adapter's synchronous redeem.
interface ILoopRouter {
    /// @notice A call into an allowlisted venue that converts one token into another.
    /// @dev `target` is checked against `isVenue`. `target == address(0)` means "skip this leg",
    ///      which is the correct configuration whenever the two tokens are already the same.
    struct VenueCall {
        address target;
        bytes data;
    }

    /// @notice Inputs for levering up.
    /// @param market Morpho Blue market to lever in.
    /// @param seedCollateral Collateral pulled from the caller on top of the flash-loaned leg. May be zero.
    /// @param flashLoanAmount Loan-token amount flash-borrowed from Morpho, converted into collateral and
    ///        finally borrowed against the caller's own position to repay the loan.
    /// @param acquire Venue call converting the flash-loaned loan token into collateral.
    /// @param minCollateralAcquired Slippage floor on `acquire`, measured as a balance delta.
    /// @param deadline Unix timestamp after which the call reverts.
    struct LoopParams {
        MarketParams market;
        uint256 seedCollateral;
        uint256 flashLoanAmount;
        VenueCall acquire;
        uint256 minCollateralAcquired;
        uint256 deadline;
    }

    /// @notice Inputs for unwinding.
    /// @param market Morpho Blue market to unwind.
    /// @param repayAssets Loan-token debt repaid, flash-borrowed for the duration of the call.
    /// @param withdrawCollateral Collateral withdrawn from the caller's position and redeemed.
    /// @param adapter Factory-registered LiquidLane adapter performing the synchronous redeem.
    /// @param redeemData Complete adapter calldata. The signed quote inside it must name this router as
    ///        the recipient; that is enforced here by balance delta rather than by decoding.
    /// @param redeemAsset Token the adapter pays out, i.e. the LiquidLane vault asset. Equal to
    ///        `market.loanToken` for an asset-matched market, and different for e.g. a PYUSD market
    ///        redeeming into USDC, in which case `settle` bridges the two.
    /// @param minRedeemed Floor on the adapter's payout, measured as a balance delta.
    /// @param settle Venue call converting the redeemed asset into the loan token. Skipped when they match.
    /// @param deadline Unix timestamp after which the call reverts.
    struct UnloopParams {
        MarketParams market;
        uint256 repayAssets;
        uint256 withdrawCollateral;
        address adapter;
        bytes redeemData;
        address redeemAsset;
        uint256 minRedeemed;
        VenueCall settle;
        uint256 deadline;
    }

    /// @notice Emitted after a successful lever-up.
    event Looped(
        address indexed account, address indexed collateralToken, uint256 collateralSupplied, uint256 debtDrawn
    );

    /// @notice Emitted after a successful unwind.
    event Unlooped(
        address indexed account, address indexed collateralToken, uint256 debtRepaid, uint256 collateralRedeemed
    );

    /// @notice Emitted when the owner adds or removes an acquisition/settlement venue.
    event SetVenue(address indexed target, bool allowed);

    error Expired();
    error InvalidAdapter();
    error InvalidVenue();
    error NotMorpho();
    error UnexpectedCallback();
    error InsufficientAcquired();
    error InsufficientRedeemed();
    error InsufficientRepayment();
    error ZeroAmount();

    function MORPHO() external view returns (address);
    function LIQUID_LANE_ADAPTER_FACTORY() external view returns (address);
    function isVenue(address target) external view returns (bool);

    function setVenue(address target, bool allowed) external;
    function loop(LoopParams calldata params) external;
    function unloop(UnloopParams calldata params) external;
}
