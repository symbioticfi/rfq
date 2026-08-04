// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";

import {Router} from "../../src/Router.sol";

/// @notice Deploys the ownerless, EIP-712-authenticated user-directed Router.
contract DeployRouterScript is Script {
    function run() public returns (Router router) {
        address liquidLaneAdapterFactory = vm.envAddress("LIQUID_LANE_ADAPTER_FACTORY");

        vm.startBroadcast();
        router = new Router(liquidLaneAdapterFactory);
        vm.stopBroadcast();

        console2.log("Deployed Router:", address(router));
    }
}
