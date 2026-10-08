// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.0;

import {IUniswapXReactorCallback, UniswapXSignedOrder} from "./IUniswapXReactor.sol";

import {ILiquidLaneAdapter} from "../../interfaces/ILiquidLaneAdapter.sol";
import {IRecipeRoute} from "src/interfaces/IRecipeRoute.sol";

interface ILiquidLaneUniswapXExecutor is IUniswapXReactorCallback {
    error NotCaller();
    error NotReactor();

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
        ILiquidLaneAdapter.DiscountSwap discountSwap;
        bytes protocolSignature;
    }

    event SetCallers(address[] newCallers);

    function initialize(address owner, address[] calldata initCallers) external;
    function callers(uint256 index) external view returns (address caller);
    function execute(UniswapXSignedOrder calldata order, FillCall calldata fillCall) external;
    /**
     * @notice Sources output through LiquidLane legs followed by committed RecipeExecutor routes.
     */
    function execute(
        UniswapXSignedOrder calldata order,
        FillCall calldata fillCall,
        IRecipeRoute.RecipeRoute[] calldata recipeRoutes
    ) external;
    function setCallers(address[] calldata newCallers) external;
}
