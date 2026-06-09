// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";

import {AdapterFactory} from "@symbioticfi/core/src/contracts/adapters/AdapterFactory.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {BridgeFacilitatorAdapter} from "../../src/3f/BridgeFacilitatorAdapter.sol";

// Deploys an AdapterFactory, the BridgeFacilitatorAdapter implementation, and a factory-created adapter
// proxy owned by the broadcaster. The `Adapter` base disables initializers in its constructor, so the
// live adapter must be a factory-created proxy, not a directly-initialized contract.
//
// Required env (addresses):
//   VAULT             Symbiotic VaultV2 (ERC4626) this adapter sources collateral from
//   REQUEST_WHITELIST 3F RequestWhitelist (use the MockWhitelist address on testnets)
//   VAULT_FACTORY     Symbiotic vault factory/registry (validates the vault at initialize)
// Optional env:
//   OFFER_SIGNER      EOA whose signatures the adapter accepts via EIP-1271; when set, setOfferSigner
//                     is called in the same broadcast.
//
// forge script script/deploy/DeployBridgeFacilitatorAdapter.s.sol:DeployBridgeFacilitatorAdapterScript \
//   --rpc-url sepolia --private-key $SOLVER_PRIVATE_KEY --broadcast
contract DeployBridgeFacilitatorAdapterScript is Script {
    function run() public returns (BridgeFacilitatorAdapter adapter) {
        address vault = vm.envAddress("VAULT");
        address requestWhitelist = vm.envAddress("REQUEST_WHITELIST");
        address vaultFactory = vm.envAddress("VAULT_FACTORY");
        address offerSigner = vm.envOr("OFFER_SIGNER", address(0));

        address collateral = IERC4626(vault).asset();

        vm.startBroadcast();
        (, address broadcaster,) = vm.readCallers();

        AdapterFactory adapterFactory = new AdapterFactory(broadcaster);
        BridgeFacilitatorAdapter implementation =
            new BridgeFacilitatorAdapter(requestWhitelist, vaultFactory, address(adapterFactory));
        adapterFactory.whitelist(address(implementation));
        uint64 version = adapterFactory.lastVersion();

        adapter = BridgeFacilitatorAdapter(
            adapterFactory.create(version, broadcaster, abi.encode(vault, bytes("")))
        );

        if (offerSigner != address(0)) {
            adapter.setOfferSigner(offerSigner);
        }
        vm.stopBroadcast();

        console2.log("Deployed BridgeFacilitatorAdapter (proxy):", address(adapter));
        console2.log("  implementation: ", address(implementation));
        console2.log("  adapterFactory: ", address(adapterFactory));
        console2.log("  owner:          ", adapter.owner());
        console2.log("  offerSigner:    ", adapter.offerSigner());
        console2.log("  collateral:     ", collateral);
        console2.log("Remaining curator setup (delegator authority, run separately):");
        console2.log("  - whitelist the adapter in the vault's AdapterRegistry");
        console2.log("  - delegator.addAdapter(adapter)        // auto-grants ALLOCATE_ROLE/DEALLOCATE_ROLE");
        console2.log("  - delegator.setAdapterLimits(adapter, limit)  // the per-adapter JIT cap (limitOf)");
        console2.log("  (Request authorization is the 3F whitelist; no per-Request setup needed.)");
    }
}
