// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.28;

import {DeployUniswapXExecutorBaseScript} from "../../script/deploy/base/DeployUniswapXExecutorBase.s.sol";
import {LiquidLaneUniswapXExecutor} from "../../src/uniswapx/LiquidLaneUniswapXExecutor.sol";
import {ILiquidLaneUniswapXExecutor} from "../../src/uniswapx/interfaces/ILiquidLaneUniswapXExecutor.sol";
import {IUniswapXReactor, UniswapXSignedOrder} from "../../src/uniswapx/interfaces/IUniswapXReactor.sol";

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Test} from "forge-std/Test.sol";

contract DeployUniswapXExecutorTest is Test {
    bytes32 internal constant ERC1967_ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    RecordingUniswapXReactor internal reactor;
    address internal admin = makeAddr("admin");
    address internal proxyAdminOwner = makeAddr("proxyAdminOwner");
    address internal caller = makeAddr("caller");

    function setUp() public {
        reactor = new RecordingUniswapXReactor();
    }

    function testDeploysProxyWithConfigurationAndInitializerLocks() public {
        DeployUniswapXExecutorBaseHarness harness = new DeployUniswapXExecutorBaseHarness();
        DeployUniswapXExecutorBaseScript.DeploymentData memory data = harness.runBase(
            DeployUniswapXExecutorBaseScript.DeployParams({
                reactor: address(reactor), admin: admin, proxyAdminOwner: proxyAdminOwner, caller: caller
            })
        );

        assertTrue(address(data.executor) != data.implementation);
        assertEq(data.executor.owner(), admin);
        assertEq(data.executor.callers(0), caller);
        assertEq(data.reactor, address(reactor));

        address implementation = address(uint160(uint256(vm.load(address(data.executor), ERC1967_IMPLEMENTATION_SLOT))));
        assertEq(implementation, data.implementation);

        address proxyAdmin = address(uint160(uint256(vm.load(address(data.executor), ERC1967_ADMIN_SLOT))));
        assertEq(ProxyAdmin(proxyAdmin).owner(), proxyAdminOwner);

        ILiquidLaneUniswapXExecutor.FillCall memory fillCall = ILiquidLaneUniswapXExecutor.FillCall({
            routes: new ILiquidLaneUniswapXExecutor.FillRoute[](0),
            discountRoutes: new ILiquidLaneUniswapXExecutor.DiscountRoute[](0)
        });
        vm.prank(caller);
        data.executor.execute(UniswapXSignedOrder({order: bytes(""), sig: bytes("")}), fillCall);
        assertTrue(reactor.executeWithCallbackCalled());
        assertEq(reactor.executor(), address(data.executor));

        address[] memory callers = new address[](1);
        callers[0] = caller;
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        LiquidLaneUniswapXExecutor(payable(data.implementation)).initialize(admin, callers);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        data.executor.initialize(admin, callers);
    }
}

contract DeployUniswapXExecutorBaseHarness is DeployUniswapXExecutorBaseScript {
    function _startBroadcast() internal override {}

    function _stopBroadcast() internal override {}
}

contract RecordingUniswapXReactor is IUniswapXReactor {
    bool public executeWithCallbackCalled;
    address public executor;

    function executeWithCallback(UniswapXSignedOrder calldata, bytes calldata) external payable override {
        executeWithCallbackCalled = true;
        executor = msg.sender;
    }
}
