// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/// @dev LiquidLaneConnector implementation registered as version 2 in LiquidLaneAdapterFactory.
uint64 constant LIQUID_LANE_CONNECTOR_VERSION = 2;

/**
 * @title IRecipeRoute
 * @notice Shared execution schema for committed RecipeExecutor swaps.
 */
interface IRecipeRoute {
    /**
     * @notice A committed RecipeExecutor invocation after input legs fund their connectors.
     * @dev The authorized caller selects the funding recipient and recipe. The RFQ executors
     * do not validate connector versions or account bindings; downstream contracts enforce their rules.
     * @param executor RecipeExecutor to invoke.
     * @param connector Caller-selected input recipient; native RFQ requires Reactor factory membership.
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
