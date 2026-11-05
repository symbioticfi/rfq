// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.0;

import {IInputCallback} from "./IInputCallback.sol";
import {IInputSettler} from "./IInputSettler.sol";
import {MandateOutput} from "./IOutputSettler.sol";

import {IExecutor} from "src/interfaces/IExecutor.sol";

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

/**
 * @title ILiquidLaneLifiExecutor
 * @notice LI.FI same-chain solver and executor callback for on-chain orders.
 */
interface ILiquidLaneLifiExecutor is IInputCallback, IERC1271 {
    /* ERRORS */

    error NotCaller();

    error NotInputSettler();

    /* EVENTS */

    event SetCallers(address[] newCallers);

    /* STRUCTS */

    /// @notice Order data needed by the settlement callback.
    struct FillCall {
        bytes32 orderId;
        MandateOutput output;
        uint32 fillDeadline;
    }

    /* FUNCTIONS */

    function INPUT_SETTLER() external view returns (address inputSettler);
    function OUTPUT_SETTLER() external view returns (address outputSettler);
    function callers(uint256 index) external view returns (address caller);
    function initialize(address owner, address[] calldata initCallers) external;
    /// @notice Executes caller-supplied calls after receiving inputs, then settles the order output.
    function finaliseWithCurrentTimestamp(IInputSettler.StandardOrder calldata order, IExecutor.Call[] calldata calls)
        external;
    function isCaller(address caller) external view returns (bool allowed);
    function lifiRegistrationDigest(bytes32 messageHash) external view returns (bytes32 digest);
    function setCallers(address[] calldata newCallers) external;
}
