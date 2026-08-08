// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";

import {Router} from "../../../src/Router.sol";

contract DeployRouterBaseScript is Script {
    struct DeploymentData {
        Router router;
        address relayer;
    }

    function runBase() public virtual returns (DeploymentData memory data) {
        _startBroadcast();
        data.router = new Router();
        _stopBroadcast();

        data.relayer = data.router.RELAYER();

        _validateDeployment(data);
        _logDeployment(data);
    }

    function _startBroadcast() internal virtual {
        vm.startBroadcast();
    }

    function _stopBroadcast() internal virtual {
        vm.stopBroadcast();
    }

    function _validateDeployment(DeploymentData memory data) internal view virtual {
        require(data.relayer != address(0), "relayer not deployed");
        require(data.relayer.code.length > 0, "relayer has no code");
        // The pairing must be immutable on both sides; a relayer pointing elsewhere would let
        // another contract spend the allowances users grant this one.
        (bool ok, bytes memory raw) = data.relayer.staticcall(abi.encodeWithSignature("ROUTER()"));
        require(ok && abi.decode(raw, (address)) == address(data.router), "relayer/router mismatch");
    }

    function _logDeployment(DeploymentData memory data) internal virtual {
        console2.log("Deployed Router");
        console2.log("    router:", address(data.router));
        console2.log("    relayer:", data.relayer);
        console2.log("Users approve the RELAYER, never the router.");
    }
}
