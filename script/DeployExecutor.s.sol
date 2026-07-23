// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DeployExecutorBaseScript} from "./deploy/base/DeployExecutorBase.s.sol";

// forge script script/DeployExecutor.s.sol:DeployExecutorScript --rpc-url=RPC --broadcast

contract DeployExecutorScript is DeployExecutorBaseScript {
    // Configurations - UPDATE THESE BEFORE DEPLOYMENT

    // Deployed Reactor address this Executor forwards fills to.
    address public constant REACTOR = 0xC323B898d7E4105E3980082B74CC5D4602996B10;
    // Executor owner. Defaults to the sender when left zero.
    address public constant ADMIN = 0x0000000000000000000000000000000000000000;
    // Initial caller allowed to invoke fill entrypoints. Defaults to the sender when left zero.
    address public constant CALLER = 0x0000000000000000000000000000000000000000;

    function run() public returns (DeploymentData memory data) {
        address owner = _scriptOwner();
        data = runBase(
            DeployParams({
                reactor: REACTOR,
                admin: ADMIN == address(0) ? owner : ADMIN,
                caller: CALLER == address(0) ? owner : CALLER
            })
        );
    }
}
