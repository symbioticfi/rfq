// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {Executor} from "../../src/Executor.sol";

// forge script rfq/reactor/script/deploy/DeployExecutor.s.sol:DeployExecutorScript --rpc-url=RPC --private-key PRIVATE_KEY --broadcast
contract DeployExecutorScript is Script {
    function run() public returns (Executor executor, address implementation) {
        address reactor = vm.envAddress("REACTOR");
        address admin = vm.envAddress("ADMIN");
        address proxyAdminOwner = vm.envAddress("PROXY_ADMIN_OWNER");
        address caller = vm.envAddress("CALLER");
        address[] memory callers = new address[](1);
        callers[0] = caller;

        vm.startBroadcast();
        Executor impl = new Executor(reactor);
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(impl), proxyAdminOwner, abi.encodeCall(Executor.initialize, (admin, callers))
        );
        vm.stopBroadcast();

        implementation = address(impl);
        executor = Executor(payable(address(proxy)));

        console2.log("Deployed Executor implementation:", implementation);
        console2.log("Deployed Executor proxy:", address(executor));
    }
}
