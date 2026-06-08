// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";

import {Executor} from "../../src/Executor.sol";

// forge script rfq/reactor/script/deploy/DeployExecutor.s.sol:DeployExecutorScript --rpc-url=RPC --private-key PRIVATE_KEY --broadcast
contract DeployExecutorScript is Script {
    function run() public returns (Executor executor) {
        address reactor = vm.envAddress("REACTOR");
        address admin = vm.envAddress("ADMIN");
        address caller = vm.envAddress("CALLER");
        address[] memory callers = new address[](1);
        callers[0] = caller;

        vm.startBroadcast();
        executor = new Executor(reactor, admin, callers);
        vm.stopBroadcast();

        console2.log("Deployed Executor:", address(executor));
    }
}
