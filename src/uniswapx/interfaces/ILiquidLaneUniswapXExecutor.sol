// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.0;

import {ILiquidLaneAdapter} from "../../interfaces/ILiquidLaneAdapter.sol";
import {IUniswapXReactorCallback, UniswapXSignedOrder} from "./IUniswapXReactor.sol";

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
    function setCallers(address[] calldata newCallers) external;
}
