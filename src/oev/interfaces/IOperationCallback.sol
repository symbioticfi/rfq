// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Interface a solver implements so that RedStone's on-chain Executor can drive liquidations.
interface IOperationCallback {
    /// @notice Invoked by the Executor with the solver's signed `operationData`.
    /// @param bidAmount Native bid amount the solver committed to pay back in `payBid`.
    /// @param solver The solver address that won the auction (equal to `address(this)` in typical setups).
    /// @param operationData Opaque payload the solver signed off-chain; decoded inside `liquidate`.
    function liquidate(uint256 bidAmount, address solver, bytes calldata operationData) external;

    /// @notice Invoked by the Executor right after `liquidate` to collect the bid in native currency.
    /// @param bidAmount Native amount to transfer back to the Executor.
    function payBid(uint256 bidAmount) external;
}
