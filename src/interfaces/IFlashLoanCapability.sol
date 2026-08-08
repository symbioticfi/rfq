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

    /// @notice Emitted once a request has run and its surplus has been returned.
    event FlashLoan(Provider indexed providerType, address indexed provider, address token, uint256 amount);

    /// @notice Borrows and runs the calls carried in `data`.
    /// @dev Permissionless, and safe only because this contract holds nothing: no allowances, and
    ///      its balance is swept to the caller before returning. Repaying the lender is one of the
    ///      encoded calls — this contract does not model fees or repayment.
    /// @param data `abi.encode(Provider, provider, token, amount, abi.encode(IRouter.Call[]))`.
    function flashLoan(bytes calldata data) external;
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
