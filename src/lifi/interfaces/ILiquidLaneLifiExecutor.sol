// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.0;

import {IInputCallback} from "./IInputCallback.sol";
import {IInputSettler} from "./IInputSettler.sol";
import {MandateOutput} from "./IOutputSettler.sol";

/**
 * @title ILiquidLaneLifiExecutor
 * @notice LI.FI same-chain executor callback for on-chain orders.
 */
interface ILiquidLaneLifiExecutor is IInputCallback {
    /* ERRORS */

    error AdapterNotAllowed();
    error DuplicateAdapter();
    error ExclusiveForMismatch(bytes32 exclusiveFor, bytes32 solver);
    error FillTooEarly(uint32 fillAfter, uint32 currentTime);
    error FillAfterWithoutAuction();
    error InsufficientOutput();
    error InvalidAmount();
    error InvalidDestination();
    error InvalidInputCount();
    error InvalidInputSettler();
    error InvalidIdentifier();
    error InvalidOrderId();
    error InvalidOrderOutput();
    error InvalidOrderStatus(uint8 status);
    error InvalidOutputCount();
    error InvalidOutputContextLength(uint8 contextType, uint256 length);
    error InvalidOutputChain();
    error InvalidOutputOracle();
    error InvalidOutputSettler();
    error NativeOutputUnsupported();
    error NotInputSettler();
    error SolverMismatch();
    error UnknownOutputContext(bytes1 contextType);
    error ZeroAddress();

    /* STRUCTS */

    /**
     * @notice Callback payload built by the LI.FI solver and passed to InputSettler.finalise.
     * @param adapter LiquidLane adapter to redeem inputs through.
     * @param orderId OIF order id.
     * @param output Single output to fill and attest.
     * @param fillDeadline Fill deadline carried by the order.
     * @param solver Solver identifier written into filler data and attestation.
     * @param fillAfter Earliest timestamp when the solver strategy allows filling.
     */
    struct FillCall {
        address adapter;
        bytes32 orderId;
        MandateOutput output;
        uint32 fillDeadline;
        bytes32 solver;
        uint32 fillAfter;
    }

    /* EVENTS */

    event InputRedeemed(
        bytes32 indexed orderId,
        address indexed adapter,
        address indexed tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );
    event OutputFilled(
        bytes32 indexed orderId, bytes32 indexed solver, address indexed token, address recipient, uint256 amount
    );
    event SetAdapters(address[] adapters);
    event SweepERC20(address indexed token, address indexed to, uint256 amount);
    event SweepNative(address indexed to, uint256 amount);

    /* FUNCTIONS */

    function INPUT_SETTLER() external view returns (address inputSettler);
    function OUTPUT_SETTLER() external view returns (address outputSettler);
    function adapters(uint256 index) external view returns (address adapter);
    function finaliseWithCurrentTimestamp(
        address inputSettler,
        IInputSettler.StandardOrder calldata order,
        address solver,
        address destination,
        bytes calldata call,
        bytes calldata orderOwnerSignature
    ) external;
    function isAdapterAllowed(address adapter) external view returns (bool allowed);
    function setAdapters(address[] calldata newAdapters) external;
    function sweepERC20(address token, address to, uint256 amount) external;
    function sweepNative(address to, uint256 amount) external;
}
