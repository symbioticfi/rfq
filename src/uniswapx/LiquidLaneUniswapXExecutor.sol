// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.28;

import {ILiquidLaneAdapter} from "../interfaces/ILiquidLaneAdapter.sol";
import {ILiquidLaneUniswapXExecutor} from "./interfaces/ILiquidLaneUniswapXExecutor.sol";
import {IUniswapXReactor, UniswapXResolvedOrder, UniswapXSignedOrder} from "./interfaces/IUniswapXReactor.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title LiquidLaneUniswapXExecutor
/// @notice UniswapX Reactor callback that atomically sources same-token outputs from LiquidLane adapters.
contract LiquidLaneUniswapXExecutor is Ownable, ReentrancyGuard, ILiquidLaneUniswapXExecutor {
    using SafeERC20 for IERC20;

    address public immutable REACTOR;
    address[] public callers;

    modifier onlyCaller() {
        if (!_isCaller(msg.sender)) revert NotCaller();
        _;
    }

    constructor(address reactor, address owner_, address[] memory initCallers) Ownable(owner_) {
        if (reactor == address(0) || owner_ == address(0)) revert ZeroAddress();
        REACTOR = reactor;
        callers = initCallers;
    }

    function execute(UniswapXSignedOrder calldata order, FillCall calldata fillCall) external onlyCaller {
        IUniswapXReactor(REACTOR).executeWithCallback(order, abi.encode(fillCall));
    }

    function isCaller(address caller) external view returns (bool) {
        return _isCaller(caller);
    }

    function reactorCallback(UniswapXResolvedOrder[] memory resolvedOrders, bytes memory callbackData)
        external
        nonReentrant
    {
        if (msg.sender != REACTOR) revert NotReactor();
        if (resolvedOrders.length != 1) revert InvalidOrderCount();

        UniswapXResolvedOrder memory order = resolvedOrders[0];
        if (order.outputs.length == 0) revert InvalidOutputCount();
        address outputToken = order.outputs[0].token;
        if (order.input.token == address(0) || outputToken == address(0)) revert ZeroAddress();
        if (order.input.amount == 0) revert InvalidAmount();
        if (order.input.token == outputToken) revert IdenticalTokens();
        uint256 requiredAmountOut;
        for (uint256 i; i < order.outputs.length; ++i) {
            if (order.outputs[i].token != outputToken) {
                revert OutputTokenMismatch(outputToken, order.outputs[i].token);
            }
            if (order.outputs[i].amount == 0) revert InvalidAmount();
            requiredAmountOut += order.outputs[i].amount;
        }

        FillCall memory fillCall = abi.decode(callbackData, (FillCall));
        (uint256 routedAmountIn, uint256 minimumAmountOut) =
            _validateFillCall(fillCall, order.input.token, order.input.amount);
        if (minimumAmountOut < requiredAmountOut) {
            revert InsufficientMinimumOutput(minimumAmountOut, requiredAmountOut);
        }

        IERC20 tokenIn = IERC20(order.input.token);
        IERC20 tokenOut = IERC20(outputToken);
        uint256 outputBefore = tokenOut.balanceOf(address(this));
        for (uint256 i; i < fillCall.routes.length; ++i) {
            FillRoute memory route = fillCall.routes[i];
            uint256 routeOutputBefore = tokenOut.balanceOf(address(this));
            tokenIn.safeTransfer(route.adapter, route.amountIn);
            ILiquidLaneAdapter(route.adapter)
                .swap(
                    ILiquidLaneAdapter.Swap({
                        recipient: address(this),
                        tokenIn: order.input.token,
                        amountIn: route.amountIn,
                        amountOut: route.amountOut
                    })
                );
            uint256 amountOut = tokenOut.balanceOf(address(this)) - routeOutputBefore;
            if (amountOut < route.amountOut) {
                revert RouteOutputTooLow(route.adapter, route.amountOut, amountOut);
            }
            emit InputRedeemed(order.hash, route.adapter, order.input.token, outputToken, route.amountIn, amountOut);
        }
        for (uint256 i; i < fillCall.discountRoutes.length; ++i) {
            DiscountRoute memory route = fillCall.discountRoutes[i];
            uint256 routeOutputBefore = tokenOut.balanceOf(address(this));
            tokenIn.safeTransfer(route.adapter, route.amountIn);
            ILiquidLaneAdapter(route.adapter)
                .swap(route.discountSwap, route.protocolSignature, address(this), route.amountIn);
            uint256 amountOut = tokenOut.balanceOf(address(this)) - routeOutputBefore;
            if (amountOut < route.minAmountOut) {
                revert RouteOutputTooLow(route.adapter, route.minAmountOut, amountOut);
            }
            emit InputRedeemed(order.hash, route.adapter, order.input.token, outputToken, route.amountIn, amountOut);
        }

        uint256 outputGained = tokenOut.balanceOf(address(this)) - outputBefore;
        if (outputGained < requiredAmountOut) revert InsufficientOutput(requiredAmountOut, outputGained);
        tokenOut.forceApprove(REACTOR, requiredAmountOut);

        emit OrderFilled(
            order.hash,
            order.input.token,
            outputToken,
            order.input.amount,
            order.input.amount - routedAmountIn,
            requiredAmountOut,
            outputGained - requiredAmountOut
        );
    }

    function setCallers(address[] calldata newCallers) public onlyOwner {
        callers = newCallers;
        emit SetCallers(newCallers);
    }

    function sweepERC20(address token, address to, uint256 amount) external onlyOwner {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
    }

    function _isCaller(address caller) internal view returns (bool) {
        for (uint256 i; i < callers.length; ++i) {
            if (callers[i] == caller) return true;
        }
        return false;
    }

    function _validateFillCall(FillCall memory fillCall, address tokenIn, uint256 orderAmountIn)
        internal
        pure
        returns (uint256 routedAmountIn, uint256 minimumAmountOut)
    {
        if (fillCall.routes.length == 0 && fillCall.discountRoutes.length == 0) revert EmptyRoutes();
        for (uint256 i; i < fillCall.routes.length; ++i) {
            FillRoute memory route = fillCall.routes[i];
            if (route.adapter == address(0)) revert ZeroAddress();
            if (route.amountIn == 0 || route.amountOut == 0) revert InvalidAmount();
            routedAmountIn += route.amountIn;
            minimumAmountOut += route.amountOut;
        }
        for (uint256 i; i < fillCall.discountRoutes.length; ++i) {
            DiscountRoute memory route = fillCall.discountRoutes[i];
            if (route.adapter == address(0)) revert ZeroAddress();
            if (route.amountIn == 0 || route.minAmountOut == 0) revert InvalidAmount();
            if (route.discountSwap.discount.tokenToRedeem != tokenIn) {
                revert DiscountTokenMismatch(tokenIn, route.discountSwap.discount.tokenToRedeem);
            }
            routedAmountIn += route.amountIn;
            minimumAmountOut += route.minAmountOut;
        }
        // Exact-output Dutch input may increase after off-chain planning; retain that positive difference.
        if (routedAmountIn > orderAmountIn) revert RouteInputExceedsOrder(routedAmountIn, orderAmountIn);
    }
}
