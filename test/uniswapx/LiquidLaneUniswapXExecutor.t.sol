// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.28;

import {ILiquidLaneAdapter} from "../../src/interfaces/ILiquidLaneAdapter.sol";
import {LiquidLaneUniswapXExecutor} from "../../src/uniswapx/LiquidLaneUniswapXExecutor.sol";
import {ILiquidLaneUniswapXExecutor} from "../../src/uniswapx/interfaces/ILiquidLaneUniswapXExecutor.sol";
import {
    IUniswapXReactor,
    IUniswapXReactorCallback,
    UniswapXInputToken,
    UniswapXOrderInfo,
    UniswapXOutputToken,
    UniswapXResolvedOrder,
    UniswapXSignedOrder
} from "../../src/uniswapx/interfaces/IUniswapXReactor.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Test} from "forge-std/Test.sol";

contract LiquidLaneUniswapXExecutorTest is Test {
    using Address for address payable;

    address internal caller = makeAddr("caller");
    address internal owner = makeAddr("owner");
    address internal proxyAdminOwner = makeAddr("proxyAdminOwner");
    address internal recipient = makeAddr("recipient");

    TestToken internal inputToken;
    TestToken internal outputToken;
    MockUniswapXAdapter internal adapter;
    MockUniswapXReactor internal reactor;
    LiquidLaneUniswapXExecutor internal implementation;
    LiquidLaneUniswapXExecutor internal executor;

    function setUp() public {
        inputToken = new TestToken("Input", "IN");
        outputToken = new TestToken("Output", "OUT");
        adapter = new MockUniswapXAdapter(address(outputToken));
        reactor = new MockUniswapXReactor();

        implementation = new LiquidLaneUniswapXExecutor(address(reactor));
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            proxyAdminOwner,
            abi.encodeCall(LiquidLaneUniswapXExecutor.initialize, (owner, _callers(caller)))
        );
        executor = LiquidLaneUniswapXExecutor(payable(address(proxy)));

        inputToken.mint(address(reactor), 10 ether);
        outputToken.mint(address(adapter), 100 ether);
        reactor.setOrder(_resolvedOrder(10 ether, _erc20Outputs(address(outputToken), 9 ether, recipient)));
    }

    function testInitializeSetsOwnerAndCallers() public view {
        assertEq(executor.owner(), owner);
        assertEq(executor.callers(0), caller);
    }

    function testInitializeCannotBeCalledTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        executor.initialize(makeAddr("intruder"), _callers(makeAddr("intruderCaller")));
    }

    function testImplementationInitializerIsDisabled() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(owner, _callers(caller));
    }

    function testExecuteRejectsOwnerWhenOwnerIsNotCaller() public {
        vm.prank(owner);
        vm.expectRevert(ILiquidLaneUniswapXExecutor.NotCaller.selector);
        executor.execute(_signedOrder(), _emptyFillCall());
    }

    function testSetCallersAllowsNewCallerAndRevokesOldCaller() public {
        address newCaller = makeAddr("newCaller");
        reactor.setOrder(_resolvedOrder(0, _emptyOutputs()));
        vm.prank(owner);
        executor.setCallers(_callers(newCaller));

        vm.prank(caller);
        vm.expectRevert(ILiquidLaneUniswapXExecutor.NotCaller.selector);
        executor.execute(_signedOrder(), _emptyFillCall());

        vm.prank(newCaller);
        executor.execute(_signedOrder(), _emptyFillCall());
    }

    function testSetCallersRejectsNonOwner() public {
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        executor.setCallers(_callers(caller));
    }

    function testReactorCallbackRejectsNonReactor() public {
        UniswapXResolvedOrder[] memory orders =
            _resolvedOrders(_resolvedOrder(10 ether, _erc20Outputs(address(outputToken), 9 ether, recipient)));
        vm.expectRevert(ILiquidLaneUniswapXExecutor.NotReactor.selector);
        executor.reactorCallback(orders, abi.encode(_emptyFillCall()));
    }

    function testReactorCallbackRejectsMalformedData() public {
        UniswapXResolvedOrder[] memory orders =
            _resolvedOrders(_resolvedOrder(10 ether, _erc20Outputs(address(outputToken), 9 ether, recipient)));
        vm.prank(address(reactor));
        vm.expectRevert();
        executor.reactorCallback(orders, hex"01");
    }

    function testExecuteRoutesDirectFillAndKeepsInputAndOutputSurplus() public {
        adapter.setDirectOutput(10 ether);
        ILiquidLaneUniswapXExecutor.FillRoute[] memory routes = new ILiquidLaneUniswapXExecutor.FillRoute[](1);
        routes[0] = _directRoute(address(adapter), 9 ether, 10 ether);
        reactor.setOrder(_resolvedOrder(10 ether, _erc20Outputs(address(outputToken), 9 ether, recipient)));

        vm.prank(caller);
        executor.execute(_signedOrder(), _fillCall(routes, new ILiquidLaneUniswapXExecutor.DiscountRoute[](0)));

        assertEq(inputToken.balanceOf(address(executor)), 1 ether);
        assertEq(outputToken.balanceOf(address(executor)), 1 ether);
        assertEq(outputToken.allowance(address(executor), address(reactor)), type(uint256).max);
    }

    function testExecuteRoutesMultipleDirectFillsAndSettlesMixedErc20Outputs() public {
        TestToken secondOutput = new TestToken("Second Output", "OUT2");
        MockUniswapXAdapter secondAdapter = new MockUniswapXAdapter(address(secondOutput));
        address secondRecipient = makeAddr("secondRecipient");
        adapter.setDirectOutput(4 ether);
        secondAdapter.setDirectOutput(6 ether);
        outputToken.mint(address(adapter), 4 ether);
        secondOutput.mint(address(secondAdapter), 6 ether);

        UniswapXOutputToken[] memory outputs = new UniswapXOutputToken[](2);
        outputs[0] = UniswapXOutputToken({token: address(outputToken), amount: 4 ether, recipient: recipient});
        outputs[1] = UniswapXOutputToken({token: address(secondOutput), amount: 5 ether, recipient: secondRecipient});
        reactor.setOrder(_resolvedOrder(10 ether, outputs));

        ILiquidLaneUniswapXExecutor.FillRoute[] memory routes = new ILiquidLaneUniswapXExecutor.FillRoute[](2);
        routes[0] = _directRoute(address(adapter), 4 ether, 4 ether);
        routes[1] = _directRoute(address(secondAdapter), 6 ether, 6 ether);
        vm.prank(caller);
        executor.execute(_signedOrder(), _fillCall(routes, new ILiquidLaneUniswapXExecutor.DiscountRoute[](0)));

        assertEq(outputToken.balanceOf(recipient), 4 ether);
        assertEq(secondOutput.balanceOf(secondRecipient), 5 ether);
        assertEq(outputToken.balanceOf(address(executor)), 0);
        assertEq(secondOutput.balanceOf(address(executor)), 1 ether);
        assertEq(outputToken.allowance(address(executor), address(reactor)), type(uint256).max);
        assertEq(secondOutput.allowance(address(executor), address(reactor)), type(uint256).max);
    }

    function testExecuteRoutesDiscountFill() public {
        adapter.setDiscountOutput(9 ether);
        ILiquidLaneUniswapXExecutor.DiscountRoute[] memory discountRoutes =
            new ILiquidLaneUniswapXExecutor.DiscountRoute[](1);
        discountRoutes[0] = _discountRoute(address(adapter), 10 ether);

        vm.prank(caller);
        executor.execute(_signedOrder(), _fillCall(new ILiquidLaneUniswapXExecutor.FillRoute[](0), discountRoutes));

        assertEq(adapter.discountCalls(), 1);
        assertEq(inputToken.balanceOf(address(adapter)), 10 ether);
        assertEq(outputToken.balanceOf(recipient), 9 ether);
    }

    function testExecuteRoutesDirectAndDiscountFillsTogether() public {
        MockUniswapXAdapter discountAdapter = new MockUniswapXAdapter(address(outputToken));
        adapter.setDirectOutput(4 ether);
        discountAdapter.setDiscountOutput(6 ether);
        outputToken.mint(address(discountAdapter), 6 ether);
        reactor.setOrder(_resolvedOrder(10 ether, _erc20Outputs(address(outputToken), 10 ether, recipient)));

        ILiquidLaneUniswapXExecutor.FillRoute[] memory routes = new ILiquidLaneUniswapXExecutor.FillRoute[](1);
        routes[0] = _directRoute(address(adapter), 4 ether, 4 ether);
        ILiquidLaneUniswapXExecutor.DiscountRoute[] memory discountRoutes =
            new ILiquidLaneUniswapXExecutor.DiscountRoute[](1);
        discountRoutes[0] = _discountRoute(address(discountAdapter), 6 ether);
        vm.prank(caller);
        executor.execute(_signedOrder(), _fillCall(routes, discountRoutes));

        assertEq(adapter.directCalls(), 1);
        assertEq(discountAdapter.discountCalls(), 1);
        assertEq(inputToken.balanceOf(address(adapter)), 4 ether);
        assertEq(inputToken.balanceOf(address(discountAdapter)), 6 ether);
    }

    function testExecuteKeepsMaxApprovalWithoutReapproving() public {
        ApprovalCountingToken countingOutput = new ApprovalCountingToken("Counting Output", "COUNT");
        MockUniswapXAdapter countingAdapter = new MockUniswapXAdapter(address(countingOutput));
        countingAdapter.setDirectOutput(9 ether);
        countingOutput.mint(address(countingAdapter), 18 ether);
        inputToken.mint(address(reactor), 10 ether);
        reactor.setOrder(_resolvedOrder(10 ether, _erc20Outputs(address(countingOutput), 9 ether, recipient)));
        ILiquidLaneUniswapXExecutor.FillRoute[] memory routes = new ILiquidLaneUniswapXExecutor.FillRoute[](1);
        routes[0] = _directRoute(address(countingAdapter), 10 ether, 9 ether);

        vm.startPrank(caller);
        executor.execute(_signedOrder(), _fillCall(routes, new ILiquidLaneUniswapXExecutor.DiscountRoute[](0)));
        executor.execute(_signedOrder(), _fillCall(routes, new ILiquidLaneUniswapXExecutor.DiscountRoute[](0)));
        vm.stopPrank();

        assertEq(countingOutput.allowance(address(executor), address(reactor)), type(uint256).max);
        assertEq(countingOutput.approveCalls(), 1);
    }

    function testExecuteForwardsNativeOutputAndReceivesReactorRefund() public {
        MockUniswapXAdapter nativeAdapter = new MockUniswapXAdapter(address(0));
        reactor.setOrder(_resolvedOrder(10 ether, _nativeOutputs(2 ether, recipient)));
        ILiquidLaneUniswapXExecutor.FillRoute[] memory routes = new ILiquidLaneUniswapXExecutor.FillRoute[](1);
        routes[0] = _directRoute(address(nativeAdapter), 10 ether, 0);
        vm.deal(address(this), 3 ether);
        payable(address(executor)).sendValue(3 ether);
        uint256 recipientBalanceBefore = recipient.balance;

        vm.prank(caller);
        executor.execute(_signedOrder(), _fillCall(routes, new ILiquidLaneUniswapXExecutor.DiscountRoute[](0)));

        assertEq(recipient.balance, recipientBalanceBefore + 2 ether);
        assertEq(address(executor).balance, 1 ether);
        assertEq(address(reactor).balance, 0);
    }

    function testExecuteBubblesAdapterRevertAndRollsBack() public {
        adapter.setShouldRevert(true);
        ILiquidLaneUniswapXExecutor.FillRoute[] memory routes = new ILiquidLaneUniswapXExecutor.FillRoute[](1);
        routes[0] = _directRoute(address(adapter), 10 ether, 9 ether);

        vm.prank(caller);
        vm.expectRevert(MockUniswapXAdapter.AdapterFailed.selector);
        executor.execute(_signedOrder(), _fillCall(routes, new ILiquidLaneUniswapXExecutor.DiscountRoute[](0)));

        assertEq(inputToken.balanceOf(address(reactor)), 10 ether);
        assertEq(inputToken.balanceOf(address(adapter)), 0);
        assertEq(outputToken.balanceOf(recipient), 0);
        assertEq(outputToken.allowance(address(executor), address(reactor)), 0);
    }

    function testExecuteBubblesReactorOutputShortfallAndRollsBack() public {
        adapter.setDirectOutput(8 ether);
        ILiquidLaneUniswapXExecutor.FillRoute[] memory routes = new ILiquidLaneUniswapXExecutor.FillRoute[](1);
        routes[0] = _directRoute(address(adapter), 10 ether, 9 ether);

        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(executor), 8 ether, 9 ether)
        );
        executor.execute(_signedOrder(), _fillCall(routes, new ILiquidLaneUniswapXExecutor.DiscountRoute[](0)));

        assertEq(inputToken.balanceOf(address(reactor)), 10 ether);
        assertEq(inputToken.balanceOf(address(adapter)), 0);
        assertEq(outputToken.balanceOf(recipient), 0);
        assertEq(outputToken.allowance(address(executor), address(reactor)), 0);
    }

    function _signedOrder() internal pure returns (UniswapXSignedOrder memory) {
        return UniswapXSignedOrder({order: hex"01", sig: hex"02"});
    }

    function _resolvedOrder(uint256 amountIn, UniswapXOutputToken[] memory outputs)
        internal
        returns (UniswapXResolvedOrder memory order)
    {
        order = UniswapXResolvedOrder({
            info: UniswapXOrderInfo({
                reactor: address(reactor),
                swapper: makeAddr("swapper"),
                nonce: 1,
                deadline: block.timestamp + 1 hours,
                additionalValidationContract: address(0),
                additionalValidationData: ""
            }),
            input: UniswapXInputToken({token: address(inputToken), amount: amountIn, maxAmount: amountIn}),
            outputs: outputs,
            sig: "",
            hash: keccak256("order")
        });
    }

    function _resolvedOrders(UniswapXResolvedOrder memory order)
        internal
        pure
        returns (UniswapXResolvedOrder[] memory orders)
    {
        orders = new UniswapXResolvedOrder[](1);
        orders[0] = order;
    }

    function _erc20Outputs(address token, uint256 amount, address outputRecipient)
        internal
        pure
        returns (UniswapXOutputToken[] memory outputs)
    {
        outputs = new UniswapXOutputToken[](1);
        outputs[0] = UniswapXOutputToken({token: token, amount: amount, recipient: outputRecipient});
    }

    function _nativeOutputs(uint256 amount, address outputRecipient)
        internal
        pure
        returns (UniswapXOutputToken[] memory outputs)
    {
        outputs = new UniswapXOutputToken[](1);
        outputs[0] = UniswapXOutputToken({token: address(0), amount: amount, recipient: outputRecipient});
    }

    function _emptyOutputs() internal pure returns (UniswapXOutputToken[] memory outputs) {
        outputs = new UniswapXOutputToken[](0);
    }

    function _callers(address caller_) internal pure returns (address[] memory callers_) {
        callers_ = new address[](1);
        callers_[0] = caller_;
    }

    function _emptyFillCall() internal pure returns (ILiquidLaneUniswapXExecutor.FillCall memory fillCall) {
        fillCall = _fillCall(
            new ILiquidLaneUniswapXExecutor.FillRoute[](0), new ILiquidLaneUniswapXExecutor.DiscountRoute[](0)
        );
    }

    function _fillCall(
        ILiquidLaneUniswapXExecutor.FillRoute[] memory routes,
        ILiquidLaneUniswapXExecutor.DiscountRoute[] memory discountRoutes
    ) internal pure returns (ILiquidLaneUniswapXExecutor.FillCall memory fillCall) {
        fillCall = ILiquidLaneUniswapXExecutor.FillCall({routes: routes, discountRoutes: discountRoutes});
    }

    function _directRoute(address routeAdapter, uint256 amountIn, uint256 amountOut)
        internal
        pure
        returns (ILiquidLaneUniswapXExecutor.FillRoute memory)
    {
        return ILiquidLaneUniswapXExecutor.FillRoute({adapter: routeAdapter, amountIn: amountIn, amountOut: amountOut});
    }

    function _discountRoute(address routeAdapter, uint256 amountIn)
        internal
        view
        returns (ILiquidLaneUniswapXExecutor.DiscountRoute memory)
    {
        return ILiquidLaneUniswapXExecutor.DiscountRoute({
            adapter: routeAdapter,
            amountIn: amountIn,
            discountSwap: ILiquidLaneAdapter.DiscountSwap({
                discount: ILiquidLaneAdapter.Discount({
                    tokenToRedeem: address(inputToken),
                    discount: 0,
                    signer: address(1),
                    protocol: address(2),
                    nonce: 1,
                    deadline: uint48(block.timestamp + 1 hours)
                }),
                signerSignature: hex"01",
                protocolDeadline: uint48(block.timestamp + 1 hours)
            }),
            protocolSignature: hex"02"
        });
    }
}

contract MockUniswapXReactor is IUniswapXReactor {
    using Address for address payable;
    using SafeERC20 for IERC20;

    address internal tokenIn;
    uint256 internal amountIn;
    UniswapXOutputToken[] internal storedOutputs;

    receive() external payable {}

    function setOrder(UniswapXResolvedOrder memory newOrder) external {
        tokenIn = newOrder.input.token;
        amountIn = newOrder.input.amount;
        delete storedOutputs;
        for (uint256 i; i < newOrder.outputs.length; ++i) {
            storedOutputs.push(newOrder.outputs[i]);
        }
    }

    function executeWithCallback(UniswapXSignedOrder calldata, bytes calldata callbackData) external payable {
        IERC20(tokenIn).safeTransfer(msg.sender, amountIn);

        UniswapXResolvedOrder[] memory orders = new UniswapXResolvedOrder[](1);
        UniswapXOutputToken[] memory outputs = new UniswapXOutputToken[](storedOutputs.length);
        for (uint256 i; i < storedOutputs.length; ++i) {
            outputs[i] = storedOutputs[i];
        }
        orders[0] = UniswapXResolvedOrder({
            info: UniswapXOrderInfo({
                reactor: address(this),
                swapper: address(1),
                nonce: 1,
                deadline: block.timestamp + 1 hours,
                additionalValidationContract: address(0),
                additionalValidationData: ""
            }),
            input: UniswapXInputToken({token: tokenIn, amount: amountIn, maxAmount: amountIn}),
            outputs: outputs,
            sig: "",
            hash: keccak256("order")
        });
        IUniswapXReactorCallback(msg.sender).reactorCallback(orders, callbackData);
        for (uint256 i; i < outputs.length; ++i) {
            if (outputs[i].token == address(0)) {
                payable(outputs[i].recipient).sendValue(outputs[i].amount);
            } else {
                IERC20(outputs[i].token).safeTransferFrom(msg.sender, outputs[i].recipient, outputs[i].amount);
            }
        }
        uint256 nativeRefund = address(this).balance;
        if (nativeRefund > 0) payable(msg.sender).sendValue(nativeRefund);
    }
}

contract MockUniswapXAdapter is ILiquidLaneAdapter {
    using Address for address payable;
    using SafeERC20 for IERC20;

    error AdapterFailed();

    address internal immutable outputToken;
    uint256 internal directOutput;
    uint256 internal discountOutput;
    uint256 public directCalls;
    uint256 public discountCalls;
    bool internal shouldRevert;

    constructor(address outputToken_) {
        outputToken = outputToken_;
    }

    receive() external payable {}

    function setDirectOutput(uint256 newDirectOutput) external {
        directOutput = newDirectOutput;
    }

    function setDiscountOutput(uint256 newDiscountOutput) external {
        discountOutput = newDiscountOutput;
    }

    function setShouldRevert(bool newShouldRevert) external {
        shouldRevert = newShouldRevert;
    }

    function getAmountOut(address, uint256) external view returns (uint256) {
        return directOutput;
    }

    function getMaxAssets(address) external view returns (uint256) {
        return outputToken == address(0) ? address(this).balance : IERC20(outputToken).balanceOf(address(this));
    }

    function minDiscount(address) external pure returns (uint256) {
        return 0;
    }

    function swap(Swap calldata swap_) external {
        ++directCalls;
        if (shouldRevert) revert AdapterFailed();
        _transferOutput(swap_.recipient, directOutput);
    }

    function swap(SignedSwap calldata, bytes calldata) external pure {
        revert("unsupported");
    }

    function swap(DiscountSwap calldata, bytes calldata, address recipient_, uint256)
        external
        returns (uint256 amountOut)
    {
        ++discountCalls;
        if (shouldRevert) revert AdapterFailed();
        amountOut = discountOutput;
        _transferOutput(recipient_, amountOut);
    }

    function _transferOutput(address recipient_, uint256 amount) internal {
        if (outputToken == address(0)) {
            payable(recipient_).sendValue(amount);
        } else {
            IERC20(outputToken).safeTransfer(recipient_, amount);
        }
    }
}

contract TestToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ApprovalCountingToken is TestToken {
    uint256 public approveCalls;

    constructor(string memory name_, string memory symbol_) TestToken(name_, symbol_) {}

    function _approve(address owner_, address spender, uint256 value, bool emitEvent) internal override {
        if (emitEvent) ++approveCalls;
        super._approve(owner_, spender, value, emitEvent);
    }
}
