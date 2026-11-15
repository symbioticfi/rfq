// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DeployRouterBaseScript} from "./base/DeployRouterBase.s.sol";

// forge script script/deploy/DeployRouter.s.sol:DeployRouterScript --rpc-url=RPC --broadcast
contract DeployRouterScript is DeployRouterBaseScript {
    function run() public returns (DeploymentData memory data) {
        data = runBase();
    }
}
