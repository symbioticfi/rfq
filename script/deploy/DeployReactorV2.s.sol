// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Script, console2} from "forge-std/Script.sol";
import {ReactorV2} from "src/ReactorV2.sol";

/// @notice Deploy with an encrypted Foundry account and explicit chain-specific dependencies.
contract DeployReactorV2Script is Script {
    function run(address permit2, address adapterFactory, address connectorFactory) public returns (ReactorV2 reactor) {
        vm.startBroadcast();
        reactor = new ReactorV2(permit2, adapterFactory, connectorFactory);
        vm.stopBroadcast();

        console2.log("ReactorV2:", address(reactor));
        console2.log("Permit2:", address(reactor.PERMIT2()));
        console2.log("LL adapter factory:", reactor.LL_ADAPTER_FACTORY());
        console2.log("LL connector factory:", reactor.LL_CONNECTOR_FACTORY());
    }
}
