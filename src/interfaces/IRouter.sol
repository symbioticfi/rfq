// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.0;

/// @notice User-directed batch execution interface for registered LiquidLane adapters.
interface IRouter {
    struct SwapCall {
        address adapter;
        uint256 amountIn;
        bytes data;
    }

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
    error InvalidCalldata(uint256 index);
    error InvalidFactory(address factory);
    error InvalidOutputToken(uint256 index, address token);
    error InvalidRecipient(uint256 index, address recipient);
    error InvalidSelector(uint256 index, bytes4 selector);
    error InvalidTokenIn(address token);
    error OutputTransferMismatch(uint256 index, uint256 expected, uint256 actual);
    error SurplusTransferMismatch(address token, uint256 expected, uint256 actual);

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
    function execute(address tokenIn, SwapCall[] calldata calls, Output[] calldata outputs) external;
    function execute(address tokenIn, SwapCall[] calldata calls, Output[] calldata outputs, uint256 deadline) external;
}
