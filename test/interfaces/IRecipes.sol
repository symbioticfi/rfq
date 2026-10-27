// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/**
 * @dev Operand sources: literal uint216, execution input, or earlier numerical instruction result.
 */
uint8 constant SRC_LITERAL = 0;
uint8 constant SRC_INPUT = 1;
uint8 constant SRC_RESULT = 2;

/**
 * @dev OP_READ through OP_MUL_DIV produce numbers; later operations cannot be referenced.
 * OP_SUB is checked; OP_SATURATING_SUB floors at zero; OP_MUL_DIV checks multiplication for overflow,
 * then divides rounding down.
 */
uint8 constant OP_READ = 0;
uint8 constant OP_ADD = 1;
uint8 constant OP_SUB = 2;
uint8 constant OP_SATURATING_SUB = 3;
uint8 constant OP_MIN = 4;
uint8 constant OP_MAX = 5;
uint8 constant OP_MUL_DIV = 6;
uint8 constant OP_EQUAL = 7;
uint8 constant OP_LESS_OR_EQUAL = 8;
uint8 constant OP_MANAGE = 9;
uint8 constant OP_APPROVE = 10;
uint8 constant OP_CALL = 11;

/**
 * @title IRecipes
 * @notice Interface for the shared instruction schema of committed executor and account capability recipes.
 * @dev Each step is bytes.concat(bytes1(operation), abi.encode(...)) with these payloads:
 * OP_READ: abi.encode(uint256 queryIndex).
 * OP_ADD/OP_SUB/OP_SATURATING_SUB/OP_MIN/OP_MAX/OP_EQUAL/OP_LESS_OR_EQUAL: abi.encode(uint256 a, uint256 b).
 * OP_MUL_DIV: abi.encode(uint256 a, uint256 b, uint256 denominator).
 * OP_MANAGE: abi.encode(uint256 gate, bytes32[] orderedLeaves, uint256[][] bindings).
 * OP_APPROVE: abi.encode(uint256 amount, address token, address spender, bytes32 leaf).
 * OP_CALL: abi.encode(address target, bytes template, uint256[] bindings).
 * Numerical operands occupy the lowest 28 bytes: (uint256(src) << 216) | value, where src is uint8
 * and the literal or index must fit uint216. Inputs and results retain all 256 bits.
 * Each binding packs a uint32 byte offset above the operand: (uint256(offset) << 224) | srcAndValue.
 * Offsets are at least four; bindings must be sorted, nonoverlapping, and fully in bounds for a 32-byte write.
 * Operand resolution ignores the highest four bytes, which contain the offset in bindings and are zero
 * in standalone operands produced by builders. OP_MANAGE keeps one atomic account group; a zero gate skips only that group.
 * OP_CALL uses a committed template from the current execution address. OP_MANAGE and OP_APPROVE are executor-only.
 */
interface IRecipes {
    /* ERRORS */

    /**
     * @notice Raised when a required comparison fails.
     */
    error CheckFailed();

    /**
     * @notice Raised when bindings overlap, replace the selector, or extend outside calldata.
     */
    error InvalidCall();

    /**
     * @notice Raised when an instruction is not supported by this execution context.
     */
    error InvalidOperation();

    /**
     * @notice Raised when a query returns less than one complete word at the configured offset.
     */
    error InvalidQuery();

    /**
     * @notice Raised when an operand has an unknown source or does not reference an earlier numerical instruction.
     */
    error InvalidReference();

    /**
     * @notice Raised when runtime or managed-action counts differ from the program.
     */
    error InvalidRuntime();

    /* STRUCTS */

    /**
     * @notice Memory-only state shared by operand resolution and calldata substitution.
     * @param values Results indexed by instruction; nonnumerical entries cannot be referenced.
     * @param index Current instruction index, excluding all self and future references.
     */
    struct State {
        uint256[] values;
        uint256 index;
    }
}
