// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @notice OIF output description used by LI.FI same-chain intents.
 */
struct MandateOutput {
    bytes32 oracle;
    bytes32 settler;
    uint256 chainId;
    bytes32 token;
    uint256 amount;
    bytes32 recipient;
    bytes callbackData;
    bytes context;
}

/**
 * @title IOutputSettler
 * @notice Minimal OIF OutputSettler surface used by the LI.FI callback.
 */
interface IOutputSettler {
    /**
     * @notice Fills one output and transfers the output token from the caller.
     * @param orderId OIF order id.
     * @param output Output to satisfy.
     * @param fillDeadline Fill deadline carried by the order.
     * @param fillerData Solver identifier.
     * @return fillRecordHash Output settler fill record hash.
     */
    function fill(bytes32 orderId, MandateOutput calldata output, uint48 fillDeadline, bytes calldata fillerData)
        external
        payable
        returns (bytes32 fillRecordHash);

    /**
     * @notice Stores a same-chain attestation for a filled output.
     * @param orderId OIF order id.
     * @param solver Solver identifier.
     * @param timestamp Fill timestamp.
     * @param output Filled output.
     */
    function setAttestation(bytes32 orderId, bytes32 solver, uint32 timestamp, MandateOutput calldata output) external;
}
