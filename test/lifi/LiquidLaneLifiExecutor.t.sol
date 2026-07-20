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
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Test} from "forge-std/Test.sol";

interface IOutputCallbackLike {
    function outputFilled(bytes32 token, uint256 amount, bytes calldata callbackData) external;
}

contract LiquidLaneLifiExecutorTest is Test {
    bytes32 internal constant ORDER_ID = keccak256("order");
    address internal constant DISCOUNT_SIGNER = address(0x515011);
    bytes32 internal constant MOCK_SOLVER = bytes32(uint256(uint160(address(0x515012))));
    uint8 internal constant ORDER_STATUS_DEPOSITED = 1;
    uint8 internal constant ORDER_STATUS_CLAIMED = 2;

    address internal owner;
    address internal recipient = makeAddr("recipient");
    address internal collector = makeAddr("collector");

    TestToken internal rwa;
    TestToken internal outputToken;
    MockLifiAdapter internal adapter;
    MockInputSettler internal inputSettler;
    MockOutputSettler internal outputSettler;
    LiquidLaneLifiExecutor internal executor;

    function setUp() public {
        owner = address(this);
        rwa = new TestToken("RWA", "RWA");
        outputToken = new TestToken("USD", "USD");
        adapter = new MockLifiAdapter(outputToken);
        inputSettler = new MockInputSettler();
        outputSettler = new MockOutputSettler();
        inputSettler.setOrderStatus(ORDER_ID, ORDER_STATUS_DEPOSITED);

        executor = new LiquidLaneLifiExecutor(address(inputSettler), address(outputSettler), owner);

        outputToken.mint(address(adapter), 100 ether);
    }

    function testFinaliseCallbackRedeemsInputThenFillsAndAttestsOutput() public {
        rwa.mint(address(inputSettler), 10 ether);

        vm.expectEmit(true, true, true, true, address(executor));
        emit ILiquidLaneLifiExecutor.InputRedeemed(
            ORDER_ID, address(adapter), address(rwa), address(outputToken), 10 ether, 10 ether, bytes32(0)
        );
        vm.expectEmit(true, true, true, true, address(executor));
        emit ILiquidLaneLifiExecutor.OutputFilled(
            ORDER_ID, _id(address(executor)), address(outputToken), recipient, 9 ether, 1 ether
        );

        inputSettler.finaliseCallback(address(executor), _inputs(10 ether), _fillCallData(9 ether));

        assertEq(rwa.balanceOf(address(adapter)), 10 ether);
        assertEq(outputToken.balanceOf(recipient), 9 ether);
        assertEq(outputToken.balanceOf(address(executor)), 1 ether);
        assertEq(inputSettler.orderStatus(ORDER_ID), ORDER_STATUS_CLAIMED);
        assertEq(outputSettler.lastOrderId(), ORDER_ID);
        assertEq(outputSettler.lastSolver(), _id(address(executor)));
        assertTrue(outputSettler.attested());
    }

    function testFinaliseWithCurrentTimestampCallsFinaliseAsExecutor() public {
        rwa.mint(address(inputSettler), 10 ether);

        vm.warp(1_717_171);
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        bytes32 orderId = _orderId(order);
        inputSettler.setOrderStatus(orderId, ORDER_STATUS_DEPOSITED);
        bytes memory call = _fillCallData(orderId, 9 ether);

        executor.finaliseWithCurrentTimestamp(order, call);

        assertEq(inputSettler.lastTimestamp(), uint32(block.timestamp));
        assertEq(inputSettler.lastSolver(), _id(address(executor)));
        assertEq(inputSettler.lastDestination(), _id(address(executor)));
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
        executor.finaliseWithCurrentTimestamp(order, _fillCallData(orderId, 9 ether));
    }

    function testFinaliseWithCurrentTimestampRejectsNonOwner() public {
        address caller = makeAddr("caller");
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", caller));
        vm.prank(caller);
        executor.finaliseWithCurrentTimestamp(order, _fillCallData(_orderId(order), 9 ether));
    }

    function testIsValidSignatureAcceptsOwner() public {
        uint256 ownerKey = 0xA11CE;
        LiquidLaneLifiExecutor ownedExecutor =
            new LiquidLaneLifiExecutor(address(inputSettler), address(outputSettler), vm.addr(ownerKey));
        bytes32 digest = keccak256("lifi registration");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);

        assertEq(ownedExecutor.isValidSignature(digest, abi.encodePacked(r, s, v)), IERC1271.isValidSignature.selector);
    }

    function testIsValidSignatureRejectsOtherSigner() public {
        LiquidLaneLifiExecutor ownedExecutor =
            new LiquidLaneLifiExecutor(address(inputSettler), address(outputSettler), vm.addr(0xA11CE));
        bytes32 digest = keccak256("lifi registration");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xB0B, digest);

        assertEq(ownedExecutor.isValidSignature(digest, abi.encodePacked(r, s, v)), bytes4(0xffffffff));
    }

    function testIsValidSignatureRejectsMalformedSignature() public {
        LiquidLaneLifiExecutor ownedExecutor =
            new LiquidLaneLifiExecutor(address(inputSettler), address(outputSettler), vm.addr(0xA11CE));

        assertEq(ownedExecutor.isValidSignature(keccak256("lifi registration"), hex"deadbeef"), bytes4(0xffffffff));
    }

    function testFinaliseWithCurrentTimestampRejectsOrderIdMismatch() public {
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        ILiquidLaneLifiExecutor.FillCall memory fillCall =
            _fillCallStruct(address(adapter), _orderId(order), _output(9 ether));
        fillCall.orderId = keccak256("wrong order");

        vm.expectRevert(ILiquidLaneLifiExecutor.InvalidOrderId.selector);
        executor.finaliseWithCurrentTimestamp(order, abi.encode(fillCall));
    }

    function testFinaliseWithCurrentTimestampRejectsOutputCountMismatch() public {
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        MandateOutput[] memory outputs = new MandateOutput[](2);
        outputs[0] = _output(9 ether);
        outputs[1] = _output(1 ether);
        order.outputs = outputs;
        bytes memory call = _fillCallData(_orderId(order), 9 ether);

        vm.expectRevert(ILiquidLaneLifiExecutor.InvalidOutputCount.selector);
        executor.finaliseWithCurrentTimestamp(order, call);
    }

    function testFinaliseWithCurrentTimestampRejectsOutputMismatch() public {
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        bytes memory call = _fillCallData(_orderId(order), 8 ether);

        vm.expectRevert(ILiquidLaneLifiExecutor.InvalidOrderOutput.selector);
        executor.finaliseWithCurrentTimestamp(order, call);
    }

    function testFinaliseWithCurrentTimestampRejectsInsufficientMinimumOutput() public {
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        _openOrder(order);
        ILiquidLaneLifiExecutor.FillCall memory fillCall =
            _fillCallStruct(address(adapter), _orderId(order), order.outputs[0]);
        fillCall.routes[0].expectedAmountOut = 8 ether;
        fillCall.routes[0].minAmountOut = 8 ether;

        vm.expectRevert(
            abi.encodeWithSelector(ILiquidLaneLifiExecutor.InsufficientMinimumOutput.selector, 8 ether, 9 ether)
        );
        executor.finaliseWithCurrentTimestamp(order, abi.encode(fillCall));
    }

    function testFinaliseWithCurrentTimestampRejectsInvalidRouteOutputBounds() public {
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        _openOrder(order);
        ILiquidLaneLifiExecutor.FillCall memory fillCall =
            _fillCallStruct(address(adapter), _orderId(order), order.outputs[0]);
        fillCall.routes[0].expectedAmountOut = 9 ether;
        fillCall.routes[0].minAmountOut = 9.1 ether;

        vm.expectRevert(
            abi.encodeWithSelector(ILiquidLaneLifiExecutor.InvalidRouteOutputBounds.selector, 9 ether, 9.1 ether)
        );
        executor.finaliseWithCurrentTimestamp(order, abi.encode(fillCall));
    }

    function testFinaliseWithCurrentTimestampClampsTargetToCurrentRate() public {
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        bytes32 orderId = _orderId(order);
        inputSettler.setOrderStatus(orderId, ORDER_STATUS_DEPOSITED);
        rwa.mint(address(inputSettler), 10 ether);
        ILiquidLaneLifiExecutor.FillCall memory fillCall = _fillCallStruct(address(adapter), orderId, order.outputs[0]);
        fillCall.routes[0].expectedAmountOut = 11 ether;

        executor.finaliseWithCurrentTimestamp(order, abi.encode(fillCall));

        assertEq(outputToken.balanceOf(recipient), 9 ether);
        assertEq(outputToken.balanceOf(address(executor)), 1 ether);
    }

    function testFinaliseWithCurrentTimestampAcceptsPrivateDiscountRoute() public {
        vm.warp(1000);
        adapter.setMinDiscount(100_000);
        rwa.mint(address(inputSettler), 10 ether);

        IInputSettler.StandardOrder memory order = _order(10 ether, 8 ether);
        bytes32 orderId = _orderId(order);
        inputSettler.setOrderStatus(orderId, ORDER_STATUS_DEPOSITED);
        ILiquidLaneLifiExecutor.FillCall memory fillCall = _fillCallStruct(address(adapter), orderId, order.outputs[0]);
        fillCall.routes[0] = _discountRoute(address(adapter), 10 ether, 9 ether, keccak256("discount"), 100_000);

        executor.finaliseWithCurrentTimestamp(order, abi.encode(fillCall));

        assertEq(outputToken.balanceOf(recipient), 8 ether);
        assertEq(outputToken.balanceOf(address(executor)), 1 ether);
        assertEq(rwa.balanceOf(address(adapter)), 10 ether);
    }

    function testFinaliseWithCurrentTimestampRejectsDiscountBelowAdapterMinimum() public {
        vm.warp(1000);
        adapter.setMinDiscount(100_000);
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        _openOrder(order);
        ILiquidLaneLifiExecutor.FillCall memory fillCall =
            _fillCallStruct(address(adapter), _orderId(order), order.outputs[0]);
        fillCall.routes[0] = _discountRoute(address(adapter), 10 ether, 9.5 ether, keccak256("discount"), 50_000);

        vm.expectRevert(abi.encodeWithSelector(ILiquidLaneLifiExecutor.InvalidDiscount.selector, 50_000, 100_000));
        executor.finaliseWithCurrentTimestamp(order, abi.encode(fillCall));
    }

    function testFinaliseWithCurrentTimestampRejectsExpiredPrivateDiscount() public {
        vm.warp(1000);
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        _openOrder(order);
        ILiquidLaneLifiExecutor.FillCall memory fillCall =
            _fillCallStruct(address(adapter), _orderId(order), order.outputs[0]);
        fillCall.routes[0] = _discountRoute(address(adapter), 10 ether, 10 ether, keccak256("discount"), 0);
        fillCall.routes[0].discount.discountSwap.discount.deadline = 999;

        vm.expectRevert(
            abi.encodeWithSelector(ILiquidLaneLifiExecutor.DiscountExpired.selector, uint48(999), uint48(1100), 1000)
        );
        executor.finaliseWithCurrentTimestamp(order, abi.encode(fillCall));
    }

    function testFinaliseWithCurrentTimestampRejectsPrivateDiscountTokenMismatch() public {
        vm.warp(1000);
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        _openOrder(order);
        ILiquidLaneLifiExecutor.FillCall memory fillCall =
            _fillCallStruct(address(adapter), _orderId(order), order.outputs[0]);
        fillCall.routes[0] = _discountRoute(address(adapter), 10 ether, 10 ether, keccak256("discount"), 0);
        fillCall.routes[0].discount.discountSwap.discount.tokenToRedeem = makeAddr("wrongToken");

        vm.expectRevert(
            abi.encodeWithSelector(
                ILiquidLaneLifiExecutor.DiscountTokenMismatch.selector,
                address(rwa),
                fillCall.routes[0].discount.discountSwap.discount.tokenToRedeem
            )
        );
        executor.finaliseWithCurrentTimestamp(order, abi.encode(fillCall));
    }

    function testFinaliseWithCurrentTimestampAppliesAdapterMinDiscount() public {
        adapter.setMinDiscount(100_000);
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        _openOrder(order);
        ILiquidLaneLifiExecutor.FillCall memory fillCall =
            _fillCallStruct(address(adapter), _orderId(order), order.outputs[0]);

        vm.expectRevert(
            abi.encodeWithSelector(
                ILiquidLaneLifiExecutor.RouteOutputTooLow.selector, address(adapter), 10 ether, 9 ether
            )
        );
        executor.finaliseWithCurrentTimestamp(order, abi.encode(fillCall));
    }

    function testFinaliseWithCurrentTimestampRejectsRouteInputMismatch() public {
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        _openOrder(order);
        ILiquidLaneLifiExecutor.FillCall memory fillCall =
            _fillCallStruct(address(adapter), _orderId(order), order.outputs[0]);
        fillCall.routes[0].amountIn = 9 ether;
        fillCall.routes[0].expectedAmountOut = 9 ether;
        fillCall.routes[0].minAmountOut = 9 ether;

        vm.expectRevert(abi.encodeWithSelector(ILiquidLaneLifiExecutor.RouteInputMismatch.selector, 9 ether, 10 ether));
        executor.finaliseWithCurrentTimestamp(order, abi.encode(fillCall));
    }

    function testFinaliseWithCurrentTimestampRejectsEmptyRoutes() public {
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        _openOrder(order);
        ILiquidLaneLifiExecutor.FillCall memory fillCall =
            _fillCallStruct(address(adapter), _orderId(order), order.outputs[0]);
        fillCall.routes = new ILiquidLaneLifiExecutor.FillRoute[](0);

        vm.expectRevert(ILiquidLaneLifiExecutor.EmptyRoutes.selector);
        executor.finaliseWithCurrentTimestamp(order, abi.encode(fillCall));
    }

    function testFinaliseWithCurrentTimestampRejectsFillDeadlineMismatch() public {
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        ILiquidLaneLifiExecutor.FillCall memory fillCall =
            _fillCallStruct(address(adapter), _orderId(order), _output(9 ether));
        fillCall.fillDeadline = order.fillDeadline + 1;

        vm.expectRevert(ILiquidLaneLifiExecutor.InvalidOrderOutput.selector);
        executor.finaliseWithCurrentTimestamp(order, abi.encode(fillCall));
    }

    function testFinaliseWithCurrentTimestampRejectsFillAfterWithoutAuction() public {
        vm.warp(1000);
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        ILiquidLaneLifiExecutor.FillCall memory fillCall =
            _fillCallStruct(address(adapter), _orderId(order), order.outputs[0]);
        fillCall.fillAfter = uint32(block.timestamp);

        vm.expectRevert(ILiquidLaneLifiExecutor.FillAfterWithoutAuction.selector);
        executor.finaliseWithCurrentTimestamp(order, abi.encode(fillCall));
    }

    function testFinaliseWithCurrentTimestampRejectsAuctionFillTooEarly() public {
        vm.warp(1000);
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        order.outputs[0].context = _dutchContext(900, 1100, 0.01 ether);
        bytes32 orderId = _orderId(order);
        ILiquidLaneLifiExecutor.FillCall memory fillCall = _fillCallStruct(address(adapter), orderId, order.outputs[0]);
        fillCall.fillAfter = uint32(block.timestamp + 1);

        vm.expectRevert(abi.encodeWithSelector(ILiquidLaneLifiExecutor.FillTooEarly.selector, 1001, 1000));
        executor.finaliseWithCurrentTimestamp(order, abi.encode(fillCall));
    }

    function testMockFinaliseRejectsStaleOrFutureTimestamp() public {
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        IInputSettler.SolveParams[] memory solveParams = new IInputSettler.SolveParams[](1);
        solveParams[0].solver = _id(address(executor));

        vm.warp(100);
        solveParams[0].timestamp = 99;
        vm.expectRevert(MockInputSettler.TimestampPassed.selector);
        inputSettler.finalise(order, solveParams, _id(address(executor)), _fillCallData(9 ether));

        solveParams[0].timestamp = 101;
        vm.expectRevert(MockInputSettler.TimestampNotPassed.selector);
        inputSettler.finalise(order, solveParams, _id(address(executor)), _fillCallData(9 ether));
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

    function testOrderFinalisedExecutesArbitraryAdapter() public {
        MockLifiAdapter otherAdapter = new MockLifiAdapter(outputToken);
        outputToken.mint(address(otherAdapter), 10 ether);
        inputSettler.setOrderStatus(ORDER_ID, ORDER_STATUS_CLAIMED);
        rwa.mint(address(executor), 10 ether);

        vm.prank(address(inputSettler));
        executor.orderFinalised(_inputs(10 ether), _fillCallData(address(otherAdapter), 9 ether));

        assertEq(rwa.balanceOf(address(otherAdapter)), 10 ether);
        assertEq(outputToken.balanceOf(recipient), 9 ether);
        assertEq(outputToken.balanceOf(address(executor)), 1 ether);
    }

    function testOrderFinalisedKeepsOutputSeparateWhenExecutorIsRecipient() public {
        inputSettler.setOrderStatus(ORDER_ID, ORDER_STATUS_CLAIMED);
        rwa.mint(address(executor), 10 ether);
        MandateOutput memory output = _output(9 ether);
        output.recipient = _id(address(executor));

        vm.prank(address(inputSettler));
        executor.orderFinalised(_inputs(10 ether), _fillCallData(output));

        assertEq(outputToken.balanceOf(address(executor)), 10 ether);
    }

    function testOrderFinalisedKeepsCallbackRefundSeparateFromSurplusAccounting() public {
        RefundingOutputRecipient outputRecipient = new RefundingOutputRecipient(outputToken, address(executor), 1 ether);
        inputSettler.setOrderStatus(ORDER_ID, ORDER_STATUS_CLAIMED);
        rwa.mint(address(executor), 10 ether);
        MandateOutput memory output = _output(9 ether);
        output.recipient = _id(address(outputRecipient));
        output.callbackData = hex"01";

        vm.prank(address(inputSettler));
        executor.orderFinalised(_inputs(10 ether), _fillCallData(output));

        assertEq(outputToken.balanceOf(address(outputRecipient)), 8 ether);
        assertEq(outputToken.balanceOf(address(executor)), 2 ether);
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
        MandateOutput memory output =
            _output(9 ether, _exclusiveContext(_id(address(executor)), uint32(block.timestamp)));
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

        vm.expectRevert(
            abi.encodeWithSelector(
                ILiquidLaneLifiExecutor.RouteOutputTooLow.selector, address(adapter), 10 ether, 8 ether
            )
        );
        vm.prank(address(inputSettler));
        executor.orderFinalised(_inputs(10 ether), _fillCallData(9 ether));
    }

    function testOrderFinalisedClampsDirectOutputToLiveCapacityAboveMinimum() public {
        inputSettler.setOrderStatus(ORDER_ID, ORDER_STATUS_CLAIMED);
        adapter.setMaxAssets(9.5 ether);
        rwa.mint(address(executor), 10 ether);

        ILiquidLaneLifiExecutor.FillCall memory fillCall = _fillCallStruct(address(adapter), _output(9 ether));
        fillCall.routes[0].minAmountOut = 9.25 ether;

        vm.prank(address(inputSettler));
        executor.orderFinalised(_inputs(10 ether), abi.encode(fillCall));

        assertEq(outputToken.balanceOf(recipient), 9 ether);
        assertEq(outputToken.balanceOf(address(executor)), 0.5 ether);
    }

    function testOrderFinalisedRejectsPrivateOutputAboveLiveCapacity() public {
        vm.warp(1000);
        inputSettler.setOrderStatus(ORDER_ID, ORDER_STATUS_CLAIMED);
        adapter.setMaxAssets(8.5 ether);
        rwa.mint(address(executor), 10 ether);

        ILiquidLaneLifiExecutor.FillCall memory fillCall = _fillCallStruct(address(adapter), _output(8 ether));
        fillCall.routes[0] = _discountRoute(address(adapter), 10 ether, 9 ether, keccak256("discount"), 100_000);

        vm.expectRevert(
            abi.encodeWithSelector(
                ILiquidLaneLifiExecutor.PrivateRouteExceedsCapacity.selector, address(adapter), 9 ether, 8.5 ether
            )
        );
        vm.prank(address(inputSettler));
        executor.orderFinalised(_inputs(10 ether), abi.encode(fillCall));
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

        vm.expectRevert(
            abi.encodeWithSelector(
                ILiquidLaneLifiExecutor.RouteOutputTooLow.selector, address(adapter), 10 ether, 9.5 ether
            )
        );
        vm.prank(address(inputSettler));
        executor.orderFinalised(_inputs(10 ether), _fillCallData(output));
    }

    function testOrderFinalisedRejectsExclusiveSolverMismatchBeforeStart() public {
        vm.warp(1000);
        inputSettler.setOrderStatus(ORDER_ID, ORDER_STATUS_CLAIMED);

        bytes32 exclusiveFor = _id(makeAddr("otherSolver"));
        MandateOutput memory output = _output(9 ether, _exclusiveContext(exclusiveFor, 1001));

        vm.expectRevert(
            abi.encodeWithSelector(
                ILiquidLaneLifiExecutor.ExclusiveForMismatch.selector, exclusiveFor, _id(address(executor))
            )
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

    function testOrderFinalisedSupportsSameInputAndOutputTokenAccounting() public {
        inputSettler.setOrderStatus(ORDER_ID, ORDER_STATUS_CLAIMED);
        MockLifiAdapter sameTokenAdapter = new MockLifiAdapter(rwa);

        rwa.mint(address(executor), 10 ether);
        rwa.mint(address(sameTokenAdapter), 10 ether);

        vm.prank(address(inputSettler));
        executor.orderFinalised(_inputs(10 ether), _fillCallData(address(sameTokenAdapter), address(rwa), 10 ether));

        assertEq(rwa.balanceOf(address(executor)), 0);
        assertEq(rwa.balanceOf(address(sameTokenAdapter)), 10 ether);
        assertEq(rwa.balanceOf(recipient), 10 ether);
    }

    function testOrderFinalisedExecutesMultipleRoutesAndKeepsSurplus() public {
        MockLifiAdapter secondAdapter = new MockLifiAdapter(outputToken);
        outputToken.mint(address(secondAdapter), 100 ether);

        inputSettler.setOrderStatus(ORDER_ID, ORDER_STATUS_CLAIMED);
        rwa.mint(address(executor), 10 ether);

        ILiquidLaneLifiExecutor.FillCall memory fillCall = _fillCallStruct(address(adapter), _output(9 ether));
        fillCall.routes = new ILiquidLaneLifiExecutor.FillRoute[](2);
        fillCall.routes[0] = _directRoute(address(adapter), 4 ether, 4 ether);
        fillCall.routes[1] = _directRoute(address(secondAdapter), 6 ether, 6 ether);

        vm.prank(address(inputSettler));
        executor.orderFinalised(_inputs(10 ether), abi.encode(fillCall));

        assertEq(rwa.balanceOf(address(adapter)), 4 ether);
        assertEq(rwa.balanceOf(address(secondAdapter)), 6 ether);
        assertEq(outputToken.balanceOf(recipient), 9 ether);
        assertEq(outputToken.balanceOf(address(executor)), 1 ether);
    }

    function testOrderFinalisedRejectsActualRouteUnderDeliveryEvenWhenAggregatePasses() public {
        MockLifiAdapter secondAdapter = new MockLifiAdapter(outputToken);
        outputToken.mint(address(secondAdapter), 100 ether);
        adapter.setNextOutputAmount(3 ether);
        secondAdapter.setBonus(1 ether);

        inputSettler.setOrderStatus(ORDER_ID, ORDER_STATUS_CLAIMED);
        rwa.mint(address(executor), 10 ether);

        ILiquidLaneLifiExecutor.FillCall memory fillCall = _fillCallStruct(address(adapter), _output(9 ether));
        fillCall.routes = new ILiquidLaneLifiExecutor.FillRoute[](2);
        fillCall.routes[0] = _directRoute(address(adapter), 4 ether, 4 ether);
        fillCall.routes[1] = _directRoute(address(secondAdapter), 6 ether, 6 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                ILiquidLaneLifiExecutor.RouteOutputTooLow.selector, address(adapter), 4 ether, 3 ether
            )
        );
        vm.prank(address(inputSettler));
        executor.orderFinalised(_inputs(10 ether), abi.encode(fillCall));
    }

    function testMockOutputSettlerFillIsIdempotent() public {
        MandateOutput memory output = _output(9 ether);
        outputToken.mint(address(this), 18 ether);
        outputToken.approve(address(outputSettler), 18 ether);

        bytes32 firstRecord = outputSettler.fill(ORDER_ID, output, uint48(block.timestamp), abi.encode(MOCK_SOLVER));
        bytes32 secondRecord = outputSettler.fill(ORDER_ID, output, uint48(block.timestamp), abi.encode(MOCK_SOLVER));

        assertEq(secondRecord, firstRecord);
        assertEq(outputToken.balanceOf(recipient), 9 ether);
        assertEq(outputToken.balanceOf(address(this)), 9 ether);
    }

    function testMockOutputSettlerInvokesOutputCallback() public {
        MockOutputRecipient outputRecipient = new MockOutputRecipient();
        MandateOutput memory output = _output(9 ether);
        output.recipient = _id(address(outputRecipient));
        output.callbackData = hex"1234";
        outputToken.mint(address(this), 9 ether);
        outputToken.approve(address(outputSettler), 9 ether);

        outputSettler.fill(ORDER_ID, output, uint48(block.timestamp), abi.encode(MOCK_SOLVER));

        assertEq(outputRecipient.token(), output.token);
        assertEq(outputRecipient.amount(), 9 ether);
        assertEq(outputRecipient.callbackData(), hex"1234");
    }

    function testOwnerSweepsFillSurplus() public {
        inputSettler.setOrderStatus(ORDER_ID, ORDER_STATUS_CLAIMED);
        rwa.mint(address(executor), 10 ether);
        vm.prank(address(inputSettler));
        executor.orderFinalised(_inputs(10 ether), _fillCallData(9 ether));

        vm.prank(owner);
        executor.sweepERC20(address(outputToken), collector, 1 ether);

        assertEq(outputToken.balanceOf(collector), 1 ether);
        assertEq(outputToken.balanceOf(address(executor)), 0);
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

    function _openOrder(IInputSettler.StandardOrder memory order) internal {
        inputSettler.setOrderStatus(_orderId(order), ORDER_STATUS_DEPOSITED);
        rwa.mint(address(inputSettler), order.inputs[0][1]);
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
        ILiquidLaneLifiExecutor.FillRoute[] memory routes = new ILiquidLaneLifiExecutor.FillRoute[](1);
        routes[0] = _directRoute(fillAdapter, 10 ether, 10 ether);
        return ILiquidLaneLifiExecutor.FillCall({
            orderId: orderId,
            output: output,
            fillDeadline: uint32(block.timestamp + 1 hours),
            fillAfter: 0,
            routes: routes
        });
    }

    function _directRoute(address fillAdapter, uint256 amountIn, uint256 expectedAmountOut)
        internal
        pure
        returns (ILiquidLaneLifiExecutor.FillRoute memory)
    {
        return ILiquidLaneLifiExecutor.FillRoute({
            adapter: fillAdapter,
            amountIn: amountIn,
            expectedAmountOut: expectedAmountOut,
            minAmountOut: expectedAmountOut,
            discount: _emptyDiscount()
        });
    }

    function _discountRoute(
        address fillAdapter,
        uint256 amountIn,
        uint256 expectedAmountOut,
        bytes32 discountId,
        uint256 discount
    ) internal view returns (ILiquidLaneLifiExecutor.FillRoute memory) {
        return ILiquidLaneLifiExecutor.FillRoute({
            adapter: fillAdapter,
            amountIn: amountIn,
            expectedAmountOut: expectedAmountOut,
            minAmountOut: expectedAmountOut,
            discount: ILiquidLaneLifiExecutor.FillDiscount({
                discountId: discountId,
                discountSwap: ILiquidLaneAdapter.DiscountSwap({
                    discount: ILiquidLaneAdapter.Discount({
                        tokenToRedeem: address(rwa),
                        discount: discount,
                        signer: DISCOUNT_SIGNER,
                        protocol: address(0xBEEF),
                        nonce: 1,
                        deadline: uint48(block.timestamp + 100)
                    }),
                    signerSignature: hex"1234",
                    protocolDeadline: uint48(block.timestamp + 100)
                }),
                protocolSignature: hex"5678"
            })
        });
    }

    function _emptyDiscount() internal pure returns (ILiquidLaneLifiExecutor.FillDiscount memory) {
        return ILiquidLaneLifiExecutor.FillDiscount({
            discountId: bytes32(0),
            discountSwap: ILiquidLaneAdapter.DiscountSwap({
                discount: ILiquidLaneAdapter.Discount({
                    tokenToRedeem: address(0),
                    discount: 0,
                    signer: address(0),
                    protocol: address(0),
                    nonce: 0,
                    deadline: 0
                }),
                signerSignature: "",
                protocolDeadline: 0
            }),
            protocolSignature: ""
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

    function setOrderStatus(bytes32 orderId, uint8 status) public {
        orderStatus[orderId] = status;
    }

    function orderIdentifier(StandardOrder calldata order) external pure returns (bytes32 orderId) {
        return _orderId(order);
    }

    function finalise(
        StandardOrder calldata order,
        SolveParams[] calldata solveParams,
        bytes32 destination,
        bytes calldata call
    ) external {
        if (solveParams.length != 1) revert InvalidTimestampLength();
        if (solveParams[0].timestamp < block.timestamp) revert TimestampPassed();
        if (solveParams[0].timestamp > block.timestamp) revert TimestampNotPassed();

        lastTimestamp = solveParams[0].timestamp;
        lastSolver = solveParams[0].solver;
        lastDestination = destination;

        _finalise(_orderId(order), address(uint160(uint256(destination))), order.inputs, call);
    }

    function finaliseCallback(address destination, uint256[2][] memory inputs, bytes memory call) public {
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
        bytes32 outputHash = _outputHash(output);
        fillRecordHash = fillRecords[orderId][outputHash];
        if (fillRecordHash != bytes32(0)) return fillRecordHash;

        fillRecordHash = keccak256(abi.encodePacked(solver, uint32(block.timestamp)));
        fillRecords[orderId][outputHash] = fillRecordHash;
        lastOrderId = orderId;
        lastSolver = solver;
        lastOutputAmount = resolvedAmount;

        IERC20(token).safeTransferFrom(msg.sender, recipient, resolvedAmount);
        if (output.callbackData.length != 0) {
            IOutputCallbackLike(recipient).outputFilled(output.token, resolvedAmount, output.callbackData);
        }
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
    uint256 public discount;
    uint256 public nextOutputAmount;
    uint256 public maxAssets = type(uint256).max;

    constructor(TestToken outputToken_) {
        outputToken = outputToken_;
    }

    function setBonus(uint256 bonus_) public {
        bonus = bonus_;
    }

    function setNextOutputAmount(uint256 amount) public {
        nextOutputAmount = amount;
    }

    function setMinDiscount(uint256 discount_) public {
        discount = discount_;
    }

    function setMaxAssets(uint256 maxAssets_) public {
        maxAssets = maxAssets_;
    }

    function getAmountOut(address, uint256 amountIn) external pure returns (uint256) {
        return amountIn;
    }

    function getMaxAssets(address) external returns (uint256) {
        return maxAssets;
    }

    function minDiscount(address) external view returns (uint256) {
        return discount;
    }

    function swap(ILiquidLaneAdapter.Swap calldata swap_) public {
        require(IERC20(swap_.tokenIn).balanceOf(address(this)) >= swap_.amountIn, "missing input");

        uint256 amount = nextOutputAmount == 0 ? swap_.amountOut + bonus : nextOutputAmount;
        nextOutputAmount = 0;
        outputToken.transfer(swap_.recipient, amount);
    }

    function swap(ILiquidLaneAdapter.SignedSwap calldata, bytes calldata) public {}

    function swap(
        ILiquidLaneAdapter.DiscountSwap calldata discountSwap,
        bytes calldata,
        address recipient,
        uint256 amountIn
    ) public returns (uint256) {
        require(IERC20(discountSwap.discount.tokenToRedeem).balanceOf(address(this)) >= amountIn, "missing input");
        uint256 amountOut = amountIn * (1_000_000 - discountSwap.discount.discount) / 1_000_000;
        outputToken.transfer(recipient, amountOut);
        return amountOut;
    }
}

contract MockOutputRecipient is IOutputCallbackLike {
    bytes32 public token;
    uint256 public amount;
    bytes public callbackData;

    function outputFilled(bytes32 token_, uint256 amount_, bytes calldata callbackData_) external {
        token = token_;
        amount = amount_;
        callbackData = callbackData_;
    }
}

contract RefundingOutputRecipient is IOutputCallbackLike {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    address public immutable recipient;
    uint256 public immutable refundAmount;

    constructor(IERC20 token_, address recipient_, uint256 refundAmount_) {
        token = token_;
        recipient = recipient_;
        refundAmount = refundAmount_;
    }

    function outputFilled(bytes32, uint256, bytes calldata) external {
        token.safeTransfer(recipient, refundAmount);
    }
}

contract TestToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}
