// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.0;

/// @notice User-directed executor: pull one token in, run arbitrary calls, pay declared outputs.
interface IRouter {
    /// @notice One arbitrary call executed with the router as `msg.sender`.
    struct Call {
        address target;
        bytes data;
    }

    /// @notice A payment made from the router's balance once all calls have run.
    struct Output {
        address token;
        address recipient;
        uint256 minAmount;
    }

    event Executed(address indexed account, address indexed tokenIn, uint256 amountIn);

    error Expired();
    error RelayerCallForbidden();
    error InsufficientOutput(address token, uint256 received, uint256 minAmount);

    /// @notice The relayer holding user allowances for this router.
    function RELAYER() external view returns (address relayer);

    /// @notice Pulls `amountIn` of `tokenIn` from the caller, runs `calls`, then pays `outputs`.
    /// @param tokenIn Token pulled from the caller through the relayer. Ignored when `amountIn` is zero.
    /// @param amountIn Amount pulled. May be zero for a call batch that needs no input.
    /// @param calls Arbitrary calls, executed in order. None may target the relayer.
    /// @param outputs Minimum amounts to deliver, each paid from the router's whole balance of that token.
    /// @param deadline Unix timestamp after which the call reverts.
    function execute(
        address tokenIn,
        uint256 amountIn,
        Call[] calldata calls,
        Output[] calldata outputs,
        uint256 deadline
    ) external;
}
