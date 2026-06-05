// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.28;

import {Executor} from "../src/Executor.sol";
import {Reactor} from "../src/Reactor.sol";
import {CALLER_ROLE, IExecutor} from "../src/interfaces/IExecutor.sol";
import {IInstantRedemptionAdapter} from "../src/interfaces/IInstantRedemptionAdapter.sol";
import {IPermit2} from "../src/interfaces/IPermit2.sol";
import {
    IReactor,
    NATIVE,
    ORDER_TYPEHASH,
    OUTPUT_TYPEHASH,
    REQUEST_TYPEHASH,
    REQUEST_WITNESS_TYPE_STRING
} from "../src/interfaces/IReactor.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {SafeTransferLib as SafeERC20} from "@solady/src/utils/SafeTransferLib.sol";

import {Test} from "forge-std/Test.sol";

contract ReactorTest is Test {
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    uint256 internal constant NEW_PROTOCOL_PRIVATE_KEY = 0xB0B;
    uint256 internal constant PROTOCOL_PRIVATE_KEY = 0xA11CE;

    address internal filler = makeAddr("filler");
    address internal newProtocol = vm.addr(NEW_PROTOCOL_PRIVATE_KEY);
    address internal protocol = vm.addr(PROTOCOL_PRIVATE_KEY);
    address internal referrer = makeAddr("referrer");
    address internal swapper = makeAddr("swapper");
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
    MockPermit2 internal permit2;
    Executor internal executor;
    Reactor internal reactor;

    function setUp() public {
        adapter = new MockAdapter();
        secondaryAdapter = new MockAdapter();
        adapterFactory = new MockAdapterFactory();
        adapterFactory.setEntity(address(adapter), true);
        adapterFactory.setEntity(address(secondaryAdapter), true);
        callTarget = new MockCallTarget();
        permit2 = new MockPermit2();
        reactor = new Reactor(address(adapterFactory), address(permit2));
        executor = new Executor(address(reactor), address(this));
        executor.grantRole(CALLER_ROLE, filler);

        rwa = new MockERC20("RWA", "RWA");
        outputToken = new MockERC20("USD", "USD");

        adapter.setAccount(vault0, address(rwa), vault0Account);
        adapter.setAccount(vault1, address(rwa), vault1Account);
        secondaryAdapter.setAccount(vault0, address(rwa), vault0Account);
        secondaryAdapter.setAccount(vault1, address(rwa), vault1Account);

        rwa.mint(swapper, 100 ether);
        vm.prank(swapper);
        rwa.approve(address(permit2), type(uint256).max);
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
        swapInputs[1] = _swapInput(vault1, 6 ether, 6 ether);

        IReactor.Order memory order = _order(outputs, 10 ether);
        bytes memory protocolSignature = _signOrder(order);

        vm.prank(filler);
        executor.fill(order, protocolSignature, swapInputs, abi.encode(calls));

        assertEq(rwa.balanceOf(vault0Account), 4 ether);
        assertEq(rwa.balanceOf(vault1Account), 6 ether);
        assertEq(outputToken.balanceOf(swapper), 10 ether);
        assertEq(adapter.swapCount(), 2);
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
    }

    function testFillRevertsIfOutputsAreNotSatisfied() public {
        outputToken.mint(address(executor), 4 ether);

        IReactor.Output[] memory outputs = new IReactor.Output[](1);
        outputs[0] = IReactor.Output({token: address(outputToken), amount: 5 ether, recipient: swapper});

        IExecutor.Call[] memory calls = new IExecutor.Call[](0);
        IReactor.SwapInput memory swap = _swapInput(vault0, 5 ether, 5 ether);

        IReactor.Order memory order = _order(outputs, 5 ether);
        bytes memory protocolSignature = _signOrder(order);

        vm.expectRevert(SafeERC20.TransferFromFailed.selector);
        vm.prank(filler);
        executor.fill(order, protocolSignature, swap, abi.encode(calls));

        assertEq(rwa.balanceOf(vault0Account), 0);
        assertEq(outputToken.balanceOf(swapper), 0);
    }

    function testExecutorRequiresCallerRole() public {
        Reactor customReactor = new Reactor(address(adapterFactory), address(permit2));
        Executor lockedExecutor = new Executor(address(customReactor), address(this));

        outputToken.mint(address(lockedExecutor), 5 ether);

        IReactor.Output[] memory outputs = new IReactor.Output[](1);
        outputs[0] = IReactor.Output({token: address(outputToken), amount: 5 ether, recipient: swapper});

        IExecutor.Call[] memory calls = new IExecutor.Call[](0);
        IReactor.SwapInput memory swap = _swapInput(vault0, 5 ether, 5 ether);

        IReactor.Order memory order = _order(outputs, 5 ether, address(lockedExecutor));
        bytes memory protocolSignature = _signOrder(order, customReactor);

        vm.expectRevert(IExecutor.NotCaller.selector);
        vm.prank(filler);
        lockedExecutor.fill(order, protocolSignature, swap, abi.encode(calls));

        lockedExecutor.grantRole(CALLER_ROLE, filler);

        vm.prank(filler);
        lockedExecutor.fill(order, protocolSignature, swap, abi.encode(calls));

        assertEq(outputToken.balanceOf(swapper), 5 ether);
        assertEq(rwa.balanceOf(vault0Account), 5 ether);
        assertEq(adapter.swapCount(), 1);
        assertEq(adapter.signedSwapCount(), 0);
    }

    function testFillRevertsIfExecutorDoesNotMatchOrderFiller() public {
        Executor otherExecutor = new Executor(address(reactor), address(this));

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

        vm.prank(filler);
        executor.fill(order, protocolSignature, swap, abi.encode(calls));

        assertEq(approvalToken.allowance(address(executor), address(reactor)), type(uint256).max);
        assertEq(approvalToken.approveCalls(), 1);
        assertEq(approvalToken.balanceOf(swapper), 10 ether);
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

        executor.fill(order, _signOrder(order, reactor, NEW_PROTOCOL_PRIVATE_KEY), swap, abi.encode(calls));
        vm.stopPrank();

        assertEq(outputToken.balanceOf(swapper), 5 ether);
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

    function testRequestWitnessTypeStringMatchesPermit2CanonicalOrder() public pure {
        assertEq(
            REQUEST_WITNESS_TYPE_STRING,
            "Request witness)Output(address token,uint256 amount,address recipient)"
            "Request(address tokenIn,uint256 amountIn,Output[] outputs,uint256 deadline,uint256 nonce,address protocol)"
            "TokenPermissions(address token,uint256 amount)"
        );
    }

    function testFillRevertsIfSwapInputTokenDoesNotMatchOrderTokenIn() public {
        MockERC20 otherRwa = new MockERC20("OtherRWA", "ORWA");
        adapter.setAccount(vault0, address(otherRwa), makeAddr("otherAccount"));
        otherRwa.mint(swapper, 5 ether);
        vm.prank(swapper);
        otherRwa.approve(address(permit2), type(uint256).max);

        IReactor.Output[] memory outputs = new IReactor.Output[](0);
        IExecutor.Call[] memory calls = new IExecutor.Call[](0);
        IReactor.SwapInput memory swap = IReactor.SwapInput({
            adapter: address(adapter),
            swap: IInstantRedemptionAdapter.Swap({
                recipient: filler, vault: vault0, tokenIn: address(otherRwa), amountIn: 5 ether, amountOut: 5 ether
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
        discountSwapInputs[0] = _discountSwapInput(vault1, 6 ether, 6 ether);

        IReactor.Order memory order = _order(outputs, 10 ether);
        bytes memory protocolSignature = _signOrder(order);

        vm.prank(filler);
        executor.fill(order, protocolSignature, swapInputs, discountSwapInputs, abi.encode(calls));

        assertEq(rwa.balanceOf(vault0Account), 4 ether);
        assertEq(rwa.balanceOf(vault1Account), 6 ether);
        assertEq(outputToken.balanceOf(swapper), 10 ether);
        assertEq(adapter.swapCount(), 1);
        assertEq(adapter.discountSwapCount(), 1);
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
            swap: IInstantRedemptionAdapter.Swap({
                recipient: filler, vault: vault0, tokenIn: address(rwa), amountIn: 4 ether, amountOut: 5 ether
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
        return IReactor.Order({
            request: IReactor.Request({
                tokenIn: address(rwa),
                amountIn: amountIn,
                outputs: outputs,
                deadline: block.timestamp + 1 days,
                nonce: 1,
                protocol: protocol
            }),
            swapperSignature: hex"1234",
            swapper: swapper,
            filler: filler_
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

    function _hashOrder(IReactor.Order memory order) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                _hashRequest(order.request),
                keccak256(order.swapperSignature),
                order.swapper,
                order.filler
            )
        );
    }

    function _hashRequest(IReactor.Request memory request) internal pure returns (bytes32) {
        bytes32[] memory outputHashes = new bytes32[](request.outputs.length);
        for (uint256 i; i < request.outputs.length; ++i) {
            outputHashes[i] = keccak256(abi.encode(OUTPUT_TYPEHASH, request.outputs[i]));
        }

        return keccak256(
            abi.encode(
                REQUEST_TYPEHASH,
                request.tokenIn,
                request.amountIn,
                keccak256(abi.encodePacked(outputHashes)),
                request.deadline,
                request.nonce,
                request.protocol
            )
        );
    }

    function _swap(address vault, uint256 amountIn, uint256 amountOut)
        internal
        view
        returns (IInstantRedemptionAdapter.Swap memory)
    {
        return IInstantRedemptionAdapter.Swap({
            recipient: filler, vault: vault, tokenIn: address(rwa), amountIn: amountIn, amountOut: amountOut
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

    function _discountSwapInput(address adapter_, address vault, uint256 amountIn, uint256 amountOut)
        internal
        view
        returns (IReactor.DiscountSwapInput memory)
    {
        return IReactor.DiscountSwapInput({
            adapter: adapter_,
            discountSwap: IInstantRedemptionAdapter.DiscountSwap({
                discount: IInstantRedemptionAdapter.Discount({
                    vault: vault,
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
            amountIn: amountIn,
            amountOut: amountOut
        });
    }
}

contract MockAdapterFactory {
    mapping(address adapter => bool status) public isEntity;

    function setEntity(address adapter, bool status) external {
        isEntity[adapter] = status;
    }
}

contract MockAdapter is IInstantRedemptionAdapter {
    mapping(address vault => mapping(address token => address account)) internal _accounts;
    uint256 public swapCount;
    uint256 public signedSwapCount;
    uint256 public discountSwapCount;

    function setAccount(address vault, address token, address account) external {
        _accounts[vault][token] = account;
    }

    function getAccount(address vault, address token) external view returns (address) {
        return _accounts[vault][token];
    }

    function swap(IInstantRedemptionAdapter.Swap calldata swap) external {
        address account = _accounts[swap.vault][swap.tokenIn];
        uint256 balance = ERC20(swap.tokenIn).balanceOf(address(this));
        require(account != address(0) && balance >= swap.amountIn, "missing rwa");
        ERC20(swap.tokenIn).transfer(account, swap.amountIn);
        ++swapCount;
    }

    function swap(IInstantRedemptionAdapter.SignedSwap calldata signedSwap, bytes calldata) external {
        address account = _accounts[signedSwap.vault][signedSwap.tokenIn];
        uint256 balance = ERC20(signedSwap.tokenIn).balanceOf(address(this));
        require(account != address(0) && balance >= signedSwap.amountIn, "missing rwa");
        ERC20(signedSwap.tokenIn).transfer(account, signedSwap.amountIn);
        ++signedSwapCount;
    }

    function swap(
        IInstantRedemptionAdapter.DiscountSwap calldata discountSwap,
        bytes calldata,
        address recipient,
        uint256 amountIn,
        uint256
    ) external {
        address account = _accounts[discountSwap.discount.vault][discountSwap.discount.tokenToRedeem];
        uint256 balance = ERC20(discountSwap.discount.tokenToRedeem).balanceOf(address(this));
        require(account != address(0) && balance >= amountIn, "missing rwa");
        ERC20(discountSwap.discount.tokenToRedeem).transfer(account, amountIn);
        if (recipient != address(0)) {
            recipient.code.length;
        }
        ++discountSwapCount;
    }
}

contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
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

contract MockPermit2 is IPermit2 {
    function permitWitnessTransferFrom(
        PermitTransferFrom memory permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes32,
        string calldata,
        bytes calldata
    ) external {
        require(permit.permitted.amount == transferDetails.requestedAmount, "invalid amount");
        ERC20(permit.permitted.token).transferFrom(owner, transferDetails.to, transferDetails.requestedAmount);
    }
}

contract MockCallTarget {
    uint256 public calls;
    uint256 public lastValue;

    function record(uint256 value) external payable {
        ++calls;
        lastValue = value;
    }
}
