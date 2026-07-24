// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.28;

import {DeployUniswapXExecutorBaseScript} from "./deploy/base/DeployUniswapXExecutorBase.s.sol";

// forge script script/DeployUniswapXExecutor.s.sol:DeployUniswapXExecutorScript --rpc-url=RPC --broadcast

contract DeployUniswapXExecutorScript is DeployUniswapXExecutorBaseScript {
    // Configurations - UPDATE THESE BEFORE DEPLOYMENT

    // Deployed UniswapX Reactor address this Executor forwards fills to.
    address public constant REACTOR = 0x0000000000000000000000000000000000000000;
    // Executor owner.
    address public constant ADMIN = 0x0000000000000000000000000000000000000000;
    // Proxy admin owner allowed to upgrade the executor proxy.
    address public constant PROXY_ADMIN_OWNER = 0x0000000000000000000000000000000000000000;
    // Initial caller allowed to invoke fill entrypoints.
    address public constant CALLER = 0x0000000000000000000000000000000000000000;

    function run() public returns (DeploymentData memory data) {
        data =
            runBase(DeployParams({reactor: REACTOR, admin: ADMIN, proxyAdminOwner: PROXY_ADMIN_OWNER, caller: CALLER}));
    }
}
