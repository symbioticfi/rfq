// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.0;

import {IInputCallback} from "./IInputCallback.sol";
import {IInputSettler} from "./IInputSettler.sol";
import {MandateOutput} from "./IOutputSettler.sol";
import {ILiquidLaneAdapter} from "../../interfaces/ILiquidLaneAdapter.sol";

/**
 * @title ILiquidLaneLifiExecutor
 * @notice LI.FI same-chain executor callback for on-chain orders.
 */
interface ILiquidLaneLifiExecutor is IInputCallback {
    /* ERRORS */

    error AdapterNotAllowed();
    error DuplicateAdapter();
    error DiscountExpired(uint48 deadline, uint48 protocolDeadline, uint256 currentTime);
    error DiscountTokenMismatch(address expectedToken, address discountToken);
    error EmptyRoutes();
    error ExclusiveForMismatch(bytes32 exclusiveFor, bytes32 solver);
    error FillTooEarly(uint32 fillAfter, uint32 currentTime);
    error FillAfterWithoutAuction();
    error InsufficientMinimumOutput(uint256 minimumAmountOut, uint256 resolvedAmountOut);
    error InsufficientOutput(uint256 minimumAmountOut, uint256 receivedAmountOut);
    error InvalidAmount();
    error InvalidDestination();
    error InvalidDiscount(uint256 discount, uint256 minimumDiscount);
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
    error InvalidRouteOutputBounds(uint256 expectedAmountOut, uint256 minAmountOut);
    error NativeOutputUnsupported();
    error NotInputSettler();
    error PrivateRouteExceedsCapacity(address adapter, uint256 amountOut, uint256 maxAssets);
    error RouteInputMismatch(uint256 routedAmountIn, uint256 orderAmountIn);
    error RouteOutputTooLow(address adapter, uint256 minAmountOut, uint256 availableAmountOut);
    error SolverMismatch();
    error UnknownOutputContext(bytes1 contextType);
    error ZeroAddress();

    /* STRUCTS */

    /**
     * @notice Optional private-discount authorization for one route.
     * @param discountId Backend discount identifier; zero selects the direct swap path.
     * @param discountSwap Reusable signer policy plus the fresh protocol deadline.
     * @param protocolSignature Fresh protocol cosign verified by the LiquidLane adapter.
     */
    struct FillDiscount {
        bytes32 discountId;
        ILiquidLaneAdapter.DiscountSwap discountSwap;
        bytes protocolSignature;
    }

    /**
     * @notice One atomic LiquidLane redemption leg.
     * @param adapter Allowed LiquidLane adapter.
     * @param amountIn Order-input amount routed to the adapter.
     * @param expectedAmountOut Preferred output at the strategy's buffered quote.
     * @param minAmountOut Hard economic floor after order output, gas, and minimum margin.
     * @param discount Optional private-discount authorization; zero id means direct swap.
     */
    struct FillRoute {
        address adapter;
        uint256 amountIn;
        uint256 expectedAmountOut;
        uint256 minAmountOut;
        FillDiscount discount;
    }

    /**
     * @notice Callback payload built by the LI.FI solver and passed to InputSettler.finalise.
     * @param orderId OIF order id.
     * @param output Single output to fill and attest.
     * @param fillDeadline Fill deadline carried by the order.
     * @param solver Solver identifier written into filler data and attestation.
     * @param fillAfter Earliest timestamp when the solver strategy allows filling.
     * @param routes LiquidLane legs selected by the solver. Their input sum must equal the order input;
     * each minimum output is checked against current rate/capacity and direct targets may be clamped.
     */
    struct FillCall {
        bytes32 orderId;
        MandateOutput output;
        uint32 fillDeadline;
        bytes32 solver;
        uint32 fillAfter;
        FillRoute[] routes;
    }

    /* EVENTS */

    event InputRedeemed(
        bytes32 indexed orderId,
        address indexed adapter,
        address indexed tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bytes32 discountId
    );
    event OutputFilled(
        bytes32 indexed orderId,
        bytes32 indexed solver,
        address indexed token,
        address recipient,
        uint256 amount,
        uint256 surplus
    );
    event SetAdapters(address[] adapters);
    event SweepERC20(address indexed token, address indexed to, uint256 amount);
    event SweepNative(address indexed to, uint256 amount);

    /* FUNCTIONS */

    function INPUT_SETTLER() external view returns (address inputSettler);
    function OUTPUT_SETTLER() external view returns (address outputSettler);
    function adapters(uint256 index) external view returns (address adapter);
    function expectedOutput(FillCall calldata fillCall) external pure returns (uint256 expectedAmountOut);
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
