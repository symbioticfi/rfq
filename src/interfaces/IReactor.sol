// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.0;

import {IInstantRedemptionAdapter} from "./IInstantRedemptionAdapter.sol";

address constant NATIVE = 0x0000000000000000000000000000000000000000;

bytes32 constant OUTPUT_TYPEHASH = keccak256("Output(address token,uint256 amount,address recipient)");
bytes32 constant REQUEST_TYPEHASH = keccak256(
    "Request(address tokenIn,uint256 amountIn,Output[] outputs,uint256 deadline,uint256 nonce,address protocol)"
    "Output(address token,uint256 amount,address recipient)"
);
bytes32 constant ORDER_TYPEHASH = keccak256(
    "Order(Request request,bytes swapperSignature,address swapper,address filler)"
    "Output(address token,uint256 amount,address recipient)"
    "Request(address tokenIn,uint256 amountIn,Output[] outputs,uint256 deadline,uint256 nonce,address protocol)"
);
string constant REQUEST_WITNESS_TYPE_STRING = "Request witness)Output(address token,uint256 amount,address recipient)"
    "Request(address tokenIn,uint256 amountIn,Output[] outputs,uint256 deadline,uint256 nonce,address protocol)"
    "TokenPermissions(address token,uint256 amount)";

/**
 * @title IReactor
 * @notice Interface for the Reactor contract.
 */
interface IReactor {
    /* ERRORS */

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
     * @notice Permit2 witness payload for an exact-input redemption request.
     * @param tokenIn Input token address.
     * @param amountIn Exact input amount.
     * @param outputs Output obligations that must be satisfied.
     * @param deadline Request deadline.
     * @param nonce Permit2 nonce.
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
     * @param swapperSignature Permit2 swapper signature.
     * @param swapper Address that owns the input token and signed the Permit2 witness.
     * @param filler Winning filler address allowed to call the Reactor.
     */
    struct Order {
        Request request;
        bytes swapperSignature;
        address swapper;
        address filler;
    }

    /**
     * @notice Discount-backed adapter swap input.
     * @param discountSwap Protocol-authorized reusable discount payload.
     * @param protocolSignature Protocol signature over `discountSwap`.
     * @param recipient Recipient of the collateral output.
     * @param amountIn Input RWA amount assigned to the vault leg.
     * @param amountOut Collateral amount requested from the adapter.
     */
    struct DiscountSwapInput {
        IInstantRedemptionAdapter.DiscountSwap discountSwap;
        bytes protocolSignature;
        address recipient;
        uint256 amountIn;
        uint256 amountOut;
    }

    /* EVENTS */

    /**
     * @notice Emitted when an order is filled.
     * @param order Filled order payload.
     */
    event Fill(Order order);

    /* FUNCTIONS */

    /**
     * @notice Fills an order using the caller contract as the filler.
     * @param order Protocol-authorized order.
     * @param protocolSignature Protocol signature over the order.
     * @param swap Direct-caller adapter swap.
     * @param executorData Encoded executor payload.
     */
    function fill(
        Order calldata order,
        bytes calldata protocolSignature,
        IInstantRedemptionAdapter.Swap calldata swap,
        bytes calldata executorData
    ) external;

    /**
     * @notice Fills an order using multiple adapter legs with the caller contract as the filler.
     * @param order Protocol-authorized order.
     * @param protocolSignature Protocol signature over the order.
     * @param swapInputs Direct-caller adapter swaps.
     * @param executorData Encoded executor payload.
     */
    function fill(
        Order calldata order,
        bytes calldata protocolSignature,
        IInstantRedemptionAdapter.Swap[] calldata swapInputs,
        bytes calldata executorData
    ) external;

    /**
     * @notice Fills an order using both direct and discount-backed adapter legs with the caller contract as the filler.
     * @param order Protocol-authorized order.
     * @param protocolSignature Protocol signature over the order.
     * @param swapInputs Direct-caller adapter swaps.
     * @param discountSwapInputs Discount-backed adapter swap inputs.
     * @param executorData Encoded executor payload.
     */
    function fill(
        Order calldata order,
        bytes calldata protocolSignature,
        IInstantRedemptionAdapter.Swap[] calldata swapInputs,
        DiscountSwapInput[] calldata discountSwapInputs,
        bytes calldata executorData
    ) external;
}
