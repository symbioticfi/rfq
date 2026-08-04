// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.0;

/// @notice User-directed batch execution interface for registered LiquidLane adapters.
interface IRouter {
    /// @notice One adapter leg.
    /// @param adapter Factory-registered LiquidLane adapter that receives the input and executes `data`.
    /// @param amountIn Common input-token amount funded directly from the caller.
    /// @param data Complete adapter calldata.
    struct SwapCall {
        address adapter;
        uint256 amountIn;
        bytes data;
    }

    /// @notice Output payment made after all adapter calls complete.
    struct Output {
        address token;
        address recipient;
        uint256 amount;
    }

    error Expired(uint256 deadline);
    error InvalidAdapter(uint256 index, address adapter);

    function LIQUID_LANE_ADAPTER_FACTORY() external view returns (address);
    function execute(address tokenIn, SwapCall[] calldata calls, Output[] calldata outputs) external;
    function execute(address tokenIn, SwapCall[] calldata calls, Output[] calldata outputs, uint256 deadline) external;
}
