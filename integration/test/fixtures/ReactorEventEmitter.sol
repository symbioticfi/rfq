// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ReactorEventEmitter
/// @notice Minimal fixture contract that emits the Reactor `Fill(Order)` event for integration tests.
contract ReactorEventEmitter {
    struct Output {
        address token;
        uint256 amount;
        address recipient;
    }

    struct Request {
        address tokenIn;
        uint256 amountIn;
        Output[] outputs;
        uint256 deadline;
        uint256 nonce;
        address protocol;
    }

    struct Order {
        Request request;
        bytes swapperSignature;
        address swapper;
        address filler;
    }

    event Fill(Order order);

    function emitFill(Order calldata order) external {
        emit Fill(order);
    }
}
