// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.28;

import {DeployUniswapXExecutorBaseScript} from "./deploy/base/DeployUniswapXExecutorBase.s.sol";

contract DeployUniswapXExecutorScript is DeployUniswapXExecutorBaseScript {
    function run() public returns (DeploymentData memory data) {
        address owner = _scriptOwner();
        data = runBase(
            DeployParams({
                reactor: vm.envAddress("UNISWAPX_REACTOR"),
                admin: vm.envOr("ADMIN", owner),
                proxyAdminOwner: vm.envOr("PROXY_ADMIN_OWNER", owner),
                caller: vm.envOr("CALLER", owner)
            })
        );
    }
}
