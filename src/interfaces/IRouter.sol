// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.0;

/// @notice User-directed batch execution interface for registered LiquidLane adapters.
interface IRouter {
    /// @notice One authenticated adapter leg.
    /// @param adapter Factory-registered LiquidLane adapter that receives the input and executes `data`.
    /// @param amountIn Exact common input-token amount funded directly from the caller.
    /// @param data Complete signed-swap or discount-swap adapter calldata.
    /// @param authSigner Current adapter owner, market maker, or authorized filler that approved this Router leg.
    /// @param authDeadline Nonzero Router-authorization expiry included in the signed payload.
    /// @param authSignature EIP-712 signature over this leg, its payer, token, and effective execution deadline.
    struct SwapCall {
        address adapter;
        uint256 amountIn;
        bytes data;
        address authSigner;
        uint256 authDeadline;
        bytes authSignature;
    }

    /// @notice Exact output payment made after the batch meets its aggregate minimums.
    struct Output {
        address token;
        address recipient;
        uint256 amount;
    }

    error AdapterCallFailed(uint256 index, address adapter, bytes reason);
    error BalanceIsolationViolation(address token, uint256 baseline, uint256 actual);
    error EmptyOutputs();
    error EmptySwapCalls();
    error Expired(uint256 deadline);
    error InputConsumptionMismatch(uint256 index, uint256 expectedBaseline, uint256 actual);
    error InputTransferMismatch(uint256 index, uint256 expected, uint256 actual);
    error InsufficientOutput(address token, uint256 required, uint256 produced);
    error InvalidAdapter(uint256 index, address adapter);
    error InvalidAmount(uint256 index);
    error InvalidAuthorizationDeadline(uint256 index, uint256 deadline);
    error InvalidAuthorizationSignature(uint256 index, address signer);
    error InvalidCalldata(uint256 index);
    error InvalidFactory(address factory);
    error InvalidOutputToken(uint256 index, address token);
    error InvalidRecipient(uint256 index, address recipient);
    error InvalidSelector(uint256 index, bytes4 selector);
    error InvalidTokenIn(address token);
    error OutputTransferMismatch(uint256 index, uint256 expected, uint256 actual);
    error SurplusTransferMismatch(address token, uint256 expected, uint256 actual);
    error UnauthorizedAuthSigner(uint256 index, address adapter, address signer);

    event OutputTransferred(address indexed token, address indexed recipient, uint256 amount);
    event SurplusTransferred(address indexed token, address indexed swapper, uint256 amount);
    event Execute(
        address indexed swapper,
        address indexed tokenIn,
        uint256 totalAmountIn,
        uint256 swapCallCount,
        uint256 outputCount
    );

    function LIQUID_LANE_ADAPTER_FACTORY() external view returns (address);
    /// @notice Exact primary type hash for the Router `SwapAuthorization` EIP-712 payload.
    function SWAP_AUTHORIZATION_TYPEHASH() external view returns (bytes32);
    function execute(address tokenIn, SwapCall[] calldata calls, Output[] calldata outputs) external;
    function execute(address tokenIn, SwapCall[] calldata calls, Output[] calldata outputs, uint256 deadline) external;
}
