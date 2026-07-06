// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DeployReactorBaseScript} from "./base/DeployReactorBase.s.sol";

// forge script script/deploy/DeployReactor.s.sol:DeployReactorScript --rpc-url=RPC --broadcast
contract DeployReactorScript is DeployReactorBaseScript {
    function run() public returns (DeploymentData memory data) {
        data = runBase();
    }
}
