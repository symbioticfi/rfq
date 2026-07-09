// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";

import {SymbioticOevSolver} from "../../src/oev/SymbioticOevSolver.sol";

interface ISetFiller {
    function setFiller(address filler, bool ok) external;
}

// Deploys a SymbioticOevSolver callback against an existing Executor / Morpho / LiquidLane adapter and
// blesses it as the adapter's filler. The broadcaster must be the adapter curator (the deployment owner).
// forge script script/deploy/DeployOevSolver.s.sol:DeployOevSolverScript --rpc-url=RPC --private-key KEY --broadcast
contract DeployOevSolverScript is Script {
    function run() public returns (SymbioticOevSolver callback) {
        address executor = vm.envAddress("EXECUTOR");
        address morpho = vm.envAddress("MORPHO");
        address adapter = vm.envAddress("LIQUID_LANE_ADAPTER");
        address owner = vm.envAddress("OWNER");
        address authSigner = vm.envOr("AUTH_SIGNER", owner);

        vm.startBroadcast();
        callback = new SymbioticOevSolver(executor, morpho, adapter, authSigner, owner);
        ISetFiller(adapter).setFiller(address(callback), true); // adapter curator blesses the callback as a filler
        vm.stopBroadcast();

        console2.log("Deployed SymbioticOevSolver:", address(callback));
    }
}
