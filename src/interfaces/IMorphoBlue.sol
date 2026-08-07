// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.0;

import {MarketParams} from "../oev/interfaces/IMorpho.sol";

/// @notice The Morpho Blue entrypoints the loop router needs, beyond the liquidation subset already
///         declared in `src/oev/interfaces/IMorpho.sol`.
/// @dev `MarketParams` is imported from that file rather than redeclared so the two interfaces share
///      one struct type.
interface IMorphoBlue {
    /// @notice Supplies collateral on behalf of `onBehalf`. Requires no authorization.
    function supplyCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, bytes calldata data)
        external;

    /// @notice Withdraws collateral. Requires the sender to be authorized for `onBehalf`.
    function withdrawCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, address receiver)
        external;

    /// @notice Draws debt. Requires the sender to be authorized for `onBehalf`.
    function borrow(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 assetsBorrowed, uint256 sharesBorrowed);

    /// @notice Repays debt on behalf of `onBehalf`. Requires no authorization.
    function repay(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes calldata data
    ) external returns (uint256 assetsRepaid, uint256 sharesRepaid);

    /// @notice Fee-free flash loan. Morpho pulls `assets` back from the borrower after the callback.
    function flashLoan(address token, uint256 assets, bytes calldata data) external;

    /// @notice Whether `authorized` may manage `authorizer`'s position.
    function isAuthorized(address authorizer, address authorized) external view returns (bool);
}

/// @notice Callback invoked by Morpho Blue during `flashLoan`.
interface IMorphoFlashLoanCallback {
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external;
}
