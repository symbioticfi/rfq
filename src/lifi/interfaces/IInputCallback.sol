// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IInputCallback
 * @notice OIF callback invoked after an input settler transfers order inputs to the destination.
 */
interface IInputCallback {
    /**
     * @notice Handles order inputs delivered to the callback destination.
     * @param inputs Order input token ids and amounts.
     * @param executionData Callback-specific execution data.
     */
    function orderFinalised(uint256[2][] calldata inputs, bytes calldata executionData) external;
}
