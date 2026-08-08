// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.0;

import {IRouter} from "./IRouter.sol";

/// @notice Single-asset flash loans from Aave v3, Balancer v2, or Morpho Blue.
interface IFlashLoanCapability {
    /// @notice Which provider interface `provider` speaks. Only the interface, not the address.
    enum Provider {
        Aave,
        Balancer,
        Morpho
    }

    /// @notice Emitted once the borrowed funds have been used and the repayment is in place.
    event FlashLoan(
        Provider indexed providerType, address indexed provider, address token, uint256 amount, uint256 fee
    );

    /// @notice Thrown when a callback does not match the in-flight request: a stray callback, an
    ///         impostor lender, or the wrong provider type.
    error UnexpectedFlashLoan();

    /// @notice Thrown when the borrowed funds plus whatever the calls produced cannot cover
    ///         principal and fee.
    error FlashLoanNotRepaid(address token, uint256 held, uint256 owed);

    /// @notice Borrows `amount` of `token` from `provider` and runs `calls` with it.
    /// @dev Permissionless: this contract holds no allowances, so there is nothing to gate. Any
    ///      surplus left after repayment is returned to the caller.
    /// @param providerType Which interface `provider` speaks.
    /// @param provider The lender. Chosen by the caller, never trusted for anything but repayment.
    /// @param token The asset to borrow.
    /// @param amount Principal to borrow.
    /// @param calls Calls run while the borrowed funds are held here; one may nest another loan.
    function flashLoan(
        Provider providerType,
        address provider,
        address token,
        uint256 amount,
        IRouter.Call[] calldata calls
    ) external;
}

interface IFlashLoanBalancerVault {
    function flashLoan(
        address recipient,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes calldata userData
    ) external;
}

interface IFlashLoanBalancerRecipient {
    function receiveFlashLoan(
        address[] calldata tokens,
        uint256[] calldata amounts,
        uint256[] calldata feeAmounts,
        bytes calldata userData
    ) external;
}

interface IFlashLoanAavePool {
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

interface IFlashLoanAaveReceiver {
    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata params)
        external
        returns (bool);
}

interface IFlashLoanMorpho {
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}

interface IFlashLoanMorphoCallback {
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external;
}
