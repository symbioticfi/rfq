// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.28;

import {Executor} from "../src/Executor.sol";
import {Reactor} from "../src/Reactor.sol";
import {IExecutor} from "../src/interfaces/IExecutor.sol";
import {ILiquidLaneAdapter} from "../src/interfaces/ILiquidLaneAdapter.sol";
import {IReactor, NATIVE, ORDER_TYPEHASH, OUTPUT_TYPEHASH, REQUEST_TYPEHASH} from "../src/interfaces/IReactor.sol";

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {Test} from "forge-std/Test.sol";

contract ReactorTest is Test {
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    uint256 internal constant NEW_PROTOCOL_PRIVATE_KEY = 0xB0B;
    uint256 internal constant PROTOCOL_PRIVATE_KEY = 0xA11CE;
    uint256 internal constant SWAPPER_PRIVATE_KEY = 0xBEEF;

    address internal filler = makeAddr("filler");
    address internal newProtocol = vm.addr(NEW_PROTOCOL_PRIVATE_KEY);
    address internal protocol = vm.addr(PROTOCOL_PRIVATE_KEY);
    address internal referrer = makeAddr("referrer");
    address internal swapper = vm.addr(SWAPPER_PRIVATE_KEY);
    address internal vault0 = makeAddr("vault0");
    address internal vault1 = makeAddr("vault1");
    address internal vault0Account = makeAddr("vault0Account");
    address internal vault1Account = makeAddr("vault1Account");

    MockAdapter internal adapter;
    MockAdapter internal secondaryAdapter;
    MockAdapterFactory internal adapterFactory;
    MockCallTarget internal callTarget;
    MockERC20 internal outputToken;
    MockERC20 internal rwa;
    Executor internal executor;
    Reactor internal reactor;

    function setUp() public {
        adapter = new MockAdapter();
        secondaryAdapter = new MockAdapter();
        adapterFactory = new MockAdapterFactory();
        adapterFactory.setEntity(address(adapter), true);
        adapterFactory.setEntity(address(secondaryAdapter), true);
        callTarget = new MockCallTarget();
        reactor = new Reactor(address(adapterFactory));
        executor = new Executor(address(reactor), address(this), _callers(filler));

        rwa = new MockERC20("RWA", "RWA");
        outputToken = new MockERC20("USD", "USD");

        adapter.setAccount(vault0, address(rwa), vault0Account);
        secondaryAdapter.setAccount(vault1, address(rwa), vault1Account);

        rwa.mint(swapper, 100 ether);
        vm.prank(swapper);
        rwa.approve(address(reactor), type(uint256).max);
    }

    function testFillTransfersRwaIntoAccountsAndDeliversOutputs() public {
        outputToken.mint(address(executor), 10 ether);

        IReactor.Output[] memory outputs = new IReactor.Output[](2);
        outputs[0] = IReactor.Output({token: address(outputToken), amount: 7 ether, recipient: swapper});
        outputs[1] = IReactor.Output({token: address(outputToken), amount: 3 ether, recipient: referrer});

        IExecutor.Call[] memory calls = new IExecutor.Call[](0);
        IReactor.SwapInput memory swap = _swapInput(vault0, 10 ether, 10 ether);

        IReactor.Order memory order = _order(outputs, 10 ether);
        bytes memory protocolSignature = _signOrder(order);

        vm.prank(filler);
        executor.fill(order, protocolSignature, swap, abi.encode(calls));

        assertEq(rwa.balanceOf(vault0Account), 10 ether);
        assertEq(rwa.balanceOf(vault1Account), 0);
        assertEq(outputToken.balanceOf(swapper), 7 ether);
        assertEq(outputToken.balanceOf(referrer), 3 ether);
        assertEq(rwa.balanceOf(address(reactor)), 0);
        assertEq(rwa.balanceOf(address(adapter)), 0);
        assertEq(adapter.swapCount(), 1);
        assertEq(adapter.signedSwapCount(), 0);
    }

    function testFillTransfersRwaIntoMultipleAccountsAndDeliversOutputs() public {
        outputToken.mint(address(executor), 10 ether);

        IReactor.Output[] memory outputs = new IReactor.Output[](1);
        outputs[0] = IReactor.Output({token: address(outputToken), amount: 10 ether, recipient: swapper});

        IExecutor.Call[] memory calls = new IExecutor.Call[](0);
        IReactor.SwapInput[] memory swapInputs = new IReactor.SwapInput[](2);
        swapInputs[0] = _swapInput(vault0, 4 ether, 4 ether);
        swapInputs[1] = _swapInput(address(secondaryAdapter), vault1, 6 ether, 6 ether);

        IReactor.Order memory order = _order(outputs, 10 ether);
        bytes memory protocolSignature = _signOrder(order);

        vm.prank(filler);
        executor.fill(order, protocolSignature, swapInputs, abi.encode(calls));

        assertEq(rwa.balanceOf(vault0Account), 4 ether);
        assertEq(rwa.balanceOf(vault1Account), 6 ether);
        assertEq(outputToken.balanceOf(swapper), 10 ether);
        assertEq(adapter.swapCount(), 1);
        assertEq(secondaryAdapter.swapCount(), 1);
    }

    function testFillRoutesSwapInputsToTheirAdapters() public {
        outputToken.mint(address(executor), 10 ether);

        IReactor.Output[] memory outputs = new IReactor.Output[](1);
        outputs[0] = IReactor.Output({token: address(outputToken), amount: 10 ether, recipient: swapper});

        IExecutor.Call[] memory calls = new IExecutor.Call[](0);
        IReactor.SwapInput[] memory swapInputs = new IReactor.SwapInput[](2);
        swapInputs[0] = _swapInput(address(adapter), vault0, 4 ether, 4 ether);
        swapInputs[1] = _swapInput(address(secondaryAdapter), vault1, 6 ether, 6 ether);

        IReactor.Order memory order = _order(outputs, 10 ether);
        bytes memory protocolSignature = _signOrder(order);

        vm.prank(filler);
        executor.fill(order, protocolSignature, swapInputs, abi.encode(calls));

        assertEq(rwa.balanceOf(vault0Account), 4 ether);
        assertEq(rwa.balanceOf(vault1Account), 6 ether);
        assertEq(outputToken.balanceOf(swapper), 10 ether);
        assertEq(adapter.swapCount(), 1);
        assertEq(secondaryAdapter.swapCount(), 1);
        assertEq(rwa.balanceOf(address(adapter)), 0);
        assertEq(rwa.balanceOf(address(secondaryAdapter)), 0);
    }

    function testFillRevertsIfOutputsAreNotSatisfied() public {
        outputToken.mint(address(executor), 4 ether);

        IReactor.Output[] memory outputs = new IReactor.Output[](1);
        outputs[0] = IReactor.Output({token: address(outputToken), amount: 5 ether, recipient: swapper});

        IExecutor.Call[] memory calls = new IExecutor.Call[](0);
        IReactor.SwapInput memory swap = _swapInput(vault0, 5 ether, 5 ether);

        IReactor.Order memory order = _order(outputs, 5 ether);
        bytes memory protocolSignature = _signOrder(order);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(executor), 4 ether, 5 ether)
        );
        vm.prank(filler);
        executor.fill(order, protocolSignature, swap, abi.encode(calls));

        assertEq(rwa.balanceOf(vault0Account), 0);
        assertEq(outputToken.balanceOf(swapper), 0);
    }

    function testFillRevertsIfOrderOutputsMissRequestOutput() public {
        IReactor.Output[] memory outputs = new IReactor.Output[](1);
        outputs[0] = IReactor.Output({token: address(outputToken), amount: 5 ether, recipient: swapper});

        IExecutor.Call[] memory calls = new IExecutor.Call[](0);
        IReactor.SwapInput memory swap = _swapInput(vault0, 5 ether, 5 ether);

        IReactor.Order memory order = _order(outputs, 5 ether);
        order.outputs[0] = IReactor.Output({token: address(outputToken), amount: 5 ether, recipient: referrer});
        bytes memory protocolSignature = _signOrder(order);

        vm.expectRevert(IReactor.InvalidOutput.selector);
        vm.prank(filler);
        executor.fill(order, protocolSignature, swap, abi.encode(calls));

        assertEq(rwa.balanceOf(vault0Account), 0);
        assertEq(outputToken.balanceOf(swapper), 0);
        assertEq(outputToken.balanceOf(referrer), 0);
    }

    function testFillRevertsIfOrderOutputAmountIsLessThanRequestOutput() public {
        IReactor.Output[] memory outputs = new IReactor.Output[](1);
        outputs[0] = IReactor.Output({token: address(outputToken), amount: 5 ether, recipient: swapper});

        IExecutor.Call[] memory calls = new IExecutor.Call[](0);
        IReactor.SwapInput memory swap = _swapInput(vault0, 5 ether, 5 ether);

        IReactor.Order memory order = _order(outputs, 5 ether);
        IReactor.Output[] memory orderOutputs = new IReactor.Output[](1);
        orderOutputs[0] = IReactor.Output({token: address(outputToken), amount: 4 ether, recipient: swapper});
        order.outputs = orderOutputs;
        bytes memory protocolSignature = _signOrder(order);

        vm.expectRevert(IReactor.InvalidOutput.selector);
        vm.prank(filler);
        executor.fill(order, protocolSignature, swap, abi.encode(calls));

        assertEq(rwa.balanceOf(vault0Account), 0);
        assertEq(outputToken.balanceOf(swapper), 0);
    }

    function testFillRevertsIfOrderOutputsLengthDoesNotMatchRequestOutputs() public {
        IReactor.Output[] memory outputs = new IReactor.Output[](1);
        outputs[0] = IReactor.Output({token: address(outputToken), amount: 5 ether, recipient: swapper});

        IExecutor.Call[] memory calls = new IExecutor.Call[](0);
        IReactor.SwapInput memory swap = _swapInput(vault0, 5 ether, 5 ether);

        IReactor.Order memory order = _order(outputs, 5 ether);
        IReactor.Output[] memory orderOutputs = new IReactor.Output[](2);
        orderOutputs[0] = IReactor.Output({token: address(outputToken), amount: 6 ether, recipient: swapper});
        orderOutputs[1] = IReactor.Output({token: address(outputToken), amount: 1 ether, recipient: referrer});
        order.outputs = orderOutputs;
        bytes memory protocolSignature = _signOrder(order);

        vm.expectRevert(IReactor.InvalidOutput.selector);
        vm.prank(filler);
        executor.fill(order, protocolSignature, swap, abi.encode(calls));

        assertEq(rwa.balanceOf(vault0Account), 0);
        assertEq(outputToken.balanceOf(swapper), 0);
    }

    function testFillDeliversHigherOrderOutputsThatMeetRequestMinimums() public {
        outputToken.mint(address(executor), 6 ether);

        IReactor.Output[] memory outputs = new IReactor.Output[](1);
        outputs[0] = IReactor.Output({token: address(outputToken), amount: 5 ether, recipient: swapper});

        IExecutor.Call[] memory calls = new IExecutor.Call[](0);
        IReactor.SwapInput memory swap = _swapInput(vault0, 5 ether, 5 ether);

        IReactor.Order memory order = _order(outputs, 5 ether);
        IReactor.Output[] memory orderOutputs = new IReactor.Output[](1);
        orderOutputs[0] = IReactor.Output({token: address(outputToken), amount: 6 ether, recipient: swapper});
        order.outputs = orderOutputs;
        bytes memory protocolSignature = _signOrder(order);

        vm.prank(filler);
        executor.fill(order, protocolSignature, swap, abi.encode(calls));

        assertEq(rwa.balanceOf(vault0Account), 5 ether);
        assertEq(outputToken.balanceOf(swapper), 6 ether);
    }

    function testExecutorRequiresCaller() public {
        Reactor customReactor = new Reactor(address(adapterFactory));
        Executor lockedExecutor = new Executor(address(customReactor), address(this), new address[](0));

        outputToken.mint(address(lockedExecutor), 5 ether);

        IReactor.Output[] memory outputs = new IReactor.Output[](1);
        outputs[0] = IReactor.Output({token: address(outputToken), amount: 5 ether, recipient: swapper});

        IExecutor.Call[] memory calls = new IExecutor.Call[](0);
        IReactor.SwapInput memory swap = _swapInput(vault0, 5 ether, 5 ether);

        IReactor.Order memory order = _order(outputs, 5 ether, address(lockedExecutor), customReactor);
        bytes memory protocolSignature = _signOrder(order, customReactor);

        vm.expectRevert(IExecutor.NotCaller.selector);
        vm.prank(filler);
        lockedExecutor.fill(order, protocolSignature, swap, abi.encode(calls));

        lockedExecutor.setCallers(_callers(filler));
        vm.prank(swapper);
        rwa.approve(address(customReactor), type(uint256).max);

        vm.prank(filler);
        lockedExecutor.fill(order, protocolSignature, swap, abi.encode(calls));

        assertEq(outputToken.balanceOf(swapper), 5 ether);
        assertEq(rwa.balanceOf(vault0Account), 5 ether);
        assertEq(adapter.swapCount(), 1);
        assertEq(adapter.signedSwapCount(), 0);
    }

    function testFillRevertsIfExecutorDoesNotMatchOrderFiller() public {
        Executor otherExecutor = new Executor(address(reactor), address(this), _callers(filler));

        IReactor.Output[] memory outputs = new IReactor.Output[](1);
        outputs[0] = IReactor.Output({token: address(outputToken), amount: 5 ether, recipient: swapper});

        IExecutor.Call[] memory calls = new IExecutor.Call[](0);
        IReactor.SwapInput memory swap = _swapInput(vault0, 5 ether, 5 ether);
        IReactor.Order memory order = _order(outputs, 5 ether, address(otherExecutor));
        bytes memory protocolSignature = _signOrder(order);

        vm.expectRevert(IReactor.InvalidFiller.selector);
        vm.prank(filler);
        executor.fill(order, protocolSignature, swap, abi.encode(calls));
    }

    function testFillTransfersNativeOutputs() public {
        vm.deal(address(executor), 2 ether);

        IReactor.Output[] memory outputs = new IReactor.Output[](1);
        outputs[0] = IReactor.Output({token: NATIVE, amount: 2 ether, recipient: swapper});

        IExecutor.Call[] memory calls = new IExecutor.Call[](0);
        IReactor.SwapInput memory swap = _swapInput(vault0, 5 ether, 5 ether);

        IReactor.Order memory order = _order(outputs, 5 ether);
        bytes memory protocolSignature = _signOrder(order);
        uint256 balanceBefore = swapper.balance;

        vm.prank(filler);
        executor.fill(order, protocolSignature, swap, abi.encode(calls));

        assertEq(swapper.balance, balanceBefore + 2 ether);
        assertEq(address(executor).balance, 0);
        assertEq(address(reactor).balance, 0);
        assertEq(rwa.balanceOf(vault0Account), 5 ether);
    }

    function testFillRefundsNativeSurplusToExecutor() public {
        vm.deal(address(executor), 3 ether);

        IReactor.Output[] memory outputs = new IReactor.Output[](1);
        outputs[0] = IReactor.Output({token: NATIVE, amount: 2 ether, recipient: swapper});

        IExecutor.Call[] memory calls = new IExecutor.Call[](0);
        IReactor.SwapInput memory swap = _swapInput(vault0, 5 ether, 5 ether);

        IReactor.Order memory order = _order(outputs, 5 ether);
        bytes memory protocolSignature = _signOrder(order);
        uint256 balanceBefore = swapper.balance;

        vm.prank(filler);
        executor.fill(order, protocolSignature, swap, abi.encode(calls));

        assertEq(swapper.balance, balanceBefore + 2 ether);
        assertEq(address(executor).balance, 1 ether);
        assertEq(address(reactor).balance, 0);
    }

    function testFillRevertsIfNativeRecipientReentersFill() public {
        ReentrantNativeRecipient recipient = new ReentrantNativeRecipient(reactor);
        vm.deal(address(executor), 3 ether);

        IReactor.Output[] memory outputs = new IReactor.Output[](1);
        outputs[0] = IReactor.Output({token: NATIVE, amount: 2 ether, recipient: address(recipient)});

        IExecutor.Call[] memory calls = new IExecutor.Call[](0);
        IReactor.SwapInput memory swap = _swapInput(vault0, 5 ether, 5 ether);

        IReactor.Order memory order = _order(outputs, 5 ether);
        bytes memory protocolSignature = _signOrder(order);

        IReactor.Output[] memory reentrantOutputs = new IReactor.Output[](0);
        IReactor.Order memory reentrantOrder = _order(reentrantOutputs, 0, address(recipient));
        reentrantOrder.request.nonce = 2;
        reentrantOrder.swapperSignature = _signRequest(reentrantOrder.request);
        recipient.setReentry(
            abi.encodeCall(
                IReactorFullFill.fill,
                (
                    reentrantOrder,
                    _signOrder(reentrantOrder),
                    new IReactor.SwapInput[](0),
                    new IReactor.DiscountSwapInput[](0),
                    abi.encode(calls)
                )
            )
        );

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        vm.prank(filler);
        executor.fill(order, protocolSignature, swap, abi.encode(calls));

        assertEq(address(recipient).balance, 0);
        assertEq(address(executor).balance, 3 ether);
        assertEq(address(reactor).balance, 0);
    }

    function testFillEmitsFillEvent() public {
        outputToken.mint(address(executor), 5 ether);

        IReactor.Output[] memory outputs = new IReactor.Output[](1);
        outputs[0] = IReactor.Output({token: address(outputToken), amount: 5 ether, recipient: swapper});

        IExecutor.Call[] memory calls = new IExecutor.Call[](0);
        IReactor.SwapInput memory swap = _swapInput(vault0, 5 ether, 5 ether);

        IReactor.Order memory order = _order(outputs, 5 ether);
        bytes memory protocolSignature = _signOrder(order);

        vm.expectEmit(false, false, false, true, address(reactor));
        emit IReactor.Fill(order);

        vm.prank(filler);
        executor.fill(order, protocolSignature, swap, abi.encode(calls));
    }

    function testFillKeepsMaxApproval() public {
        MockApprovalERC20 approvalToken = new MockApprovalERC20("USD", "USD");
        approvalToken.mint(address(executor), 10 ether);

        IReactor.Output[] memory outputs = new IReactor.Output[](1);
        outputs[0] = IReactor.Output({token: address(approvalToken), amount: 5 ether, recipient: swapper});

        IExecutor.Call[] memory calls = new IExecutor.Call[](0);
        IReactor.SwapInput memory swap = _swapInput(vault0, 5 ether, 5 ether);

        IReactor.Order memory order = _order(outputs, 5 ether);
        bytes memory protocolSignature = _signOrder(order);

        vm.prank(filler);
        executor.fill(order, protocolSignature, swap, abi.encode(calls));

        assertEq(approvalToken.allowance(address(executor), address(reactor)), type(uint256).max);
        assertEq(approvalToken.approveCalls(), 1);

        order.request.nonce = 2;
        order.swapperSignature = _signRequest(order.request);
        protocolSignature = _signOrder(order);

        vm.prank(filler);
        executor.fill(order, protocolSignature, swap, abi.encode(calls));

        assertEq(approvalToken.allowance(address(executor), address(reactor)), type(uint256).max);
        assertEq(approvalToken.approveCalls(), 1);
        assertEq(approvalToken.balanceOf(swapper), 10 ether);
    }

    function testFillApprovesMultipleOutputTokens() public {
        MockApprovalERC20 firstToken = new MockApprovalERC20("USD1", "USD1");
        MockApprovalERC20 secondToken = new MockApprovalERC20("USD2", "USD2");
        firstToken.mint(address(executor), 5 ether);
        secondToken.mint(address(executor), 7 ether);

        IReactor.Output[] memory outputs = new IReactor.Output[](2);
        outputs[0] = IReactor.Output({token: address(firstToken), amount: 5 ether, recipient: swapper});
        outputs[1] = IReactor.Output({token: address(secondToken), amount: 7 ether, recipient: referrer});

        IExecutor.Call[] memory calls = new IExecutor.Call[](0);
        IReactor.SwapInput memory swap = _swapInput(vault0, 12 ether, 12 ether);

        IReactor.Order memory order = _order(outputs, 12 ether);
        bytes memory protocolSignature = _signOrder(order);

        vm.prank(filler);
        executor.fill(order, protocolSignature, swap, abi.encode(calls));

        assertEq(firstToken.allowance(address(executor), address(reactor)), type(uint256).max);
        assertEq(secondToken.allowance(address(executor), address(reactor)), type(uint256).max);
        assertEq(firstToken.approveCalls(), 1);
        assertEq(secondToken.approveCalls(), 1);
        assertEq(firstToken.balanceOf(swapper), 5 ether);
        assertEq(secondToken.balanceOf(referrer), 7 ether);
    }

    function testFillUsesRequestProtocol() public {
        outputToken.mint(address(executor), 5 ether);

        IReactor.Output[] memory outputs = new IReactor.Output[](1);
        outputs[0] = IReactor.Output({token: address(outputToken), amount: 5 ether, recipient: swapper});

        IExecutor.Call[] memory calls = new IExecutor.Call[](0);
        IReactor.SwapInput memory swap = _swapInput(vault0, 5 ether, 5 ether);

        IReactor.Order memory order = _order(outputs, 5 ether);
        bytes memory oldProtocolSignature = _signOrder(order);

        order.request.protocol = newProtocol;

        vm.startPrank(filler);
        vm.expectRevert(IReactor.InvalidProtocolSignature.selector);
        executor.fill(order, oldProtocolSignature, swap, abi.encode(calls));

        order.swapperSignature = _signRequest(order.request);
        executor.fill(order, _signOrder(order, reactor, NEW_PROTOCOL_PRIVATE_KEY), swap, abi.encode(calls));
        vm.stopPrank();

        assertEq(outputToken.balanceOf(swapper), 5 ether);
    }

    function testFillRejectsSignatureAfterOutputMutation() public {
        outputToken.mint(address(executor), 6 ether);

        IReactor.Output[] memory outputs = new IReactor.Output[](1);
        outputs[0] = IReactor.Output({token: address(outputToken), amount: 5 ether, recipient: swapper});

        IExecutor.Call[] memory calls = new IExecutor.Call[](0);
        IReactor.SwapInput memory swap = _swapInput(vault0, 5 ether, 5 ether);

        IReactor.Order memory order = _order(outputs, 5 ether);
        bytes memory protocolSignature = _signOrder(order);

        order.request.outputs[0].amount = 6 ether;

        vm.expectRevert(IReactor.InvalidProtocolSignature.selector);
        vm.prank(filler);
        executor.fill(order, protocolSignature, swap, abi.encode(calls));
    }

    function testFillRejectsInvalidSwapperRequestSignature() public {
        IReactor.Output[] memory outputs = new IReactor.Output[](0);
        IExecutor.Call[] memory calls = new IExecutor.Call[](0);
        IReactor.SwapInput memory swap = _swapInput(vault0, 5 ether, 5 ether);

        IReactor.Order memory order = _order(outputs, 5 ether);
        order.swapperSignature = _signRequest(order.request, reactor, NEW_PROTOCOL_PRIVATE_KEY);
        bytes memory protocolSignature = _signOrder(order);

        vm.expectRevert(IReactor.InvalidProtocolSignature.selector);
        vm.prank(filler);
        executor.fill(order, protocolSignature, swap, abi.encode(calls));
    }

    function testFillRevertsIfSwapperHasNotApprovedReactor() public {
        vm.prank(swapper);
        rwa.approve(address(reactor), 0);

        IReactor.Output[] memory outputs = new IReactor.Output[](0);
        IExecutor.Call[] memory calls = new IExecutor.Call[](0);
        IReactor.SwapInput memory swap = _swapInput(vault0, 5 ether, 5 ether);

        IReactor.Order memory order = _order(outputs, 5 ether);
        bytes memory protocolSignature = _signOrder(order);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(reactor), 0, 5 ether)
        );
        vm.prank(filler);
        executor.fill(order, protocolSignature, swap, abi.encode(calls));

        assertEq(rwa.balanceOf(vault0Account), 0);
        assertEq(adapter.swapCount(), 0);
    }

    function testFillRevertsIfRequestIsExpired() public {
        IReactor.Output[] memory outputs = new IReactor.Output[](0);
        IExecutor.Call[] memory calls = new IExecutor.Call[](0);
        IReactor.SwapInput memory swap = _swapInput(vault0, 5 ether, 5 ether);

        IReactor.Order memory order = _order(outputs, 5 ether);
        order.request.deadline = block.timestamp + 1;
        order.swapperSignature = _signRequest(order.request);
        bytes memory protocolSignature = _signOrder(order);

        vm.warp(order.request.deadline + 1);

        vm.expectRevert(IReactor.ExpiredRequest.selector);
        vm.prank(filler);
        executor.fill(order, protocolSignature, swap, abi.encode(calls));

        assertEq(rwa.balanceOf(vault0Account), 0);
    }

    function testFillRevertsIfRequestNonceAlreadyUsed() public {
        outputToken.mint(address(executor), 10 ether);

        IReactor.Output[] memory outputs = new IReactor.Output[](1);
        outputs[0] = IReactor.Output({token: address(outputToken), amount: 5 ether, recipient: swapper});

        IExecutor.Call[] memory calls = new IExecutor.Call[](0);
        IReactor.SwapInput memory swap = _swapInput(vault0, 5 ether, 5 ether);

        IReactor.Order memory order = _order(outputs, 5 ether);
        bytes memory protocolSignature = _signOrder(order);

        vm.prank(filler);
        executor.fill(order, protocolSignature, swap, abi.encode(calls));

        vm.expectRevert(IReactor.NonceUsed.selector);
        vm.prank(filler);
        executor.fill(order, protocolSignature, swap, abi.encode(calls));

        assertEq(IReactor(address(reactor)).isUsedNonce(swapper, order.request.nonce), true);
        assertEq(rwa.balanceOf(vault0Account), 5 ether);
        assertEq(outputToken.balanceOf(swapper), 5 ether);
    }

    function testFillRevertsIfRequestNonceWasInvalidated() public {
        outputToken.mint(address(executor), 5 ether);

        IReactor.Output[] memory outputs = new IReactor.Output[](1);
        outputs[0] = IReactor.Output({token: address(outputToken), amount: 5 ether, recipient: swapper});

        IExecutor.Call[] memory calls = new IExecutor.Call[](0);
        IReactor.SwapInput memory swap = _swapInput(vault0, 5 ether, 5 ether);

        IReactor.Order memory order = _order(outputs, 5 ether);
        bytes memory protocolSignature = _signOrder(order);

        vm.expectEmit(true, false, false, true, address(reactor));
        emit IReactor.InvalidateNonce(swapper, order.request.nonce);

        vm.prank(swapper);
        reactor.invalidateNonce(order.request.nonce);

        assertEq(IReactor(address(reactor)).isUsedNonce(swapper, order.request.nonce), true);
        assertEq(IReactor(address(reactor)).isUsedNonce(filler, order.request.nonce), false);

        vm.expectRevert(IReactor.NonceUsed.selector);
        vm.prank(filler);
        executor.fill(order, protocolSignature, swap, abi.encode(calls));

        assertEq(rwa.balanceOf(vault0Account), 0);
        assertEq(outputToken.balanceOf(swapper), 0);
    }

    function testFillRevertsIfSwapInputsDoNotMatchOrderAmountIn() public {
        IReactor.Output[] memory outputs = new IReactor.Output[](0);
        IExecutor.Call[] memory calls = new IExecutor.Call[](0);
        IReactor.SwapInput[] memory swapInputs = new IReactor.SwapInput[](2);
        swapInputs[0] = _swapInput(vault0, 4 ether, 4 ether);
        swapInputs[1] = _swapInput(vault1, 5 ether, 5 ether);

        IReactor.Order memory order = _order(outputs, 10 ether);
        bytes memory protocolSignature = _signOrder(order);

        vm.expectRevert(IReactor.InvalidAmountIn.selector);
        vm.prank(filler);
        executor.fill(order, protocolSignature, swapInputs, abi.encode(calls));
    }

    function testFillRevertsIfSwapInputTokenDoesNotMatchOrderTokenIn() public {
        MockERC20 otherRwa = new MockERC20("OtherRWA", "ORWA");
        adapter.setAccount(vault0, address(otherRwa), makeAddr("otherAccount"));
        otherRwa.mint(swapper, 5 ether);
        vm.prank(swapper);
        otherRwa.approve(address(reactor), type(uint256).max);

        IReactor.Output[] memory outputs = new IReactor.Output[](0);
        IExecutor.Call[] memory calls = new IExecutor.Call[](0);
        IReactor.SwapInput memory swap = IReactor.SwapInput({
            adapter: address(adapter),
            swap: ILiquidLaneAdapter.Swap({
                recipient: filler, tokenIn: address(otherRwa), amountIn: 5 ether, amountOut: 5 ether
            })
        });
        IReactor.Order memory order = _order(outputs, 5 ether);
        bytes memory protocolSignature = _signOrder(order);

        vm.expectRevert(IReactor.InvalidTokenIn.selector);
        vm.prank(filler);
        executor.fill(order, protocolSignature, swap, abi.encode(calls));
    }

    function testFillRevertsIfSwapAdapterIsNotFactoryEntity() public {
        MockAdapter unregisteredAdapter = new MockAdapter();
        unregisteredAdapter.setAccount(vault0, address(rwa), vault0Account);

        IReactor.Output[] memory outputs = new IReactor.Output[](0);
        IExecutor.Call[] memory calls = new IExecutor.Call[](0);
        IReactor.SwapInput memory swap = _swapInput(address(unregisteredAdapter), vault0, 5 ether, 5 ether);
        IReactor.Order memory order = _order(outputs, 5 ether);
        bytes memory protocolSignature = _signOrder(order);

        vm.expectRevert(IReactor.InvalidAdapter.selector);
        vm.prank(filler);
        executor.fill(order, protocolSignature, swap, abi.encode(calls));

        assertEq(rwa.balanceOf(address(unregisteredAdapter)), 0);
        assertEq(rwa.balanceOf(vault0Account), 0);
    }

    function testFillExecutesDiscountSwapInputsAlongsideDirectSwapInputs() public {
        outputToken.mint(address(executor), 10 ether);

        IReactor.Output[] memory outputs = new IReactor.Output[](1);
        outputs[0] = IReactor.Output({token: address(outputToken), amount: 10 ether, recipient: swapper});

        IExecutor.Call[] memory calls = new IExecutor.Call[](0);
        IReactor.SwapInput[] memory swapInputs = new IReactor.SwapInput[](1);
        swapInputs[0] = _swapInput(vault0, 4 ether, 4 ether);

        IReactor.DiscountSwapInput[] memory discountSwapInputs = new IReactor.DiscountSwapInput[](1);
        discountSwapInputs[0] = _discountSwapInput(address(secondaryAdapter), vault1, 6 ether, 6 ether);

        IReactor.Order memory order = _order(outputs, 10 ether);
        bytes memory protocolSignature = _signOrder(order);

        vm.prank(filler);
        executor.fill(order, protocolSignature, swapInputs, discountSwapInputs, abi.encode(calls));

        assertEq(rwa.balanceOf(vault0Account), 4 ether);
        assertEq(rwa.balanceOf(vault1Account), 6 ether);
        assertEq(outputToken.balanceOf(swapper), 10 ether);
        assertEq(adapter.swapCount(), 1);
        assertEq(adapter.discountSwapCount(), 0);
        assertEq(secondaryAdapter.discountSwapCount(), 1);
        assertEq(rwa.balanceOf(address(adapter)), 0);
        assertEq(rwa.balanceOf(address(secondaryAdapter)), 0);
    }

    function testFillRoutesDiscountSwapInputsToTheirAdapters() public {
        outputToken.mint(address(executor), 10 ether);

        IReactor.Output[] memory outputs = new IReactor.Output[](1);
        outputs[0] = IReactor.Output({token: address(outputToken), amount: 10 ether, recipient: swapper});

        IExecutor.Call[] memory calls = new IExecutor.Call[](0);
        IReactor.SwapInput[] memory swapInputs = new IReactor.SwapInput[](0);
        IReactor.DiscountSwapInput[] memory discountSwapInputs = new IReactor.DiscountSwapInput[](2);
        discountSwapInputs[0] = _discountSwapInput(address(adapter), vault0, 4 ether, 4 ether);
        discountSwapInputs[1] = _discountSwapInput(address(secondaryAdapter), vault1, 6 ether, 6 ether);

        IReactor.Order memory order = _order(outputs, 10 ether);
        bytes memory protocolSignature = _signOrder(order);

        vm.prank(filler);
        executor.fill(order, protocolSignature, swapInputs, discountSwapInputs, abi.encode(calls));

        assertEq(rwa.balanceOf(vault0Account), 4 ether);
        assertEq(rwa.balanceOf(vault1Account), 6 ether);
        assertEq(outputToken.balanceOf(swapper), 10 ether);
        assertEq(adapter.discountSwapCount(), 1);
        assertEq(secondaryAdapter.discountSwapCount(), 1);
    }

    function testFillRevertsIfDiscountSwapAdapterIsNotFactoryEntity() public {
        MockAdapter unregisteredAdapter = new MockAdapter();
        unregisteredAdapter.setAccount(vault0, address(rwa), vault0Account);

        IReactor.Output[] memory outputs = new IReactor.Output[](0);
        IExecutor.Call[] memory calls = new IExecutor.Call[](0);
        IReactor.SwapInput[] memory swapInputs = new IReactor.SwapInput[](0);
        IReactor.DiscountSwapInput[] memory discountSwapInputs = new IReactor.DiscountSwapInput[](1);
        discountSwapInputs[0] = _discountSwapInput(address(unregisteredAdapter), vault0, 5 ether, 5 ether);
        IReactor.Order memory order = _order(outputs, 5 ether);
        bytes memory protocolSignature = _signOrder(order);

        vm.expectRevert(IReactor.InvalidAdapter.selector);
        vm.prank(filler);
        executor.fill(order, protocolSignature, swapInputs, discountSwapInputs, abi.encode(calls));

        assertEq(rwa.balanceOf(address(unregisteredAdapter)), 0);
        assertEq(rwa.balanceOf(vault0Account), 0);
    }

    function testFillRevertsIfSwapAmountInDoesNotMatchOrderAmountIn() public {
        IReactor.Output[] memory outputs = new IReactor.Output[](0);
        IExecutor.Call[] memory calls = new IExecutor.Call[](0);
        IReactor.SwapInput memory swap = IReactor.SwapInput({
            adapter: address(adapter),
            swap: ILiquidLaneAdapter.Swap({
                recipient: filler, tokenIn: address(rwa), amountIn: 4 ether, amountOut: 5 ether
            })
        });

        IReactor.Order memory order = _order(outputs, 5 ether);
        bytes memory protocolSignature = _signOrder(order);

        vm.expectRevert(IReactor.InvalidAmountIn.selector);
        vm.prank(filler);
        executor.fill(order, protocolSignature, swap, abi.encode(calls));
    }

    function testFillRevertsIfAllLegInputsDoNotMatchOrderAmountIn() public {
        IReactor.Output[] memory outputs = new IReactor.Output[](0);
        IExecutor.Call[] memory calls = new IExecutor.Call[](0);
        IReactor.SwapInput[] memory swapInputs = new IReactor.SwapInput[](1);
        swapInputs[0] = _swapInput(vault0, 4 ether, 4 ether);

        IReactor.DiscountSwapInput[] memory discountSwapInputs = new IReactor.DiscountSwapInput[](1);
        discountSwapInputs[0] = _discountSwapInput(vault1, 5 ether, 5 ether);

        IReactor.Order memory order = _order(outputs, 10 ether);
        bytes memory protocolSignature = _signOrder(order);

        vm.expectRevert(IReactor.InvalidAmountIn.selector);
        vm.prank(filler);
        executor.fill(order, protocolSignature, swapInputs, discountSwapInputs, abi.encode(calls));
    }

    function testFuzzFillRevertsIfSingleSwapAmountDoesNotMatchOrderAmount(uint96 orderAmount, uint96 swapAmount)
        public
    {
        orderAmount = uint96(bound(orderAmount, 1, 50 ether));
        swapAmount = uint96(bound(swapAmount, 0, 50 ether));
        vm.assume(orderAmount != swapAmount);

        IReactor.Output[] memory outputs = new IReactor.Output[](0);
        IExecutor.Call[] memory calls = new IExecutor.Call[](0);
        IReactor.SwapInput memory swap = _swapInput(vault0, swapAmount, swapAmount);

        IReactor.Order memory order = _order(outputs, orderAmount);
        bytes memory protocolSignature = _signOrder(order);

        vm.expectRevert(IReactor.InvalidAmountIn.selector);
        vm.prank(filler);
        executor.fill(order, protocolSignature, swap, abi.encode(calls));
    }

    function testFillRevertsAndRollsBackIfExecutorDataIsMalformed() public {
        outputToken.mint(address(executor), 5 ether);

        IReactor.Output[] memory outputs = new IReactor.Output[](1);
        outputs[0] = IReactor.Output({token: address(outputToken), amount: 5 ether, recipient: swapper});
        IReactor.SwapInput memory swap = _swapInput(vault0, 5 ether, 5 ether);

        IReactor.Order memory order = _order(outputs, 5 ether);
        bytes memory protocolSignature = _signOrder(order);

        vm.expectRevert();
        vm.prank(filler);
        executor.fill(order, protocolSignature, swap, hex"01");

        assertEq(rwa.balanceOf(vault0Account), 0);
        assertEq(rwa.balanceOf(address(adapter)), 0);
        assertEq(outputToken.balanceOf(swapper), 0);
    }

    function testFillRevertsAndRollsBackIfExecutorCallFails() public {
        outputToken.mint(address(executor), 5 ether);

        IReactor.Output[] memory outputs = new IReactor.Output[](1);
        outputs[0] = IReactor.Output({token: address(outputToken), amount: 5 ether, recipient: swapper});

        IExecutor.Call[] memory calls = new IExecutor.Call[](1);
        calls[0] = IExecutor.Call({
            target: address(callTarget), value: 0, data: abi.encodeWithSelector(MockCallTarget.revertAlways.selector)
        });
        IReactor.SwapInput memory swap = _swapInput(vault0, 5 ether, 5 ether);

        IReactor.Order memory order = _order(outputs, 5 ether);
        bytes memory protocolSignature = _signOrder(order);

        vm.expectRevert();
        vm.prank(filler);
        executor.fill(order, protocolSignature, swap, abi.encode(calls));

        assertEq(rwa.balanceOf(vault0Account), 0);
        assertEq(rwa.balanceOf(address(adapter)), 0);
        assertEq(outputToken.balanceOf(swapper), 0);
        assertEq(callTarget.calls(), 0);
    }

    function testFillRevertsAndRollsBackIfAdapterFails() public {
        outputToken.mint(address(executor), 5 ether);

        IReactor.Output[] memory outputs = new IReactor.Output[](1);
        outputs[0] = IReactor.Output({token: address(outputToken), amount: 5 ether, recipient: swapper});

        IExecutor.Call[] memory calls = new IExecutor.Call[](0);
        MockAdapter failingAdapter = new MockAdapter();
        adapterFactory.setEntity(address(failingAdapter), true);
        IReactor.SwapInput memory swap = _swapInput(address(failingAdapter), vault0, 5 ether, 5 ether);

        IReactor.Order memory order = _order(outputs, 5 ether);
        bytes memory protocolSignature = _signOrder(order);

        vm.expectRevert(bytes("missing rwa"));
        vm.prank(filler);
        executor.fill(order, protocolSignature, swap, abi.encode(calls));

        assertEq(rwa.balanceOf(vault0Account), 0);
        assertEq(rwa.balanceOf(address(adapter)), 0);
        assertEq(rwa.balanceOf(address(failingAdapter)), 0);
        assertEq(outputToken.balanceOf(swapper), 0);
    }

    function testExecuteRevertsWhenCallerIsNotReactor() public {
        IReactor.Output[] memory outputs = new IReactor.Output[](0);
        IReactor.Order memory order = _order(outputs, 0);

        vm.expectRevert(IExecutor.NotReactor.selector);
        executor.execute(
            order, new IReactor.SwapInput[](0), new IReactor.DiscountSwapInput[](0), abi.encode(new IExecutor.Call[](0))
        );
    }

    function testExecuteRunsExecutorCalls() public {
        IExecutor.Call[] memory calls = new IExecutor.Call[](1);
        calls[0] = IExecutor.Call({
            target: address(callTarget), value: 0, data: abi.encodeWithSelector(MockCallTarget.record.selector, 7)
        });

        vm.prank(address(reactor));
        executor.execute(
            _order(new IReactor.Output[](0), 0),
            new IReactor.SwapInput[](0),
            new IReactor.DiscountSwapInput[](0),
            abi.encode(calls)
        );

        assertEq(callTarget.lastValue(), 7);
        assertEq(callTarget.calls(), 1);
    }

    function _callers(address caller) internal pure returns (address[] memory callers_) {
        callers_ = new address[](1);
        callers_[0] = caller;
    }

    function _order(IReactor.Output[] memory outputs) internal view returns (IReactor.Order memory) {
        return _order(outputs, 10 ether, address(executor));
    }

    function _order(IReactor.Output[] memory outputs, uint256 amountIn) internal view returns (IReactor.Order memory) {
        return _order(outputs, amountIn, address(executor));
    }

    function _order(IReactor.Output[] memory outputs, uint256 amountIn, address filler_)
        internal
        view
        returns (IReactor.Order memory)
    {
        return _order(outputs, amountIn, filler_, reactor);
    }

    function _order(IReactor.Output[] memory outputs, uint256 amountIn, address filler_, Reactor reactor_)
        internal
        view
        returns (IReactor.Order memory)
    {
        IReactor.Request memory request = IReactor.Request({
            tokenIn: address(rwa),
            amountIn: amountIn,
            outputs: outputs,
            deadline: block.timestamp + 1 days,
            nonce: 1,
            protocol: protocol
        });
        return IReactor.Order({
            request: request,
            swapperSignature: _signRequest(request, reactor_),
            swapper: swapper,
            filler: filler_,
            outputs: _copyOutputs(outputs)
        });
    }

    function _signOrder(IReactor.Order memory order) internal view returns (bytes memory) {
        return _signOrder(order, reactor, PROTOCOL_PRIVATE_KEY);
    }

    function _signOrder(IReactor.Order memory order, Reactor reactor_) internal view returns (bytes memory) {
        return _signOrder(order, reactor_, PROTOCOL_PRIVATE_KEY);
    }

    function _signOrder(IReactor.Order memory order, Reactor reactor_, uint256 privateKey)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = keccak256(
            abi.encodePacked(
                hex"1901",
                keccak256(
                    abi.encode(
                        DOMAIN_TYPEHASH,
                        keccak256(bytes("Reactor")),
                        keccak256(bytes("1")),
                        block.chainid,
                        address(reactor_)
                    )
                ),
                _hashOrder(order)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signRequest(IReactor.Request memory request) internal view returns (bytes memory) {
        return _signRequest(request, reactor, SWAPPER_PRIVATE_KEY);
    }

    function _signRequest(IReactor.Request memory request, Reactor reactor_) internal view returns (bytes memory) {
        return _signRequest(request, reactor_, SWAPPER_PRIVATE_KEY);
    }

    function _signRequest(IReactor.Request memory request, Reactor reactor_, uint256 privateKey)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = keccak256(
            abi.encodePacked(
                hex"1901",
                keccak256(
                    abi.encode(
                        DOMAIN_TYPEHASH,
                        keccak256(bytes("Reactor")),
                        keccak256(bytes("1")),
                        block.chainid,
                        address(reactor_)
                    )
                ),
                _hashRequest(request)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _hashOrder(IReactor.Order memory order) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                _hashRequest(order.request),
                keccak256(order.swapperSignature),
                order.swapper,
                order.filler,
                _hashOutputs(order.outputs)
            )
        );
    }

    function _hashRequest(IReactor.Request memory request) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                REQUEST_TYPEHASH,
                request.tokenIn,
                request.amountIn,
                _hashOutputs(request.outputs),
                request.deadline,
                request.nonce,
                request.protocol
            )
        );
    }

    function _hashOutputs(IReactor.Output[] memory outputs) internal pure returns (bytes32 outputsHash) {
        bytes32[] memory outputHashes = new bytes32[](outputs.length);
        for (uint256 i; i < outputs.length; ++i) {
            outputHashes[i] = keccak256(abi.encode(OUTPUT_TYPEHASH, outputs[i]));
        }
        outputsHash = keccak256(abi.encodePacked(outputHashes));
    }

    function _copyOutputs(IReactor.Output[] memory outputs)
        internal
        pure
        returns (IReactor.Output[] memory outputCopies)
    {
        outputCopies = new IReactor.Output[](outputs.length);
        for (uint256 i; i < outputs.length; ++i) {
            outputCopies[i] = outputs[i];
        }
    }

    function _swap(address, uint256 amountIn, uint256 amountOut)
        internal
        view
        returns (ILiquidLaneAdapter.Swap memory)
    {
        return ILiquidLaneAdapter.Swap({
            recipient: filler, tokenIn: address(rwa), amountIn: amountIn, amountOut: amountOut
        });
    }

    function _swapInput(address vault, uint256 amountIn, uint256 amountOut)
        internal
        view
        returns (IReactor.SwapInput memory)
    {
        return _swapInput(address(adapter), vault, amountIn, amountOut);
    }

    function _swapInput(address adapter_, address vault, uint256 amountIn, uint256 amountOut)
        internal
        view
        returns (IReactor.SwapInput memory)
    {
        return IReactor.SwapInput({adapter: adapter_, swap: _swap(vault, amountIn, amountOut)});
    }

    function _discountSwapInput(address vault, uint256 amountIn, uint256 amountOut)
        internal
        view
        returns (IReactor.DiscountSwapInput memory)
    {
        return _discountSwapInput(address(adapter), vault, amountIn, amountOut);
    }

    function _discountSwapInput(address adapter_, address, uint256 amountIn, uint256)
        internal
        view
        returns (IReactor.DiscountSwapInput memory)
    {
        return IReactor.DiscountSwapInput({
            adapter: adapter_,
            discountSwap: ILiquidLaneAdapter.DiscountSwap({
                discount: ILiquidLaneAdapter.Discount({
                    tokenToRedeem: address(rwa),
                    discount: 50_000,
                    signer: protocol,
                    protocol: protocol,
                    nonce: 1,
                    deadline: uint48(block.timestamp + 1 days)
                }),
                signerSignature: hex"1234",
                protocolDeadline: uint48(block.timestamp + 90)
            }),
            protocolSignature: hex"5678",
            recipient: filler,
            amountIn: amountIn
        });
    }
}

contract MockAdapterFactory {
    mapping(address adapter => bool status) public isEntity;

    function setEntity(address adapter, bool status) external {
        isEntity[adapter] = status;
    }
}

contract MockAdapter is ILiquidLaneAdapter {
    mapping(address token => address account) internal _accounts;
    uint256 public swapCount;
    uint256 public signedSwapCount;
    uint256 public discountSwapCount;

    function setAccount(address vault, address token, address account) public {
        vault;
        _accounts[token] = account;
    }

    function getAccount(address vault, address token) public view returns (address) {
        vault;
        return _accounts[token];
    }

    function swap(ILiquidLaneAdapter.Swap calldata swap) public {
        address account = _accounts[swap.tokenIn];
        uint256 balance = ERC20(swap.tokenIn).balanceOf(address(this));
        require(account != address(0) && balance >= swap.amountIn, "missing rwa");
        ERC20(swap.tokenIn).transfer(account, swap.amountIn);
        ++swapCount;
    }

    function swap(ILiquidLaneAdapter.SignedSwap calldata signedSwap, bytes calldata) public {
        address account = _accounts[signedSwap.tokenIn];
        uint256 balance = ERC20(signedSwap.tokenIn).balanceOf(address(this));
        require(account != address(0) && balance >= signedSwap.amountIn, "missing rwa");
        ERC20(signedSwap.tokenIn).transfer(account, signedSwap.amountIn);
        ++signedSwapCount;
    }

    function swap(
        ILiquidLaneAdapter.DiscountSwap calldata discountSwap,
        bytes calldata,
        address recipient,
        uint256 amountIn
    ) public returns (uint256 amountOut) {
        address account = _accounts[discountSwap.discount.tokenToRedeem];
        uint256 balance = ERC20(discountSwap.discount.tokenToRedeem).balanceOf(address(this));
        require(account != address(0) && balance >= amountIn, "missing rwa");
        ERC20(discountSwap.discount.tokenToRedeem).transfer(account, amountIn);
        if (recipient != address(0)) {
            recipient.code.length;
        }
        ++discountSwapCount;
        return amountIn;
    }
}

contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract MockApprovalERC20 is MockERC20 {
    uint256 public approveCalls;

    constructor(string memory name_, string memory symbol_) MockERC20(name_, symbol_) {}

    function approve(address spender, uint256 amount) public override returns (bool) {
        ++approveCalls;
        return super.approve(spender, amount);
    }
}

contract MockCallTarget {
    uint256 public calls;
    uint256 public lastValue;

    function record(uint256 value) public payable {
        ++calls;
        lastValue = value;
    }

    function revertAlways() public pure {
        revert("call failed");
    }
}

interface IReactorFullFill {
    function fill(
        IReactor.Order calldata order,
        bytes calldata protocolSignature,
        IReactor.SwapInput[] calldata swapInputs,
        IReactor.DiscountSwapInput[] calldata discountSwapInputs,
        bytes calldata executorData
    ) external;
}

contract ReentrantNativeRecipient is IExecutor {
    Reactor internal immutable _reactor;
    bytes internal _reentryCalldata;
    bool internal _entered;

    constructor(Reactor reactor_) {
        _reactor = reactor_;
    }

    function setReentry(bytes memory reentryCalldata) public {
        _reentryCalldata = reentryCalldata;
    }

    function execute(
        IReactor.Order calldata,
        IReactor.SwapInput[] calldata,
        IReactor.DiscountSwapInput[] calldata,
        bytes calldata
    ) public {}

    function fill(IReactor.Order calldata, bytes calldata, IReactor.SwapInput calldata, bytes calldata) external {}

    function fill(IReactor.Order calldata, bytes calldata, IReactor.SwapInput[] calldata, bytes calldata) external {}

    function fill(
        IReactor.Order calldata,
        bytes calldata,
        IReactor.SwapInput[] calldata,
        IReactor.DiscountSwapInput[] calldata,
        bytes calldata
    ) external {}

    function setCallers(address[] calldata) external {}

    function callers(uint256) external pure returns (address) {
        return address(0);
    }

    receive() external payable {
        if (_entered) {
            return;
        }
        _entered = true;

        (bool success, bytes memory returndata) = address(_reactor).call(_reentryCalldata);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returndata, 0x20), mload(returndata))
            }
        }
    }
}
