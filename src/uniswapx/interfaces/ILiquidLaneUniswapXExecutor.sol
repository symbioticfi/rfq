// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.0;

import {IUniswapXReactorCallback, UniswapXSignedOrder} from "./IUniswapXReactor.sol";

import {IExecutor} from "src/interfaces/IExecutor.sol";

interface ILiquidLaneUniswapXExecutor is IUniswapXReactorCallback {
    error NotCaller();
    error NotReactor();

    event SetCallers(address[] newCallers);

    function initialize(address owner, address[] calldata initCallers) external;
    function callers(uint256 index) external view returns (address caller);
    /// @notice Executes caller-supplied calls after receiving inputs, then settles the order outputs.
    function execute(UniswapXSignedOrder calldata order, IExecutor.Call[] calldata calls) external;
    function setCallers(address[] calldata newCallers) external;
}
