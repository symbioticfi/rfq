// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IRecipeExecutor} from "src/interfaces/IRecipeExecutor.sol";
import {IRecipeRoute} from "src/interfaces/IRecipeRoute.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Funds the caller-selected input recipient and invokes RecipeExecutor.
library RecipeExecutorLib {
    using SafeERC20 for IERC20;

    function execute(address tokenIn, IRecipeRoute.RecipeRoute memory route) internal {
        if (route.amountIn != 0) IERC20(tokenIn).safeTransfer(route.connector, route.amountIn);
        // Numerical results belong to the recipe; settlement checks the actual output transfers.
        IRecipeExecutor(route.executor).execute(route.queries, route.steps, route.inputs, route.runtime);
    }
}
