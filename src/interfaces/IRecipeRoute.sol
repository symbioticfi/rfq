// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IMigratableEntity} from "@symbioticfi/core/src/interfaces/common/IMigratableEntity.sol";

/// @dev LiquidLaneConnector implementation registered as version 2 in LiquidLaneAdapterFactory.
uint64 constant LIQUID_LANE_CONNECTOR_VERSION = 2;

/// @notice Read interface for the version 2, account-bound LiquidLane connector.
interface IRecipeConnector is IMigratableEntity {
    function account() external view returns (address);
}

/**
 * @title IRecipeRoute
 * @notice Shared execution schema for committed RecipeExecutor swaps.
 */
interface IRecipeRoute {
    /**
     * @notice A committed RecipeExecutor invocation after input legs fund their connectors.
     * @dev Configure its caller as the RFQ/LI.FI/UniswapX executor. The bound account performs
     * all version 2 connector actions through the recipe and returns output for settlement.
     * @param executor RecipeExecutor to invoke.
     * @param connector Version 2 LiquidLaneConnector bound to the same account.
     * @param amountIn Input-token amount funded into the connector before recipe execution.
     * @param queries Committed query templates.
     * @param steps Committed instructions.
     * @param inputs Numerical execution inputs.
     * @param runtime Runtime payloads required by the instructions.
     */
    struct RecipeRoute {
        address executor;
        address connector;
        uint256 amountIn;
        bytes[] queries;
        bytes[] steps;
        uint256[] inputs;
        bytes[] runtime;
    }
}
