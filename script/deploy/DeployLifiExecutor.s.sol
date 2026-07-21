// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {LiquidLaneLifiExecutor} from "../../src/lifi/LiquidLaneLifiExecutor.sol";

// forge script rfq/reactor/script/deploy/DeployLifiExecutor.s.sol:DeployLifiExecutorScript --rpc-url=RPC --private-key PRIVATE_KEY --broadcast
contract DeployLifiExecutorScript is Script {
    function run() public returns (LiquidLaneLifiExecutor executor, address implementation) {
        address inputSettler = vm.envAddress("INPUT_SETTLER");
        address outputSettler = vm.envAddress("OUTPUT_SETTLER");
        address admin = vm.envAddress("ADMIN");
        address proxyAdminOwner = vm.envAddress("PROXY_ADMIN_OWNER");

        vm.startBroadcast();
        LiquidLaneLifiExecutor impl = new LiquidLaneLifiExecutor(inputSettler, outputSettler);
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(impl), proxyAdminOwner, abi.encodeCall(LiquidLaneLifiExecutor.initialize, (admin))
        );
        vm.stopBroadcast();

        implementation = address(impl);
        executor = LiquidLaneLifiExecutor(address(proxy));

        console2.log("Deployed LiquidLaneLifiExecutor implementation:", implementation);
        console2.log("Deployed LiquidLaneLifiExecutor proxy:", address(executor));
    }
}
