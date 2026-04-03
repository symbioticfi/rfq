// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";

import {Reactor} from "../../src/Reactor.sol";

// forge script rfq/reactor/script/deploy/DeployReactor.s.sol:DeployReactorScript --rpc-url=RPC --private-key PRIVATE_KEY --broadcast
contract DeployReactorScript is Script {
    function run() public returns (Reactor reactor) {
        address irAdapter = vm.envAddress("IR_ADAPTER");
        address permit2 = vm.envAddress("PERMIT2");

        vm.startBroadcast();
        reactor = new Reactor(irAdapter, permit2);
        vm.stopBroadcast();

        console2.log("Deployed Reactor:", address(reactor));
    }
}
