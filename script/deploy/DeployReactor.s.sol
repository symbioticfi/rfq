// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";

import {Reactor} from "../../src/Reactor.sol";

// forge script rfq/reactor/script/deploy/DeployReactor.s.sol:DeployReactorScript --rpc-url=RPC --private-key PRIVATE_KEY --broadcast
contract DeployReactorScript is Script {
    function run() public returns (Reactor reactor) {
        address liquidLaneAdapterFactory = vm.envAddress("LIQUID_LANE_ADAPTER_FACTORY");

        vm.startBroadcast();
        reactor = new Reactor(liquidLaneAdapterFactory);
        vm.stopBroadcast();

        console2.log("Deployed Reactor:", address(reactor));
    }
}
