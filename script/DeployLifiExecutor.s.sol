// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DeployLifiExecutorBaseScript} from "./deploy/base/DeployLifiExecutorBase.s.sol";

// forge script script/DeployLifiExecutor.s.sol:DeployLifiExecutorScript \
//     --rpc-url "$ETH_RPC_URL" --account "$ACCOUNT" --sender "$SENDER" --broadcast

contract DeployLifiExecutorScript is DeployLifiExecutorBaseScript {
    // Configurations - UPDATE THESE BEFORE DEPLOYMENT

    // LI.FI OIF InputSettlerEscrow this executor finalises orders through.
    address public constant INPUT_SETTLER = 0x00fC00edbe7C003b006f870068c548940000223e;
    // LI.FI OIF OutputSettler this executor fills and attests outputs through.
    address public constant OUTPUT_SETTLER = 0x75220B7600c300005038432a0000f308e0000068;
    // Executor owner. Defaults to the sender when left zero.
    address public constant ADMIN = 0x0000000000000000000000000000000000000000;
    // Owner of the proxy's ProxyAdmin, authorized to upgrade. Defaults to the sender when left zero.
    address public constant PROXY_ADMIN_OWNER = 0x0000000000000000000000000000000000000000;
    // Initial caller allowed to invoke finalise and register with LI.FI. Defaults to the sender when left zero.
    address public constant CALLER = 0x0000000000000000000000000000000000000000;

    function run() public returns (DeploymentData memory data) {
        address owner = _scriptOwner();
        data = runBase(
            DeployParams({
                inputSettler: INPUT_SETTLER,
                outputSettler: OUTPUT_SETTLER,
                admin: ADMIN == address(0) ? owner : ADMIN,
                proxyAdminOwner: PROXY_ADMIN_OWNER == address(0) ? owner : PROXY_ADMIN_OWNER,
                caller: CALLER == address(0) ? owner : CALLER
            })
        );
    }
}
