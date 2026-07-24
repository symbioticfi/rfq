// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {LiquidLaneLifiExecutor} from "../../../src/lifi/LiquidLaneLifiExecutor.sol";

contract DeployLifiExecutorBaseScript is Script {
    struct DeployParams {
        address inputSettler;
        address outputSettler;
        address admin;
        address proxyAdminOwner;
        address caller;
    }

    struct DeploymentData {
        LiquidLaneLifiExecutor executor;
        address implementation;
        address inputSettler;
        address outputSettler;
        address admin;
        address proxyAdminOwner;
        address caller;
    }

    function runBase(DeployParams memory params) public virtual returns (DeploymentData memory data) {
        _validateParams(params);

        address[] memory callers = new address[](1);
        callers[0] = params.caller;

        _startBroadcast();
        LiquidLaneLifiExecutor implementation = new LiquidLaneLifiExecutor(params.inputSettler, params.outputSettler);
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            params.proxyAdminOwner,
            abi.encodeCall(LiquidLaneLifiExecutor.initialize, (params.admin, callers))
        );
        _stopBroadcast();

        data.executor = LiquidLaneLifiExecutor(address(proxy));
        data.implementation = address(implementation);
        data.inputSettler = params.inputSettler;
        data.outputSettler = params.outputSettler;
        data.admin = params.admin;
        data.proxyAdminOwner = params.proxyAdminOwner;
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
        require(params.inputSettler != address(0), "invalid input settler");
        require(params.outputSettler != address(0), "invalid output settler");
        require(params.admin != address(0), "invalid admin");
        require(params.proxyAdminOwner != address(0), "invalid proxy admin owner");
        require(params.caller != address(0), "invalid caller");
    }

    function _validateDeployment(DeploymentData memory data) internal view {
        assert(data.executor.owner() == data.admin);
        assert(data.executor.INPUT_SETTLER() == data.inputSettler);
        assert(data.executor.OUTPUT_SETTLER() == data.outputSettler);
        assert(data.executor.isCaller(data.caller));
    }

    function _logDeployment(DeploymentData memory data) internal view {
        console2.log("Deployed LI.FI Executor");
        console2.log("  executor:        ", address(data.executor));
        console2.log("  implementation:  ", data.implementation);
        console2.log("  inputSettler:    ", data.inputSettler);
        console2.log("  outputSettler:   ", data.outputSettler);
        console2.log("  admin:           ", data.admin);
        console2.log("  proxyAdminOwner: ", data.proxyAdminOwner);
        console2.log("  caller:          ", data.caller);
    }
}
