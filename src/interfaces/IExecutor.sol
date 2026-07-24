// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.0;

import {IReactor} from "./IReactor.sol";

/**
 * @title IExecutor
 * @notice Interface for caller-gated executor contracts used by the Reactor.
 */
interface IExecutor {
    /* ERRORS */

    /**
     * @notice Raised when the caller is not in the allowed caller list.
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

    /* EVENTS */

    /**
     * @notice Emitted when the allowed caller list is replaced.
     * @param newCallers Addresses allowed to call the fill entrypoints.
     */
    event SetCallers(address[] newCallers);

    /* FUNCTIONS */

    /**
     * @notice Initializes the proxy with its owner and allowed caller list.
     * @param owner Owner authorized to manage the caller list.
     * @param initCallers Initial addresses allowed to call the fill entrypoints.
     */
    function initialize(address owner, address[] calldata initCallers) external;

    /**
     * @notice Returns an allowed caller by index.
     * @param index Caller index.
     * @return caller Caller address.
     */
    function callers(uint256 index) external view returns (address caller);

    /**
     * @notice Caller-gated entrypoint that forwards a fill into Reactor.
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
     * @notice Caller-gated entrypoint that forwards a multi-leg fill into Reactor.
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
     * @notice Caller-gated entrypoint that forwards direct and discount-backed legs into Reactor.
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

    /**
     * @notice Replaces the allowed caller list.
     * @param newCallers Addresses allowed to call the fill entrypoints.
     */
    function setCallers(address[] calldata newCallers) external;
}
