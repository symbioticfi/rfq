// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";

import {RfqDeployConfig} from "../RfqDeployConfig.sol";
import {Reactor} from "../../../src/Reactor.sol";

contract DeployReactorBaseScript is Script {
    struct DeployParams {
        address liquidLaneAdapterFactory;
    }

    struct DeploymentData {
        address liquidLaneAdapterFactory;
        Reactor reactor;
    }

    function runBase() public virtual returns (DeploymentData memory data) {
        data = runBase(DeployParams({liquidLaneAdapterFactory: RfqDeployConfig.currentLiquidLaneAdapterFactory()}));
    }

    function runBase(DeployParams memory params) public virtual returns (DeploymentData memory data) {
        _validateParams(params);

        data.liquidLaneAdapterFactory = params.liquidLaneAdapterFactory;

        _startBroadcast();
        data.reactor = new Reactor(params.liquidLaneAdapterFactory);
        _stopBroadcast();

        _validateDeployment(data);
        _logDeployment(data);
    }

    function _startBroadcast() internal virtual {
        vm.startBroadcast();
    }

    function _stopBroadcast() internal virtual {
        vm.stopBroadcast();
    }

    function _validateParams(DeployParams memory params) internal pure {
        require(params.liquidLaneAdapterFactory != address(0), "invalid LiquidLane adapter factory");
    }

    function _validateDeployment(DeploymentData memory data) internal view {
        assert(data.reactor.LIQUID_LANE_ADAPTER_FACTORY() == data.liquidLaneAdapterFactory);
    }

    function _logDeployment(DeploymentData memory data) internal view {
        console2.log("Deployed RFQ Reactor");
        console2.log("  reactor:                    ", address(data.reactor));
        console2.log("  liquidLaneAdapterFactory:   ", data.liquidLaneAdapterFactory);
    }
}
