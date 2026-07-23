// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {MandateOutput} from "./IOutputSettler.sol";

/**
 * @title IInputSettler
 * @notice Minimal OIF InputSettler surface used by the LI.FI executor.
 */
interface IInputSettler {
    struct StandardOrder {
        address user;
        uint256 nonce;
        uint256 originChainId;
        uint32 expires;
        uint32 fillDeadline;
        address inputOracle;
        uint256[2][] inputs;
        MandateOutput[] outputs;
    }

    struct SolveParams {
        uint32 timestamp;
        bytes32 solver;
    }

    function orderIdentifier(StandardOrder calldata order) external view returns (bytes32 orderId);

    function finalise(
        StandardOrder calldata order,
        SolveParams[] calldata solveParams,
        bytes32 destination,
        bytes calldata call
    ) external;
}
