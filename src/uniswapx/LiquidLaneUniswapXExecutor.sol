// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.28;

import {ILiquidLaneAdapter} from "../interfaces/ILiquidLaneAdapter.sol";
import {ILiquidLaneUniswapXExecutor} from "./interfaces/ILiquidLaneUniswapXExecutor.sol";
import {IUniswapXReactor, UniswapXResolvedOrder, UniswapXSignedOrder} from "./interfaces/IUniswapXReactor.sol";

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/// @title LiquidLaneUniswapXExecutor
/// @notice UniswapX Reactor callback that atomically sources outputs from LiquidLane adapters.
contract LiquidLaneUniswapXExecutor is Initializable, OwnableUpgradeable, ILiquidLaneUniswapXExecutor {
    using Address for address payable;
    using SafeERC20 for IERC20;

    address internal immutable REACTOR;
    address[] public callers;

    constructor(address reactor) {
        REACTOR = reactor;
        _disableInitializers();
    }

    function initialize(address owner, address[] calldata initCallers) external initializer {
        __Ownable_init(owner);
        callers = initCallers;
    }

    modifier onlyCaller() {
        if (!_isCaller(msg.sender)) revert NotCaller();
        _;
    }

    function execute(UniswapXSignedOrder calldata order, FillCall calldata fillCall) public onlyCaller {
        IUniswapXReactor(REACTOR).executeWithCallback(order, abi.encode(fillCall));
    }

    function reactorCallback(UniswapXResolvedOrder[] memory resolvedOrders, bytes memory callbackData) external {
        if (msg.sender != REACTOR) revert NotReactor();

        FillCall memory fillCall = abi.decode(callbackData, (FillCall));
        address tokenIn = resolvedOrders[0].input.token;

        uint256 routesLength = fillCall.routes.length;
        for (uint256 i; i < routesLength; ++i) {
            FillRoute memory route = fillCall.routes[i];
            IERC20(tokenIn).safeTransfer(route.adapter, route.amountIn);
            ILiquidLaneAdapter(route.adapter)
                .swap(
                    ILiquidLaneAdapter.Swap({
                    recipient: address(this), tokenIn: tokenIn, amountIn: route.amountIn, amountOut: route.amountOut
                })
                );
        }
        uint256 discountRoutesLength = fillCall.discountRoutes.length;
        for (uint256 i; i < discountRoutesLength; ++i) {
            DiscountRoute memory route = fillCall.discountRoutes[i];
            IERC20(tokenIn).safeTransfer(route.adapter, route.amountIn);
            ILiquidLaneAdapter(route.adapter)
                .swap(route.discountSwap, route.protocolSignature, address(this), route.amountIn);
        }

        uint256 outputsLength = resolvedOrders[0].outputs.length;
        for (uint256 i; i < outputsLength; ++i) {
            address token = resolvedOrders[0].outputs[i].token;
            // Native output (address(0)) is forwarded below; only ERC-20 outputs need a Reactor allowance.
            if (token != address(0) && IERC20(token).allowance(address(this), REACTOR) < type(uint256).max) {
                IERC20(token).forceApprove(REACTOR, type(uint256).max);
            }
        }

        uint256 balance = address(this).balance;
        if (balance > 0) payable(REACTOR).sendValue(balance);
    }

    function setCallers(address[] calldata newCallers) public onlyOwner {
        callers = newCallers;
        emit SetCallers(newCallers);
    }

    function _isCaller(address caller) internal view returns (bool) {
        uint256 callersLength = callers.length;
        for (uint256 i; i < callersLength; ++i) {
            if (callers[i] == caller) return true;
        }
        return false;
    }

    receive() external payable {}
}
