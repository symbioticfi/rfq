// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IRecipeExecutor} from "src/interfaces/IRecipeExecutor.sol";
import {IRecipeRoute, IRecipeConnector, LIQUID_LANE_CONNECTOR_VERSION} from "src/interfaces/IRecipeRoute.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Validates connector/account binding, funds connector input, and invokes its committed recipe.
library RecipeExecutorLib {
    using SafeERC20 for IERC20;

    error RecipeExecutorLib__InvalidConnector();
    error RecipeExecutorLib__InvalidAccount();

    function validate(IRecipeRoute.RecipeRoute memory route) internal view {
        if (IRecipeConnector(route.connector).version() != LIQUID_LANE_CONNECTOR_VERSION) {
            revert RecipeExecutorLib__InvalidConnector();
        }
        address account = IRecipeExecutor(route.executor).account();
        if (account == address(0) || IRecipeConnector(route.connector).account() != account) {
            revert RecipeExecutorLib__InvalidAccount();
        }
    }

    function execute(address tokenIn, IRecipeRoute.RecipeRoute memory route) internal {
        validate(route);
        if (route.amountIn != 0) IERC20(tokenIn).safeTransfer(route.connector, route.amountIn);
        // Numerical results belong to the recipe; settlement checks the actual output transfers.
        IRecipeExecutor(route.executor).execute(route.queries, route.steps, route.inputs, route.runtime);
    }
}
