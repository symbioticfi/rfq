// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.28;

import {ILiquidLaneAdapter} from "../../src/interfaces/ILiquidLaneAdapter.sol";
import {IInputCallback} from "../../src/lifi/interfaces/IInputCallback.sol";
import {IInputSettler} from "../../src/lifi/interfaces/IInputSettler.sol";
import {LiquidLaneLifiExecutor} from "../../src/lifi/LiquidLaneLifiExecutor.sol";
import {ILiquidLaneLifiExecutor} from "../../src/lifi/interfaces/ILiquidLaneLifiExecutor.sol";
import {IOutputSettler, MandateOutput} from "../../src/lifi/interfaces/IOutputSettler.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Test} from "forge-std/Test.sol";

contract LiquidLaneLifiExecutorTest is Test {
    bytes32 internal constant ORDER_ID = keccak256("order");
    address internal constant SOLVER_ADDR = address(0x515011);
    bytes32 internal constant SOLVER = bytes32(uint256(uint160(SOLVER_ADDR)));
    uint8 internal constant ORDER_STATUS_DEPOSITED = 1;
    uint8 internal constant ORDER_STATUS_CLAIMED = 2;

    address internal owner = makeAddr("owner");
    address internal recipient = makeAddr("recipient");
    address internal collector = makeAddr("collector");

    TestToken internal rwa;
    TestToken internal outputToken;
    MockLifiAdapter internal adapter;
    MockInputSettler internal inputSettler;
    MockOutputSettler internal outputSettler;
    LiquidLaneLifiExecutor internal executor;

    function setUp() public {
        rwa = new TestToken("RWA", "RWA");
        outputToken = new TestToken("USD", "USD");
        adapter = new MockLifiAdapter(outputToken);
        inputSettler = new MockInputSettler();
        outputSettler = new MockOutputSettler();
        inputSettler.setOrderStatus(ORDER_ID, ORDER_STATUS_DEPOSITED);

        address[] memory adapters = new address[](1);
        adapters[0] = address(adapter);
        executor = new LiquidLaneLifiExecutor(address(inputSettler), address(outputSettler), owner, adapters);

        outputToken.mint(address(adapter), 100 ether);
    }

    function testFinaliseCallbackRedeemsInputThenFillsAndAttestsOutput() public {
        adapter.setBonus(1 ether);
        rwa.mint(address(inputSettler), 10 ether);

        vm.expectEmit(true, true, true, true, address(executor));
        emit ILiquidLaneLifiExecutor.InputRedeemed(
            ORDER_ID, address(adapter), address(rwa), address(outputToken), 10 ether, 10 ether
        );
        vm.expectEmit(true, true, true, true, address(executor));
        emit ILiquidLaneLifiExecutor.OutputFilled(ORDER_ID, SOLVER, address(outputToken), recipient, 9 ether);

        inputSettler.finalise(address(executor), _inputs(10 ether), _fillCallData(9 ether));

        assertEq(rwa.balanceOf(address(adapter)), 10 ether);
        assertEq(outputToken.balanceOf(recipient), 9 ether);
        assertEq(outputToken.balanceOf(address(executor)), 1 ether);
        assertEq(inputSettler.orderStatus(ORDER_ID), ORDER_STATUS_CLAIMED);
        assertEq(outputSettler.lastOrderId(), ORDER_ID);
        assertEq(outputSettler.lastSolver(), SOLVER);
        assertTrue(outputSettler.attested());
    }

    function testFinaliseWithCurrentTimestampCallsSignaturePathAndCallback() public {
        adapter.setBonus(1 ether);
        rwa.mint(address(inputSettler), 10 ether);

        vm.warp(1_717_171);
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        bytes32 orderId = _orderId(order);
        inputSettler.setOrderStatus(orderId, ORDER_STATUS_DEPOSITED);
        bytes memory call = _fillCallData(orderId, 9 ether);

        executor.finaliseWithCurrentTimestamp(
            address(inputSettler), order, SOLVER_ADDR, address(executor), call, hex"1234"
        );

        assertEq(inputSettler.lastTimestamp(), uint32(block.timestamp));
        assertEq(inputSettler.lastSolver(), SOLVER);
        assertEq(inputSettler.lastDestination(), _id(address(executor)));
        assertEq(inputSettler.lastOrderOwnerSignature(), hex"1234");
        assertEq(inputSettler.orderStatus(orderId), ORDER_STATUS_CLAIMED);
        assertEq(outputToken.balanceOf(recipient), 9 ether);
        assertTrue(outputSettler.attested());
    }

    function testFinaliseWithCurrentTimestampRejectsAlreadyClaimedOrderBeforeFinalise() public {
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        bytes32 orderId = _orderId(order);
        inputSettler.setOrderStatus(orderId, ORDER_STATUS_CLAIMED);

        vm.expectRevert(
            abi.encodeWithSelector(ILiquidLaneLifiExecutor.InvalidOrderStatus.selector, ORDER_STATUS_CLAIMED)
        );
        executor.finaliseWithCurrentTimestamp(
            address(inputSettler), order, SOLVER_ADDR, address(executor), _fillCallData(orderId, 9 ether), ""
        );
    }

    function testFinaliseWithCurrentTimestampRejectsSolverMismatch() public {
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);

        vm.expectRevert(ILiquidLaneLifiExecutor.SolverMismatch.selector);
        executor.finaliseWithCurrentTimestamp(
            address(inputSettler),
            order,
            makeAddr("wrongSolver"),
            address(executor),
            _fillCallData(_orderId(order), 9 ether),
            ""
        );
    }

    function testFinaliseWithCurrentTimestampRejectsOrderIdMismatch() public {
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        ILiquidLaneLifiExecutor.FillCall memory fillCall =
            _fillCallStruct(address(adapter), _orderId(order), _output(9 ether));
        fillCall.orderId = keccak256("wrong order");

        vm.expectRevert(ILiquidLaneLifiExecutor.InvalidOrderId.selector);
        executor.finaliseWithCurrentTimestamp(
            address(inputSettler), order, SOLVER_ADDR, address(executor), abi.encode(fillCall), ""
        );
    }

    function testFinaliseWithCurrentTimestampRejectsOutputCountMismatch() public {
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        MandateOutput[] memory outputs = new MandateOutput[](2);
        outputs[0] = _output(9 ether);
        outputs[1] = _output(1 ether);
        order.outputs = outputs;
        bytes memory call = _fillCallData(_orderId(order), 9 ether);

        vm.expectRevert(ILiquidLaneLifiExecutor.InvalidOutputCount.selector);
        executor.finaliseWithCurrentTimestamp(address(inputSettler), order, SOLVER_ADDR, address(executor), call, "");
    }

    function testFinaliseWithCurrentTimestampRejectsOutputMismatch() public {
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        bytes memory call = _fillCallData(_orderId(order), 8 ether);

        vm.expectRevert(ILiquidLaneLifiExecutor.InvalidOrderOutput.selector);
        executor.finaliseWithCurrentTimestamp(address(inputSettler), order, SOLVER_ADDR, address(executor), call, "");
    }

    function testFinaliseWithCurrentTimestampRejectsFillDeadlineMismatch() public {
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        ILiquidLaneLifiExecutor.FillCall memory fillCall =
            _fillCallStruct(address(adapter), _orderId(order), _output(9 ether));
        fillCall.fillDeadline = order.fillDeadline + 1;

        vm.expectRevert(ILiquidLaneLifiExecutor.InvalidOrderOutput.selector);
        executor.finaliseWithCurrentTimestamp(
            address(inputSettler), order, SOLVER_ADDR, address(executor), abi.encode(fillCall), ""
        );
    }

    function testFinaliseWithCurrentTimestampRejectsFillAfterWithoutAuction() public {
        vm.warp(1000);
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        ILiquidLaneLifiExecutor.FillCall memory fillCall =
            _fillCallStruct(address(adapter), _orderId(order), order.outputs[0]);
        fillCall.fillAfter = uint32(block.timestamp);

        vm.expectRevert(ILiquidLaneLifiExecutor.FillAfterWithoutAuction.selector);
        executor.finaliseWithCurrentTimestamp(
            address(inputSettler), order, SOLVER_ADDR, address(executor), abi.encode(fillCall), ""
        );
    }

    function testFinaliseWithCurrentTimestampRejectsAuctionFillTooEarly() public {
        vm.warp(1000);
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        order.outputs[0].context = _dutchContext(900, 1100, 0.01 ether);
        bytes32 orderId = _orderId(order);
        ILiquidLaneLifiExecutor.FillCall memory fillCall = _fillCallStruct(address(adapter), orderId, order.outputs[0]);
        fillCall.fillAfter = uint32(block.timestamp + 1);

        vm.expectRevert(abi.encodeWithSelector(ILiquidLaneLifiExecutor.FillTooEarly.selector, 1001, 1000));
        executor.finaliseWithCurrentTimestamp(
            address(inputSettler), order, SOLVER_ADDR, address(executor), abi.encode(fillCall), ""
        );
    }

    function testFinaliseWithCurrentTimestampRejectsWrongInputSettler() public {
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);

        vm.expectRevert(ILiquidLaneLifiExecutor.InvalidInputSettler.selector);
        executor.finaliseWithCurrentTimestamp(
            makeAddr("wrongSettler"), order, SOLVER_ADDR, address(executor), _fillCallData(_orderId(order), 9 ether), ""
        );
    }

    function testFinaliseWithCurrentTimestampRejectsWrongDestination() public {
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);

        vm.expectRevert(ILiquidLaneLifiExecutor.InvalidDestination.selector);
        executor.finaliseWithCurrentTimestamp(
            address(inputSettler),
            order,
            SOLVER_ADDR,
            makeAddr("wrongDestination"),
            _fillCallData(_orderId(order), 9 ether),
            ""
        );
    }

    function testMockFinaliseWithSignatureRejectsStaleOrFutureTimestamp() public {
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        IInputSettler.SolveParams[] memory solveParams = new IInputSettler.SolveParams[](1);
        solveParams[0].solver = SOLVER;

        vm.warp(100);
        solveParams[0].timestamp = 99;
        vm.expectRevert(MockInputSettler.TimestampPassed.selector);
        inputSettler.finaliseWithSignature(order, solveParams, _id(address(executor)), _fillCallData(9 ether), "");

        solveParams[0].timestamp = 101;
        vm.expectRevert(MockInputSettler.TimestampNotPassed.selector);
        inputSettler.finaliseWithSignature(order, solveParams, _id(address(executor)), _fillCallData(9 ether), "");
    }

    function testOrderFinalisedRejectsNonInputSettler() public {
        vm.expectRevert(ILiquidLaneLifiExecutor.NotInputSettler.selector);
        executor.orderFinalised(_inputs(10 ether), _fillCallData(9 ether));
    }

    function testOrderFinalisedRejectsDepositedOrderStatusInCallback() public {
        rwa.mint(address(executor), 10 ether);

        vm.expectRevert(
            abi.encodeWithSelector(ILiquidLaneLifiExecutor.InvalidOrderStatus.selector, ORDER_STATUS_DEPOSITED)
        );
        vm.prank(address(inputSettler));
        executor.orderFinalised(_inputs(10 ether), _fillCallData(9 ether));

        assertEq(outputToken.balanceOf(recipient), 0);
        assertFalse(outputSettler.attested());
    }

    function testOrderFinalisedRejectsMultipleInputs() public {
        uint256[2][] memory inputs = new uint256[2][](2);
        inputs[0][0] = uint256(uint160(address(rwa)));
        inputs[0][1] = 10 ether;
        inputs[1][0] = uint256(uint160(address(rwa)));
        inputs[1][1] = 1 ether;

        vm.expectRevert(ILiquidLaneLifiExecutor.InvalidInputCount.selector);
        vm.prank(address(inputSettler));
        executor.orderFinalised(inputs, _fillCallData(9 ether));
    }

    function testOrderFinalisedRejectsUnallowedAdapter() public {
        MockLifiAdapter otherAdapter = new MockLifiAdapter(outputToken);
        rwa.mint(address(executor), 10 ether);

        vm.expectRevert(ILiquidLaneLifiExecutor.AdapterNotAllowed.selector);
        vm.prank(address(inputSettler));
        executor.orderFinalised(_inputs(10 ether), _fillCallData(address(otherAdapter), 9 ether));
    }

    function testOrderFinalisedRejectsFillAfterWithoutAuction() public {
        vm.warp(1000);
        inputSettler.setOrderStatus(ORDER_ID, ORDER_STATUS_CLAIMED);
        ILiquidLaneLifiExecutor.FillCall memory fillCall = _fillCallStruct(address(adapter), _output(9 ether));
        fillCall.fillAfter = uint32(block.timestamp);

        vm.expectRevert(ILiquidLaneLifiExecutor.FillAfterWithoutAuction.selector);
        vm.prank(address(inputSettler));
        executor.orderFinalised(_inputs(10 ether), abi.encode(fillCall));
    }

    function testOrderFinalisedRejectsFillAfterForExclusiveLimitOutput() public {
        vm.warp(1000);
        inputSettler.setOrderStatus(ORDER_ID, ORDER_STATUS_CLAIMED);
        MandateOutput memory output = _output(9 ether, _exclusiveContext(SOLVER, uint32(block.timestamp)));
        ILiquidLaneLifiExecutor.FillCall memory fillCall = _fillCallStruct(address(adapter), output);
        fillCall.fillAfter = uint32(block.timestamp);

        vm.expectRevert(ILiquidLaneLifiExecutor.FillAfterWithoutAuction.selector);
        vm.prank(address(inputSettler));
        executor.orderFinalised(_inputs(10 ether), abi.encode(fillCall));
    }

    function testOrderFinalisedRejectsAuctionFillTooEarly() public {
        vm.warp(1000);
        inputSettler.setOrderStatus(ORDER_ID, ORDER_STATUS_CLAIMED);
        ILiquidLaneLifiExecutor.FillCall memory fillCall =
            _fillCallStruct(address(adapter), _output(9 ether, _dutchContext(900, 1100, 0.01 ether)));
        fillCall.fillAfter = uint32(block.timestamp + 1);

        vm.expectRevert(abi.encodeWithSelector(ILiquidLaneLifiExecutor.FillTooEarly.selector, 1001, 1000));
        vm.prank(address(inputSettler));
        executor.orderFinalised(_inputs(10 ether), abi.encode(fillCall));
    }

    function testOrderFinalisedRejectsUnderDelivery() public {
        inputSettler.setOrderStatus(ORDER_ID, ORDER_STATUS_CLAIMED);
        adapter.setNextOutputAmount(8 ether);
        rwa.mint(address(executor), 10 ether);

        vm.expectRevert(ILiquidLaneLifiExecutor.InsufficientOutput.selector);
        vm.prank(address(inputSettler));
        executor.orderFinalised(_inputs(10 ether), _fillCallData(9 ether));
    }

    function testOrderFinalisedDutchOutputUsesResolvedAmount() public {
        vm.warp(1000);
        inputSettler.setOrderStatus(ORDER_ID, ORDER_STATUS_CLAIMED);
        rwa.mint(address(executor), 10 ether);

        MandateOutput memory output = _output(9 ether, _dutchContext(900, 1100, 0.01 ether));

        vm.prank(address(inputSettler));
        executor.orderFinalised(_inputs(10 ether), _fillCallData(output));

        assertEq(outputToken.balanceOf(recipient), 10 ether);
        assertEq(outputSettler.lastOutputAmount(), 10 ether);
    }

    function testOrderFinalisedExclusiveDutchOutputUsesResolvedAmount() public {
        vm.warp(1000);
        inputSettler.setOrderStatus(ORDER_ID, ORDER_STATUS_CLAIMED);
        rwa.mint(address(executor), 10 ether);

        MandateOutput memory output =
            _output(9 ether, _exclusiveDutchContext(_id(makeAddr("otherSolver")), 900, 1100, 0.01 ether));

        vm.prank(address(inputSettler));
        executor.orderFinalised(_inputs(10 ether), _fillCallData(output));

        assertEq(outputToken.balanceOf(recipient), 10 ether);
        assertEq(outputSettler.lastOutputAmount(), 10 ether);
    }

    function testOrderFinalisedRejectsDutchUnderDeliveryAgainstResolvedAmount() public {
        vm.warp(1000);
        inputSettler.setOrderStatus(ORDER_ID, ORDER_STATUS_CLAIMED);
        adapter.setNextOutputAmount(9.5 ether);
        rwa.mint(address(executor), 10 ether);

        MandateOutput memory output = _output(9 ether, _dutchContext(900, 1100, 0.01 ether));

        vm.expectRevert(ILiquidLaneLifiExecutor.InsufficientOutput.selector);
        vm.prank(address(inputSettler));
        executor.orderFinalised(_inputs(10 ether), _fillCallData(output));
    }

    function testOrderFinalisedRejectsExclusiveSolverMismatchBeforeStart() public {
        vm.warp(1000);
        inputSettler.setOrderStatus(ORDER_ID, ORDER_STATUS_CLAIMED);

        bytes32 exclusiveFor = _id(makeAddr("otherSolver"));
        MandateOutput memory output = _output(9 ether, _exclusiveContext(exclusiveFor, 1001));

        vm.expectRevert(
            abi.encodeWithSelector(ILiquidLaneLifiExecutor.ExclusiveForMismatch.selector, exclusiveFor, SOLVER)
        );
        vm.prank(address(inputSettler));
        executor.orderFinalised(_inputs(10 ether), _fillCallData(output));
    }

    function testOrderFinalisedAllowsExclusiveOutputAfterStart() public {
        vm.warp(1000);
        inputSettler.setOrderStatus(ORDER_ID, ORDER_STATUS_CLAIMED);
        rwa.mint(address(executor), 10 ether);

        MandateOutput memory output = _output(9 ether, _exclusiveContext(_id(makeAddr("otherSolver")), 1000));

        vm.prank(address(inputSettler));
        executor.orderFinalised(_inputs(10 ether), _fillCallData(output));

        assertEq(outputToken.balanceOf(recipient), 9 ether);
    }

    function testOrderFinalisedRejectsBadContextLength() public {
        inputSettler.setOrderStatus(ORDER_ID, ORDER_STATUS_CLAIMED);
        MandateOutput memory output = _output(9 ether, hex"0000");

        vm.expectRevert(abi.encodeWithSelector(ILiquidLaneLifiExecutor.InvalidOutputContextLength.selector, 0, 2));
        vm.prank(address(inputSettler));
        executor.orderFinalised(_inputs(10 ether), _fillCallData(output));
    }

    function testOrderFinalisedRejectsUnknownContextType() public {
        inputSettler.setOrderStatus(ORDER_ID, ORDER_STATUS_CLAIMED);
        MandateOutput memory output = _output(9 ether, hex"02");

        vm.expectRevert(abi.encodeWithSelector(ILiquidLaneLifiExecutor.UnknownOutputContext.selector, bytes1(0x02)));
        vm.prank(address(inputSettler));
        executor.orderFinalised(_inputs(10 ether), _fillCallData(output));
    }

    function testOrderFinalisedRejectsZeroInputAmount() public {
        inputSettler.setOrderStatus(ORDER_ID, ORDER_STATUS_CLAIMED);

        vm.expectRevert(ILiquidLaneLifiExecutor.InvalidAmount.selector);
        vm.prank(address(inputSettler));
        executor.orderFinalised(_inputs(0), _fillCallData(9 ether));
    }

    function testOrderFinalisedRejectsWrongOutputSettlerIdentifier() public {
        bytes memory call = _fillCallData(_output(9 ether, makeAddr("wrongSettler"), address(outputSettler)));

        vm.expectRevert(ILiquidLaneLifiExecutor.InvalidOutputSettler.selector);
        vm.prank(address(inputSettler));
        executor.orderFinalised(_inputs(10 ether), call);
    }

    function testOrderFinalisedRejectsWrongOutputOracle() public {
        bytes memory call = _fillCallData(_output(9 ether, address(outputSettler), makeAddr("wrongOracle")));

        vm.expectRevert(ILiquidLaneLifiExecutor.InvalidOutputOracle.selector);
        vm.prank(address(inputSettler));
        executor.orderFinalised(_inputs(10 ether), call);
    }

    function testOrderFinalisedRejectsWrongOutputChain() public {
        MandateOutput memory output = _output(9 ether);
        output.chainId = block.chainid + 1;

        vm.expectRevert(ILiquidLaneLifiExecutor.InvalidOutputChain.selector);
        vm.prank(address(inputSettler));
        executor.orderFinalised(_inputs(10 ether), _fillCallData(output));
    }

    function testOrderFinalisedRejectsNativeOutput() public {
        MandateOutput memory output = _output(9 ether);
        output.token = bytes32(0);

        vm.expectRevert(ILiquidLaneLifiExecutor.NativeOutputUnsupported.selector);
        vm.prank(address(inputSettler));
        executor.orderFinalised(_inputs(10 ether), _fillCallData(output));
    }

    function testOrderFinalisedRejectsDirtyOutputIdentifier() public {
        MandateOutput memory output = _output(9 ether);
        output.token = bytes32(uint256(uint160(address(outputToken))) | (uint256(1) << 160));

        vm.expectRevert(ILiquidLaneLifiExecutor.InvalidIdentifier.selector);
        vm.prank(address(inputSettler));
        executor.orderFinalised(_inputs(10 ether), _fillCallData(output));
    }

    function testOrderFinalisedRejectsDirtySolverIdentifier() public {
        ILiquidLaneLifiExecutor.FillCall memory fillCall = _fillCallStruct(address(adapter), _output(9 ether));
        fillCall.solver = bytes32(uint256(SOLVER) | (uint256(1) << 160));

        vm.expectRevert(ILiquidLaneLifiExecutor.InvalidIdentifier.selector);
        vm.prank(address(inputSettler));
        executor.orderFinalised(_inputs(10 ether), abi.encode(fillCall));
    }

    function testOrderFinalisedSupportsSameInputAndOutputTokenAccounting() public {
        inputSettler.setOrderStatus(ORDER_ID, ORDER_STATUS_CLAIMED);
        MockLifiAdapter sameTokenAdapter = new MockLifiAdapter(rwa);
        address[] memory adapters = new address[](1);
        adapters[0] = address(sameTokenAdapter);

        vm.prank(owner);
        executor.setAdapters(adapters);

        rwa.mint(address(executor), 10 ether);
        rwa.mint(address(sameTokenAdapter), 10 ether);

        vm.prank(address(inputSettler));
        executor.orderFinalised(_inputs(10 ether), _fillCallData(address(sameTokenAdapter), address(rwa), 10 ether));

        assertEq(rwa.balanceOf(address(executor)), 0);
        assertEq(rwa.balanceOf(address(sameTokenAdapter)), 10 ether);
        assertEq(rwa.balanceOf(recipient), 10 ether);
    }

    function testSetAdaptersReplacesAllowlistAndOwnerSweepsSurplus() public {
        MockLifiAdapter nextAdapter = new MockLifiAdapter(outputToken);
        address[] memory adapters = new address[](1);
        adapters[0] = address(nextAdapter);

        vm.prank(owner);
        executor.setAdapters(adapters);

        assertFalse(executor.isAdapterAllowed(address(adapter)));
        assertTrue(executor.isAdapterAllowed(address(nextAdapter)));
        assertEq(executor.adapters(0), address(nextAdapter));

        outputToken.mint(address(executor), 2 ether);
        vm.prank(owner);
        executor.sweepERC20(address(outputToken), collector, 2 ether);

        assertEq(outputToken.balanceOf(collector), 2 ether);
    }

    function testSetAdaptersRejectsDuplicates() public {
        address[] memory adapters = new address[](2);
        adapters[0] = address(adapter);
        adapters[1] = address(adapter);

        vm.expectRevert(ILiquidLaneLifiExecutor.DuplicateAdapter.selector);
        vm.prank(owner);
        executor.setAdapters(adapters);
    }

    function _order(uint256 amountIn, uint256 amountOut) internal view returns (IInputSettler.StandardOrder memory) {
        MandateOutput[] memory outputs = new MandateOutput[](1);
        outputs[0] = _output(amountOut);

        return IInputSettler.StandardOrder({
            user: address(0xA11CE),
            nonce: uint256(ORDER_ID),
            originChainId: block.chainid,
            expires: uint32(block.timestamp + 1 hours),
            fillDeadline: uint32(block.timestamp + 1 hours),
            inputOracle: address(outputSettler),
            inputs: _inputs(amountIn),
            outputs: outputs
        });
    }

    function _inputs(uint256 amount) internal view returns (uint256[2][] memory inputs) {
        inputs = new uint256[2][](1);
        inputs[0][0] = uint256(uint160(address(rwa)));
        inputs[0][1] = amount;
    }

    function _fillCallData(uint256 amountOut) internal view returns (bytes memory) {
        return abi.encode(_fillCallStruct(address(adapter), _output(amountOut)));
    }

    function _fillCallData(address fillAdapter, uint256 amountOut) internal view returns (bytes memory) {
        return abi.encode(_fillCallStruct(fillAdapter, _output(amountOut)));
    }

    function _fillCallData(address fillAdapter, address tokenOut, uint256 amountOut)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(_fillCallStruct(fillAdapter, _output(amountOut, tokenOut)));
    }

    function _fillCallData(MandateOutput memory output) internal view returns (bytes memory) {
        return abi.encode(_fillCallStruct(address(adapter), output));
    }

    function _fillCallData(bytes32 orderId, uint256 amountOut) internal view returns (bytes memory) {
        return abi.encode(_fillCallStruct(address(adapter), orderId, _output(amountOut)));
    }

    function _fillCallStruct(address fillAdapter, MandateOutput memory output)
        internal
        view
        returns (ILiquidLaneLifiExecutor.FillCall memory)
    {
        return _fillCallStruct(fillAdapter, ORDER_ID, output);
    }

    function _fillCallStruct(address fillAdapter, bytes32 orderId, MandateOutput memory output)
        internal
        view
        returns (ILiquidLaneLifiExecutor.FillCall memory)
    {
        return ILiquidLaneLifiExecutor.FillCall({
            adapter: fillAdapter,
            orderId: orderId,
            output: output,
            fillDeadline: uint32(block.timestamp + 1 hours),
            solver: SOLVER,
            fillAfter: 0
        });
    }

    function _output(uint256 amount) internal view returns (MandateOutput memory) {
        return _output(amount, address(outputToken));
    }

    function _output(uint256 amount, address token) internal view returns (MandateOutput memory) {
        return _output(amount, token, address(outputSettler), address(outputSettler));
    }

    function _output(uint256 amount, bytes memory context) internal view returns (MandateOutput memory output) {
        output = _output(amount);
        output.context = context;
    }

    function _output(uint256 amount, address settler, address oracle) internal view returns (MandateOutput memory) {
        return _output(amount, address(outputToken), settler, oracle);
    }

    function _output(uint256 amount, address token, address settler, address oracle)
        internal
        view
        returns (MandateOutput memory)
    {
        return MandateOutput({
            oracle: _id(oracle),
            settler: _id(settler),
            chainId: block.chainid,
            token: _id(token),
            amount: amount,
            recipient: _id(recipient),
            callbackData: bytes(""),
            context: bytes("")
        });
    }

    function _id(address addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }

    function _dutchContext(uint32 startTime, uint32 stopTime, uint256 slope) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes1(0x01), startTime, stopTime, slope);
    }

    function _exclusiveContext(bytes32 exclusiveFor, uint32 startTime) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes1(0xe0), exclusiveFor, startTime);
    }

    function _exclusiveDutchContext(bytes32 exclusiveFor, uint32 startTime, uint32 stopTime, uint256 slope)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(bytes1(0xe1), exclusiveFor, startTime, stopTime, slope);
    }

    function _orderId(IInputSettler.StandardOrder memory order) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                order.user,
                order.nonce,
                order.originChainId,
                order.expires,
                order.fillDeadline,
                order.inputOracle,
                keccak256(abi.encode(order.inputs)),
                _outputsHash(order.outputs)
            )
        );
    }

    function _outputsHash(MandateOutput[] memory outputs) internal pure returns (bytes32) {
        bytes32[] memory outputHashes = new bytes32[](outputs.length);
        for (uint256 i; i < outputs.length; ++i) {
            outputHashes[i] = _outputHash(outputs[i]);
        }
        return keccak256(abi.encode(outputHashes));
    }

    function _outputHash(MandateOutput memory output) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                output.oracle,
                output.settler,
                output.chainId,
                output.token,
                output.amount,
                output.recipient,
                keccak256(output.callbackData),
                keccak256(output.context)
            )
        );
    }
}

contract MockInputSettler is IInputSettler {
    using SafeERC20 for IERC20;

    uint8 internal constant ORDER_STATUS_DEPOSITED = 1;
    uint8 internal constant ORDER_STATUS_CLAIMED = 2;

    error InvalidTimestampLength();
    error TimestampNotPassed();
    error TimestampPassed();

    mapping(bytes32 orderId => uint8 status) public orderStatus;
    uint32 public lastTimestamp;
    bytes32 public lastSolver;
    bytes32 public lastDestination;
    bytes public lastOrderOwnerSignature;

    function setOrderStatus(bytes32 orderId, uint8 status) public {
        orderStatus[orderId] = status;
    }

    function orderIdentifier(StandardOrder calldata order) external pure returns (bytes32 orderId) {
        return _orderId(order);
    }

    function finaliseWithSignature(
        StandardOrder calldata order,
        SolveParams[] calldata solveParams,
        bytes32 destination,
        bytes calldata call,
        bytes calldata orderOwnerSignature
    ) external {
        if (solveParams.length != 1) revert InvalidTimestampLength();
        if (solveParams[0].timestamp < block.timestamp) revert TimestampPassed();
        if (solveParams[0].timestamp > block.timestamp) revert TimestampNotPassed();

        lastTimestamp = solveParams[0].timestamp;
        lastSolver = solveParams[0].solver;
        lastDestination = destination;
        lastOrderOwnerSignature = orderOwnerSignature;

        _finalise(_orderId(order), address(uint160(uint256(destination))), order.inputs, call);
    }

    function finalise(address destination, uint256[2][] memory inputs, bytes memory call) public {
        ILiquidLaneLifiExecutor.FillCall memory fillCall = abi.decode(call, (ILiquidLaneLifiExecutor.FillCall));
        _finalise(fillCall.orderId, destination, inputs, call);
    }

    function _finalise(bytes32 orderId, address destination, uint256[2][] memory inputs, bytes memory call) internal {
        for (uint256 i; i < inputs.length; ++i) {
            IERC20(address(uint160(inputs[i][0]))).safeTransfer(destination, inputs[i][1]);
        }

        orderStatus[orderId] = ORDER_STATUS_CLAIMED;
        IInputCallback(destination).orderFinalised(inputs, call);

        ILiquidLaneLifiExecutor.FillCall memory fillCall = abi.decode(call, (ILiquidLaneLifiExecutor.FillCall));
        require(fillCall.orderId == orderId, "order mismatch");
        require(MockOutputSettler(address(uint160(uint256(fillCall.output.settler)))).attested(), "not attested");
    }

    function _orderId(StandardOrder calldata order) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                order.user,
                order.nonce,
                order.originChainId,
                order.expires,
                order.fillDeadline,
                order.inputOracle,
                keccak256(abi.encode(order.inputs)),
                _outputsHash(order.outputs)
            )
        );
    }

    function _outputsHash(MandateOutput[] calldata outputs) internal pure returns (bytes32) {
        bytes32[] memory outputHashes = new bytes32[](outputs.length);
        for (uint256 i; i < outputs.length; ++i) {
            outputHashes[i] = _outputHash(outputs[i]);
        }
        return keccak256(abi.encode(outputHashes));
    }

    function _outputHash(MandateOutput calldata output) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                output.oracle,
                output.settler,
                output.chainId,
                output.token,
                output.amount,
                output.recipient,
                keccak256(output.callbackData),
                keccak256(output.context)
            )
        );
    }
}

contract MockOutputSettler is IOutputSettler {
    using SafeERC20 for IERC20;

    bool public attested;
    bytes32 public lastOrderId;
    bytes32 public lastSolver;
    uint256 public lastOutputAmount;
    mapping(bytes32 orderId => mapping(bytes32 outputHash => bytes32 fillRecord)) public fillRecords;

    function fill(bytes32 orderId, MandateOutput calldata output, uint48 fillDeadline, bytes calldata fillerData)
        external
        payable
        returns (bytes32 fillRecordHash)
    {
        require(fillDeadline >= block.timestamp, "deadline");
        bytes32 solver = abi.decode(fillerData, (bytes32));
        address token = _identifierAddress(output.token);
        address recipient = _identifierAddress(output.recipient);
        require(output.chainId == block.chainid, "chain");
        require(output.settler == _id(address(this)), "settler");
        require(output.oracle == _id(address(this)), "oracle");

        uint256 resolvedAmount = _resolveOutputAmount(output, solver);
        IERC20(token).safeTransferFrom(msg.sender, recipient, resolvedAmount);

        fillRecordHash = keccak256(abi.encodePacked(solver, uint32(block.timestamp)));
        fillRecords[orderId][_outputHash(output)] = fillRecordHash;
        lastOrderId = orderId;
        lastSolver = solver;
        lastOutputAmount = resolvedAmount;
    }

    function setAttestation(bytes32 orderId, bytes32 solver, uint32 timestamp, MandateOutput calldata output) external {
        bytes32 expected = keccak256(abi.encodePacked(solver, timestamp));
        require(fillRecords[orderId][_outputHash(output)] == expected, "invalid attestation");
        attested = true;
    }

    function _outputHash(MandateOutput calldata output) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                output.oracle,
                output.settler,
                output.chainId,
                output.token,
                output.amount,
                output.recipient,
                keccak256(output.callbackData),
                keccak256(output.context)
            )
        );
    }

    function _identifierAddress(bytes32 identifier) internal pure returns (address addr) {
        addr = address(uint160(uint256(identifier)));
        require(addr != address(0) && identifier == _id(addr), "invalid identifier");
    }

    function _resolveOutputAmount(MandateOutput calldata output, bytes32 solver) internal view returns (uint256) {
        bytes calldata context = output.context;
        if (context.length == 0) return output.amount;

        uint8 contextType = uint8(context[0]);
        if (contextType == 0x00) {
            require(context.length == 1, "bad length");
            return output.amount;
        }
        if (contextType == 0x01) {
            require(context.length == 41, "bad length");
            return _dutchOutputAmount(output.amount, context, 1);
        }
        if (contextType == 0xe0) {
            require(context.length == 37, "bad length");
            _validateExclusiveSolver(context, solver, 1, 33);
            return output.amount;
        }
        if (contextType == 0xe1) {
            require(context.length == 73, "bad length");
            _validateExclusiveSolver(context, solver, 1, 33);
            return _dutchOutputAmount(output.amount, context, 33);
        }

        revert("unknown context");
    }

    function _dutchOutputAmount(uint256 amount, bytes calldata context, uint256 startTimeOffset)
        internal
        view
        returns (uint256)
    {
        uint256 startTime = _readUint32(context, startTimeOffset);
        uint256 stopTime = _readUint32(context, startTimeOffset + 4);
        uint256 currentTime = block.timestamp > startTime ? block.timestamp : startTime;
        if (stopTime < currentTime) return amount;

        return amount + _readUint256(context, startTimeOffset + 8) * (stopTime - currentTime);
    }

    function _validateExclusiveSolver(
        bytes calldata context,
        bytes32 solver,
        uint256 exclusiveForOffset,
        uint256 startTimeOffset
    ) internal view {
        bytes32 exclusiveFor = _readBytes32(context, exclusiveForOffset);
        require(block.timestamp >= _readUint32(context, startTimeOffset) || exclusiveFor == solver, "exclusive");
    }

    function _readUint32(bytes calldata data, uint256 offset) internal pure returns (uint32 value) {
        bytes32 word = _readBytes32(data, offset);
        value = uint32(uint256(word >> 224));
    }

    function _readUint256(bytes calldata data, uint256 offset) internal pure returns (uint256 value) {
        value = uint256(_readBytes32(data, offset));
    }

    function _readBytes32(bytes calldata data, uint256 offset) internal pure returns (bytes32 value) {
        assembly ("memory-safe") {
            value := calldataload(add(data.offset, offset))
        }
    }

    function _id(address addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }
}

contract MockLifiAdapter is ILiquidLaneAdapter {
    TestToken public immutable outputToken;
    uint256 public bonus;
    uint256 public nextOutputAmount;

    constructor(TestToken outputToken_) {
        outputToken = outputToken_;
    }

    function setBonus(uint256 bonus_) public {
        bonus = bonus_;
    }

    function setNextOutputAmount(uint256 amount) public {
        nextOutputAmount = amount;
    }

    function swap(ILiquidLaneAdapter.Swap calldata swap_) public {
        require(IERC20(swap_.tokenIn).balanceOf(address(this)) >= swap_.amountIn, "missing input");

        uint256 amount = nextOutputAmount == 0 ? swap_.amountOut + bonus : nextOutputAmount;
        nextOutputAmount = 0;
        outputToken.transfer(swap_.recipient, amount);
    }

    function swap(ILiquidLaneAdapter.SignedSwap calldata, bytes calldata) public {}

    function swap(ILiquidLaneAdapter.DiscountSwap calldata, bytes calldata, address, uint256)
        public
        pure
        returns (uint256)
    {
        return 0;
    }
}

contract TestToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}
