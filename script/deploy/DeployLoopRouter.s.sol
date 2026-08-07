// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DeployLoopRouterBaseScript} from "./base/DeployLoopRouterBase.s.sol";

// forge script script/deploy/DeployLoopRouter.s.sol:DeployLoopRouterScript --rpc-url=RPC --broadcast
contract DeployLoopRouterScript is DeployLoopRouterBaseScript {
    function run() public returns (DeploymentData memory data) {
        data = runBase();
    }
}
