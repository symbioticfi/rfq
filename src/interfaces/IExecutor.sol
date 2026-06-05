// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.0;

import {IReactor} from "./IReactor.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

// keccak256("CALLER_ROLE")
bytes32 constant CALLER_ROLE = 0x74a23095bc1d81f421b8f4e555b0abbafaf53263fb97dffca9f89a4ca3115d41;

/**
 * @title IExecutor
 * @notice Interface for role-gated executor contracts used by the Reactor.
 */
interface IExecutor is IAccessControl {
    /* ERRORS */

    /**
     * @notice Raised when the caller does not have the required role.
     */
    error NotCaller();

    /**
     * @notice Raised when the caller is not the Reactor.
     */
    error NotReactor();

    /* STRUCTS */

    /**
     * @notice Generic executor call instruction.
     * @param target Call target.
     * @param value Native value forwarded with the call.
     * @param data Calldata forwarded to the target.
     */
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    /* FUNCTIONS */

    /**
     * @notice Role-gated caller-facing entrypoint that forwards a fill into Reactor.
     * @param order Protocol-authorized order.
     * @param protocolSignature Protocol signature over the order.
     * @param swapInput Direct-caller adapter swap input.
     * @param executorData Encoded executor payload.
     */
    function fill(
        IReactor.Order calldata order,
        bytes calldata protocolSignature,
        IReactor.SwapInput calldata swapInput,
        bytes calldata executorData
    ) external;

    /**
     * @notice Role-gated caller-facing entrypoint that forwards a multi-leg fill into Reactor.
     * @param order Protocol-authorized order.
     * @param protocolSignature Protocol signature over the order.
     * @param swapInputs Direct-caller adapter swap inputs.
     * @param executorData Encoded executor payload.
     */
    function fill(
        IReactor.Order calldata order,
        bytes calldata protocolSignature,
        IReactor.SwapInput[] calldata swapInputs,
        bytes calldata executorData
    ) external;

    /**
     * @notice Role-gated caller-facing entrypoint that forwards direct and discount-backed legs into Reactor.
     * @param order Protocol-authorized order.
     * @param protocolSignature Protocol signature over the order.
     * @param swapInputs Direct-caller adapter swap inputs.
     * @param discountSwapInputs Discount-backed adapter swap inputs.
     * @param executorData Encoded executor payload.
     */
    function fill(
        IReactor.Order calldata order,
        bytes calldata protocolSignature,
        IReactor.SwapInput[] calldata swapInputs,
        IReactor.DiscountSwapInput[] calldata discountSwapInputs,
        bytes calldata executorData
    ) external;

    /**
     * @notice Executes routed calls for an authorized caller.
     * @param order Protocol-authorized order.
     * @param swapInputs Direct adapter swap inputs selected for the fill.
     * @param discountSwapInputs Discount-backed adapter swap legs selected for the fill.
     * @param executorData Encoded executor payload.
     */
    function execute(
        IReactor.Order calldata order,
        IReactor.SwapInput[] calldata swapInputs,
        IReactor.DiscountSwapInput[] calldata discountSwapInputs,
        bytes calldata executorData
    ) external;
}
