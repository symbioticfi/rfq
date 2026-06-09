// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.0;

import {ILiquidLaneAdapter} from "./ILiquidLaneAdapter.sol";

/* Sentinel address used to represent native asset outputs. */
address constant NATIVE = 0x0000000000000000000000000000000000000000;

/* EIP-712 typehash for Reactor output obligations. */
bytes32 constant OUTPUT_TYPEHASH = keccak256("Output(address token,uint256 amount,address recipient)");
/* EIP-712 typehash for Reactor requests. */
bytes32 constant REQUEST_TYPEHASH = keccak256(
    "Request(address tokenIn,uint256 amountIn,Output[] outputs,uint256 deadline,uint256 nonce,address protocol)"
    "Output(address token,uint256 amount,address recipient)"
);
/* EIP-712 typehash for Reactor orders. */
bytes32 constant ORDER_TYPEHASH = keccak256(
    "Order(Request request,bytes swapperSignature,address swapper,address filler)"
    "Output(address token,uint256 amount,address recipient)"
    "Request(address tokenIn,uint256 amountIn,Output[] outputs,uint256 deadline,uint256 nonce,address protocol)"
);

/**
 * @title IReactor
 * @notice Interface for the Reactor contract.
 */
interface IReactor {
    /* ERRORS */

    /**
     * @notice Raised when the request deadline has passed.
     */
    error ExpiredRequest();

    /**
     * @notice Raised when a swap adapter is not a LiquidLane adapter factory entity.
     */
    error InvalidAdapter();

    /**
     * @notice Raised when the sum of swap input amounts does not match the request input amount.
     */
    error InvalidAmountIn();

    /**
     * @notice Raised when the caller is not the authorized filler.
     */
    error InvalidFiller();

    /**
     * @notice Raised when an output obligation is not satisfied.
     */
    error InvalidOutput();

    /**
     * @notice Raised when the protocol signature is invalid.
     */
    error InvalidProtocolSignature();

    /**
     * @notice Raised when a swap token does not match the request input token.
     */
    error InvalidTokenIn();

    /**
     * @notice Raised when the swapper request nonce has already been used.
     */
    error NonceUsed();

    /* STRUCTS */

    /**
     * @notice Output obligation that must be satisfied during a fill.
     * @param token Output token address.
     * @param amount Minimum amount that must be delivered.
     * @param recipient Recipient that must receive the output.
     */
    struct Output {
        address token;
        uint256 amount;
        address recipient;
    }

    /**
     * @notice Exact-input redemption request.
     * @param tokenIn Input token address.
     * @param amountIn Exact input amount.
     * @param outputs Output obligations that must be satisfied.
     * @param deadline Request expiry timestamp.
     * @param nonce Swapper nonce consumed by Reactor on fill.
     * @param protocol Protocol signer bound to the request.
     */
    struct Request {
        address tokenIn;
        uint256 amountIn;
        Output[] outputs;
        uint256 deadline;
        uint256 nonce;
        address protocol;
    }

    /**
     * @notice Protocol-authorized order for a winning filler.
     * @param request Swapper request that is bound to the fill.
     * @param swapperSignature Swapper signature over `request`.
     * @param swapper Swapper address that owns the input token and approved Reactor.
     * @param filler Winning filler address allowed to call the Reactor.
     */
    struct Order {
        Request request;
        bytes swapperSignature;
        address swapper;
        address filler;
    }

    /**
     * @notice Direct adapter swap input.
     * @param adapter LiquidLane adapter that executes the swap.
     * @param swap Direct-caller adapter swap payload.
     */
    struct SwapInput {
        address adapter;
        ILiquidLaneAdapter.Swap swap;
    }

    /**
     * @notice Discount-backed adapter swap input.
     * @param adapter LiquidLane adapter that executes the swap.
     * @param discountSwap Protocol-authorized reusable discount payload.
     * @param protocolSignature Protocol signature over `discountSwap`.
     * @param recipient Recipient of the collateral output.
     * @param amountIn Input RWA amount assigned to the adapter leg.
     */
    struct DiscountSwapInput {
        address adapter;
        ILiquidLaneAdapter.DiscountSwap discountSwap;
        bytes protocolSignature;
        address recipient;
        uint256 amountIn;
    }

    /* EVENTS */

    /**
     * @notice Emitted when an order is filled.
     * @param order Filled order payload.
     */
    event Fill(Order order);

    /**
     * @notice Emitted when a swapper invalidates a request nonce.
     * @param swapper Swapper address that owns the invalidated nonce.
     * @param nonce Request nonce that was invalidated.
     */
    event InvalidateNonce(address indexed swapper, uint256 nonce);

    /* FUNCTIONS */

    /**
     * @notice Returns the LiquidLane adapter factory registry used for adapter validation.
     * @return factory LiquidLane adapter factory address.
     */
    function LIQUID_LANE_ADAPTER_FACTORY() external view returns (address factory);

    /**
     * @notice Returns whether a swapper request nonce has been consumed.
     * @param swapper Address that owns the nonce.
     * @param nonce Request nonce to check.
     * @return used Whether the nonce has already been consumed.
     */
    function isUsedNonce(address swapper, uint256 nonce) external view returns (bool used);

    /**
     * @notice Invalidates one caller-owned request nonce before it is filled.
     * @param nonce Request nonce to invalidate for `msg.sender`.
     */
    function invalidateNonce(uint256 nonce) external;

    /**
     * @notice Fills an order using the caller contract as the filler.
     * @param order Protocol-authorized order.
     * @param protocolSignature Protocol signature over the order.
     * @param swapInput Direct-caller adapter swap input.
     * @param executorData Encoded executor payload.
     */
    function fill(
        Order calldata order,
        bytes calldata protocolSignature,
        SwapInput calldata swapInput,
        bytes calldata executorData
    ) external;

    /**
     * @notice Fills an order using multiple adapter legs with the caller contract as the filler.
     * @param order Protocol-authorized order.
     * @param protocolSignature Protocol signature over the order.
     * @param swapInputs Direct-caller adapter swap inputs.
     * @param executorData Encoded executor payload.
     */
    function fill(
        Order calldata order,
        bytes calldata protocolSignature,
        SwapInput[] calldata swapInputs,
        bytes calldata executorData
    ) external;

    /**
     * @notice Fills an order using both direct and discount-backed adapter legs with the caller contract as the filler.
     * @param order Protocol-authorized order.
     * @param protocolSignature Protocol signature over the order.
     * @param swapInputs Direct-caller adapter swap inputs.
     * @param discountSwapInputs Discount-backed adapter swap inputs.
     * @param executorData Encoded executor payload.
     */
    function fill(
        Order calldata order,
        bytes calldata protocolSignature,
        SwapInput[] calldata swapInputs,
        DiscountSwapInput[] calldata discountSwapInputs,
        bytes calldata executorData
    ) external;
}
