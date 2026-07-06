// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DeployExecutorBaseScript} from "./base/DeployExecutorBase.s.sol";

// forge script script/deploy/DeployExecutor.s.sol:DeployExecutorScript --rpc-url=RPC --broadcast

contract DeployExecutorScript is DeployExecutorBaseScript {
    // Configurations - UPDATE THESE BEFORE DEPLOYMENT

    // Deployed Reactor address this Executor forwards fills to.
    address public constant REACTOR = 0x5eB54c47837cC84249F697e3CD8C5D88bCc35dac;
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
