// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";

import {MockWhitelist} from "../../src/3f/MockWhitelist.sol";

// Deploys the test-only MockWhitelist (attests every address) for testnet/local use where 3F's real
// RequestWhitelist isn't available. Use its address as the adapter's REQUEST_WHITELIST arg on testnets only.
//
// forge script script/deploy/DeployMockWhitelist.s.sol:DeployMockWhitelistScript \
//   --rpc-url sepolia --private-key $SOLVER_PRIVATE_KEY --broadcast
contract DeployMockWhitelistScript is Script {
    function run() public returns (MockWhitelist whitelist) {
        vm.startBroadcast();
        whitelist = new MockWhitelist();
        vm.stopBroadcast();

        console2.log("Deployed MockWhitelist:", address(whitelist));
    }
}
