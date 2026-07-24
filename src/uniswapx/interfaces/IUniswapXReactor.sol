// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.0;

struct UniswapXOrderInfo {
    address reactor;
    address swapper;
    uint256 nonce;
    uint256 deadline;
    address additionalValidationContract;
    bytes additionalValidationData;
}

struct UniswapXInputToken {
    address token;
    uint256 amount;
    uint256 maxAmount;
}

struct UniswapXOutputToken {
    address token;
    uint256 amount;
    address recipient;
}

struct UniswapXResolvedOrder {
    UniswapXOrderInfo info;
    UniswapXInputToken input;
    UniswapXOutputToken[] outputs;
    bytes sig;
    bytes32 hash;
}

struct UniswapXSignedOrder {
    bytes order;
    bytes sig;
}

interface IUniswapXReactor {
    function executeWithCallback(UniswapXSignedOrder calldata order, bytes calldata callbackData) external payable;
}

interface IUniswapXReactorCallback {
    function reactorCallback(UniswapXResolvedOrder[] memory resolvedOrders, bytes memory callbackData) external;
}
