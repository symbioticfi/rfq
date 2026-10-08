// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IRecipes} from "src/interfaces/IRecipes.sol";

import {IMulticallable} from "@symbioticfi/core/src/interfaces/common/IMulticallable.sol";

/**
 * @title IRecipeExecutor
 * @notice Interface for curator-committed programs of approved actions and state conditions.
 */
interface IRecipeExecutor is IRecipes, IMulticallable {
    /* ERRORS */

    /**
     * @notice Raised when a token returns false for an approval.
     */
    error ApprovalFailed();

    /**
     * @notice Raised when the final action differs from its configured leaf or carries native value.
     */
    error InvalidAction();

    /**
     * @notice Raised when the selected operator is not the caller.
     */
    error InvalidCaller();

    /**
     * @notice Raised when the recipe differs from the curator's current commitment.
     */
    error InvalidRecipe();

    /* EVENTS */

    /**
     * @notice Emitted when the owner selects an operator; zero disables execution.
     */
    event SetCaller(address indexed caller);
    /**
     * @notice Emitted when the owner replaces the commitment and publishes the complete recipe.
     */
    event SetRecipe(bytes32 indexed recipeHash, bytes[] queries, bytes[] steps);

    /* FUNCTIONS */

    /**
     * @notice Returns the account permanently bound to this executor.
     */
    function account() external view returns (address);
    /**
     * @notice Returns the operator permitted to execute.
     */
    function caller() external view returns (address);
    /**
     * @notice Returns keccak256(abi.encode(queries, steps)), or zero before configuration.
     */
    function recipeHash() external view returns (bytes32);
    /**
     * @notice Returns the block containing the latest SetRecipe event, or zero before configuration.
     */
    function recipeBlock() external view returns (uint48);
    /**
     * @notice Selects the operator; owner-only and unavailable during execution.
     */
    function setCaller(address newCaller) external;
    /**
     * @notice Commits and publishes a recipe; owner-only and unavailable during execution.
     * @param newQueries Shared STATICCALL templates, each abi.encode(address target, bytes data,
     * uint256[] bindings, uint256 offset). Offset selects a complete return-data word in bytes;
     * alignment is not required. Each query is decoded afresh before applying its bindings.
     * @param newSteps Instructions in execution order.
     * @dev Stores no queries or instructions. The hash occupies one slot and the uint48 event block
     * shares another with caller, independent of program size. An explicitly configured empty recipe
     * is a no-op. Changes apply to pending executions: previously supplied recipes fail unless their
     * complete contents are unchanged.
     */
    function setRecipe(bytes[] calldata newQueries, bytes[] calldata newSteps) external;
    /**
     * @notice Authenticates the supplied recipe and executes its instructions atomically.
     * @param queries Shared encoded queries recovered from SetRecipe or a verified cache.
     * @param steps Curator-committed instructions, authenticated together with queries.
     * @param inputs Numerical inputs constrained by the configured calls and assertions.
     * @param runtime One entry per Manage or Approve instruction, in order. Manage decodes
     * IMerkleAccount.Action[]; Approve decodes (bytes dataMask, bytes32[] proof). A zero Manage gate
     * still consumes its entry but does not decode it. Reads, arithmetic, assertions and Call need
     * no runtime entry.
     * @return values Results by instruction index; effects and assertions have unused zero slots.
     * @dev Checks caller and recipe hash before any external query or action. Only prior Read
     * through MulDiv results may be referenced. Managed actions are bound then matched against
     * their exact configured leaves; the account validates current proofs and roles; bridge push checks reserves.
     * Approval resets and optional bool return handling run through the account. Call uses a fixed
     * template and target from the executor and sends no native value. Manage and Approve reject native-value
     * actions. The interpreter never delegatecalls; downstream contracts retain their separately authorized powers.
     * Every failure rolls back the entire execution, including external policy and protocol state.
     */
    function execute(
        bytes[] calldata queries,
        bytes[] calldata steps,
        uint256[] calldata inputs,
        bytes[] calldata runtime
    ) external returns (uint256[] memory values);
}
