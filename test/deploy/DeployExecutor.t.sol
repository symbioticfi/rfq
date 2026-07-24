// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.28;

import {Executor} from "../../src/Executor.sol";
import {LiquidLaneLifiExecutor} from "../../src/lifi/LiquidLaneLifiExecutor.sol";
import {DeployExecutorBaseScript} from "../../script/deploy/base/DeployExecutorBase.s.sol";
import {DeployLifiExecutorBaseScript} from "../../script/deploy/base/DeployLifiExecutorBase.s.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Test} from "forge-std/Test.sol";

contract DeployExecutorTest is Test {
    address internal reactor = makeAddr("reactor");
    address internal admin = makeAddr("admin");
    address internal proxyAdminOwner = makeAddr("proxyAdminOwner");
    address internal caller = makeAddr("caller");
    address internal inputSettler = makeAddr("inputSettler");
    address internal outputSettler = makeAddr("outputSettler");

    function testDeployExecutorBehindProxyInitializesOwnerAndCaller() public {
        DeployExecutorBaseHarness harness = new DeployExecutorBaseHarness();
        DeployExecutorBaseScript.DeploymentData memory data = harness.runBase(
            DeployExecutorBaseScript.DeployParams({
                reactor: reactor, admin: admin, proxyAdminOwner: proxyAdminOwner, caller: caller
            })
        );

        assertTrue(data.implementation != address(data.executor), "proxy distinct from impl");
        assertEq(data.executor.owner(), admin);
        assertEq(data.executor.callers(0), caller);

        address[] memory callers = new address[](1);
        callers[0] = caller;
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        Executor(payable(data.implementation)).initialize(admin, callers);
    }

    function testDeployLifiExecutorBehindProxyInitializesOwnerAndImmutables() public {
        DeployLifiExecutorBaseHarness harness = new DeployLifiExecutorBaseHarness();
        DeployLifiExecutorBaseScript.DeploymentData memory data = harness.runBase(
            DeployLifiExecutorBaseScript.DeployParams({
                inputSettler: inputSettler,
                outputSettler: outputSettler,
                admin: admin,
                proxyAdminOwner: proxyAdminOwner,
                caller: caller
            })
        );

        assertTrue(data.implementation != address(data.executor), "proxy distinct from impl");
        assertEq(data.executor.owner(), admin);
        assertEq(data.executor.INPUT_SETTLER(), inputSettler);
        assertEq(data.executor.OUTPUT_SETTLER(), outputSettler);
        assertTrue(data.executor.isCaller(caller));

        address[] memory callers = new address[](1);
        callers[0] = caller;
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        LiquidLaneLifiExecutor(data.implementation).initialize(admin, callers);
    }
}

contract DeployExecutorBaseHarness is DeployExecutorBaseScript {
    function _startBroadcast() internal override {}

    function _stopBroadcast() internal override {}
}

contract DeployLifiExecutorBaseHarness is DeployLifiExecutorBaseScript {
    function _startBroadcast() internal override {}

    function _stopBroadcast() internal override {}
}
