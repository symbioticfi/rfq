// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";

import {Executor} from "../../../src/Executor.sol";

contract DeployExecutorBaseScript is Script {
    struct DeployParams {
        address reactor;
        address admin;
        address caller;
    }

    struct DeploymentData {
        Executor executor;
        address reactor;
        address admin;
        address caller;
    }

    function runBase(DeployParams memory params) public virtual returns (DeploymentData memory data) {
        _validateParams(params);

        address[] memory callers = new address[](1);
        callers[0] = params.caller;

        _startBroadcast();
        data.executor = new Executor(params.reactor, params.admin, callers);
        _stopBroadcast();

        data.reactor = params.reactor;
        data.admin = params.admin;
        data.caller = params.caller;

        _validateDeployment(data);
        _logDeployment(data);
    }

    function _startBroadcast() internal virtual {
        vm.startBroadcast();
    }

    function _stopBroadcast() internal virtual {
        vm.stopBroadcast();
    }

    function _scriptOwner() internal view virtual returns (address owner_) {
        (,, address origin) = vm.readCallers();
        owner_ = origin == address(0) ? msg.sender : origin;
    }

    function _validateParams(DeployParams memory params) internal pure {
        require(params.reactor != address(0), "invalid reactor");
        require(params.admin != address(0), "invalid admin");
        require(params.caller != address(0), "invalid caller");
    }

    function _validateDeployment(DeploymentData memory data) internal view {
        assert(data.executor.owner() == data.admin);
        assert(data.executor.callers(0) == data.caller);
    }

    function _logDeployment(DeploymentData memory data) internal view {
        console2.log("Deployed RFQ Executor");
        console2.log("  executor: ", address(data.executor));
        console2.log("  reactor:  ", data.reactor);
        console2.log("  admin:    ", data.admin);
        console2.log("  caller:   ", data.caller);
    }
}
