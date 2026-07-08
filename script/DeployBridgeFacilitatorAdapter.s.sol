// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";

import {AdapterFactory} from "@symbioticfi/core/src/contracts/adapters/AdapterFactory.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {BridgeFacilitatorAdapter} from "../src/3f/BridgeFacilitatorAdapter.sol";

// Deploys an AdapterFactory, the BridgeFacilitatorAdapter implementation, and a factory-created adapter
// proxy owned by the broadcaster. The `Adapter` base disables initializers in its constructor, so the
// live adapter must be a factory-created proxy, not a directly-initialized contract.
//
// forge script script/DeployBridgeFacilitatorAdapter.s.sol:DeployBridgeFacilitatorAdapterScript \
//   --rpc-url=RPC --broadcast
contract DeployBridgeFacilitatorAdapterScript is Script {
    // Configurations - UPDATE THESE BEFORE DEPLOYMENT

    // Symbiotic VaultV2 (ERC4626) this adapter sources collateral from.
    address public constant VAULT = 0x0000000000000000000000000000000000000000;
    // 3F RequestWhitelist. Use the MockWhitelist address on testnets.
    address public constant REQUEST_WHITELIST = 0x0000000000000000000000000000000000000000;
    // Symbiotic vault factory/registry, used to validate the vault at initialize.
    address public constant VAULT_FACTORY = 0x0000000000000000000000000000000000000000;
    // EOA whose signatures the adapter accepts via EIP-1271. Leave zero to skip setup.
    address public constant OFFER_SIGNER = 0x0000000000000000000000000000000000000000;

    // Exposure limits. Zero disables each limit.
    uint256 public constant PER_REQUEST_MAX_COLLATERAL = 0;
    uint256 public constant TOTAL_MAX_COLLATERAL = 0;
    uint256 public constant MIN_REQUEST_YIELD_BPS = 0;
    uint256 public constant MAX_CONCURRENT_LOANS = 0;

    function run() public returns (BridgeFacilitatorAdapter adapter) {
        address collateral = IERC4626(VAULT).asset();

        vm.startBroadcast();
        (, address broadcaster,) = vm.readCallers();

        AdapterFactory adapterFactory = new AdapterFactory(broadcaster);
        BridgeFacilitatorAdapter implementation =
            new BridgeFacilitatorAdapter(REQUEST_WHITELIST, VAULT_FACTORY, address(adapterFactory));
        adapterFactory.whitelist(address(implementation));
        uint64 version = adapterFactory.lastVersion();

        adapter = BridgeFacilitatorAdapter(adapterFactory.create(version, broadcaster, abi.encode(VAULT, bytes(""))));

        if (OFFER_SIGNER != address(0)) {
            adapter.setOfferSigner(OFFER_SIGNER);
        }
        adapter.setExposureLimits(
            PER_REQUEST_MAX_COLLATERAL, TOTAL_MAX_COLLATERAL, MIN_REQUEST_YIELD_BPS, MAX_CONCURRENT_LOANS
        );
        vm.stopBroadcast();

        console2.log("Deployed BridgeFacilitatorAdapter (proxy):", address(adapter));
        console2.log("  implementation: ", address(implementation));
        console2.log("  adapterFactory: ", address(adapterFactory));
        console2.log("  owner:          ", adapter.owner());
        console2.log("  offerSigner:    ", adapter.offerSigner());
        console2.log("  collateral:     ", collateral);
        console2.log("  perRequestMaxCollateral:", adapter.perRequestMaxCollateral());
        console2.log("  totalMaxCollateral:     ", adapter.totalMaxCollateral());
        console2.log("  minRequestYieldBps:     ", adapter.minRequestYieldBps());
        console2.log("  maxConcurrentLoans:     ", adapter.maxConcurrentLoans());
        console2.log("Remaining curator setup (delegator authority, run separately):");
        console2.log("  - whitelist the adapter in the vault's AdapterRegistry");
        console2.log("  - delegator.addAdapter(adapter)        // auto-grants ALLOCATE_ROLE/DEALLOCATE_ROLE");
        console2.log("  - delegator.setAdapterLimits(adapter, limit)  // the per-adapter JIT cap (limitOf)");
        console2.log("  (Request authorization is the 3F whitelist; no per-Request setup needed.)");
    }
}
