// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.0;

import {ILiquidLaneAdapter} from "../../interfaces/ILiquidLaneAdapter.sol";
import {IUniswapXReactorCallback, UniswapXSignedOrder} from "./IUniswapXReactor.sol";

interface ILiquidLaneUniswapXExecutor is IUniswapXReactorCallback {
    error DiscountTokenMismatch(address expectedToken, address actualToken);
    error EmptyRoutes();
    error InsufficientMinimumOutput(uint256 minimumAmountOut, uint256 requiredAmountOut);
    error InsufficientOutput(uint256 requiredAmountOut, uint256 receivedAmountOut);
    error IdenticalTokens();
    error InvalidAmount();
    error InvalidOrderCount();
    error InvalidOutputCount();
    error NotCaller();
    error NotReactor();
    error OutputTokenMismatch(address expectedToken, address actualToken);
    error RouteInputExceedsOrder(uint256 routedAmountIn, uint256 orderAmountIn);
    error RouteOutputTooLow(address adapter, uint256 minAmountOut, uint256 availableAmountOut);
    error ZeroAddress();

    struct FillRoute {
        address adapter;
        uint256 amountIn;
        uint256 amountOut;
    }

    struct FillCall {
        FillRoute[] routes;
        DiscountRoute[] discountRoutes;
    }

    struct DiscountRoute {
        address adapter;
        uint256 amountIn;
        uint256 minAmountOut;
        ILiquidLaneAdapter.DiscountSwap discountSwap;
        bytes protocolSignature;
    }

    event SetCallers(address[] newCallers);
    event InputRedeemed(
        bytes32 indexed orderHash,
        address indexed adapter,
        address indexed tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );
    event OrderFilled(
        bytes32 indexed orderHash,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 inputSurplus,
        uint256 amountOut,
        uint256 outputSurplus
    );

    function REACTOR() external view returns (address reactor);
    function callers(uint256 index) external view returns (address caller);
    function execute(UniswapXSignedOrder calldata order, FillCall calldata fillCall) external;
    function isCaller(address caller) external view returns (bool allowed);
    function setCallers(address[] calldata newCallers) external;
    function sweepERC20(address token, address to, uint256 amount) external;
}
