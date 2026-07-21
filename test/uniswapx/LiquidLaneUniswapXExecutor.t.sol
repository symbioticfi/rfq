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

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Test} from "forge-std/Test.sol";

contract LiquidLaneUniswapXExecutorTest is Test {
    address internal caller = makeAddr("caller");
    address internal owner = makeAddr("owner");
    address internal recipient = makeAddr("recipient");
    address internal feeRecipient = makeAddr("feeRecipient");

    TestToken internal inputToken;
    TestToken internal outputToken;
    MockUniswapXAdapter internal adapter;
    MockUniswapXReactor internal reactor;
    LiquidLaneUniswapXExecutor internal executor;

    function setUp() public {
        inputToken = new TestToken("Input", "IN");
        outputToken = new TestToken("Output", "OUT");
        adapter = new MockUniswapXAdapter(outputToken);
        reactor = new MockUniswapXReactor();

        executor = new LiquidLaneUniswapXExecutor(address(reactor), owner, _callers(caller));

        inputToken.mint(address(reactor), 10 ether);
        outputToken.mint(address(adapter), 100 ether);
        reactor.setOrder(_resolvedOrder(10 ether, 9 ether));
    }

    function testExecuteFillsThroughReactorCallback() public {
        vm.prank(caller);
        executor.execute(UniswapXSignedOrder({order: hex"01", sig: hex"02"}), _fillCall(10 ether, 9 ether));

        assertEq(inputToken.balanceOf(address(adapter)), 10 ether);
        assertEq(outputToken.balanceOf(recipient), 9 ether);
        assertEq(outputToken.balanceOf(address(executor)), 0);
        assertEq(outputToken.allowance(address(executor), address(reactor)), 0);
    }

    function testExecuteKeepsDirectRouteSurplus() public {
        vm.prank(caller);
        executor.execute(UniswapXSignedOrder({order: hex"01", sig: hex"02"}), _fillCall(10 ether, 10 ether));

        assertEq(outputToken.balanceOf(recipient), 9 ether);
        assertEq(outputToken.balanceOf(address(executor)), 1 ether);
        assertEq(outputToken.allowance(address(executor), address(reactor)), 0);
    }

    function testExecuteFillsSignedDiscountRoute() public {
        vm.prank(caller);
        executor.execute(UniswapXSignedOrder({order: hex"01", sig: hex"02"}), _discountFillCall(10 ether, 9 ether));

        assertEq(inputToken.balanceOf(address(adapter)), 10 ether);
        assertEq(outputToken.balanceOf(recipient), 9 ether);
        assertEq(outputToken.balanceOf(address(executor)), 1 ether);
        assertEq(outputToken.allowance(address(executor), address(reactor)), 0);
    }

    function testExecuteFillsSameTokenFeeOutputs() public {
        reactor.setOrder(_resolvedMultiOutputOrder(10 ether, 8 ether, 1 ether));

        vm.prank(caller);
        executor.execute(UniswapXSignedOrder({order: hex"01", sig: hex"02"}), _fillCall(10 ether, 9 ether));

        assertEq(outputToken.balanceOf(recipient), 8 ether);
        assertEq(outputToken.balanceOf(feeRecipient), 1 ether);
        assertEq(outputToken.balanceOf(address(executor)), 0);
        assertEq(outputToken.allowance(address(executor), address(reactor)), 0);
    }

    function testExecuteRejectsMixedOutputTokens() public {
        TestToken otherOutput = new TestToken("Other Output", "OTHER");
        UniswapXResolvedOrder memory order = _resolvedMultiOutputOrder(10 ether, 8 ether, 1 ether);
        order.outputs[1].token = address(otherOutput);
        reactor.setOrder(order);

        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILiquidLaneUniswapXExecutor.OutputTokenMismatch.selector, address(outputToken), address(otherOutput)
            )
        );
        executor.execute(UniswapXSignedOrder({order: hex"01", sig: hex"02"}), _fillCall(10 ether, 9 ether));
    }

    function testExecuteRejectsDiscountAdapterThatOverreportsOutput() public {
        adapter.setAmountOut(8 ether);
        adapter.setReportedAmountOut(10 ether);

        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILiquidLaneUniswapXExecutor.RouteOutputTooLow.selector, address(adapter), 9 ether, 8 ether
            )
        );
        executor.execute(UniswapXSignedOrder({order: hex"01", sig: hex"02"}), _discountFillCall(10 ether, 9 ether));
    }

    function testExecuteRejectsNonCaller() public {
        vm.expectRevert(ILiquidLaneUniswapXExecutor.NotCaller.selector);
        vm.prank(makeAddr("relayer"));
        executor.execute(UniswapXSignedOrder({order: hex"01", sig: hex"02"}), _fillCall(10 ether, 9 ether));
    }

    function testOwnerCanReplaceCallers() public {
        address newCaller = makeAddr("newCaller");

        vm.prank(owner);
        executor.setCallers(_callers(newCaller));

        assertEq(executor.callers(0), newCaller);
        assertTrue(executor.isCaller(newCaller));
        assertFalse(executor.isCaller(caller));
        vm.prank(newCaller);
        executor.execute(UniswapXSignedOrder({order: hex"01", sig: hex"02"}), _fillCall(10 ether, 9 ether));
        assertEq(outputToken.balanceOf(recipient), 9 ether);
    }

    function testOnlyOwnerCanReplaceCallers() public {
        address relayer = makeAddr("relayer");

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, relayer));
        executor.setCallers(_callers(relayer));
    }

    function testOnlyOwnerCanSweep() public {
        address relayer = makeAddr("relayer");
        inputToken.mint(address(executor), 1 ether);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, relayer));
        executor.sweepERC20(address(inputToken), relayer, 1 ether);
    }

    function testOwnerCanSweep() public {
        inputToken.mint(address(executor), 1 ether);

        vm.prank(owner);
        executor.sweepERC20(address(inputToken), owner, 1 ether);

        assertEq(inputToken.balanceOf(owner), 1 ether);
    }

    function testCallbackRejectsNonReactor() public {
        UniswapXResolvedOrder[] memory orders = new UniswapXResolvedOrder[](1);
        orders[0] = _resolvedOrder(10 ether, 9 ether);

        vm.expectRevert(ILiquidLaneUniswapXExecutor.NotReactor.selector);
        executor.reactorCallback(orders, abi.encode(_fillCall(10 ether, 9 ether)));
    }

    function testCallbackRejectsZeroInputToken() public {
        UniswapXResolvedOrder[] memory orders = new UniswapXResolvedOrder[](1);
        orders[0] = _resolvedOrder(10 ether, 9 ether);
        orders[0].input.token = address(0);

        vm.expectRevert(ILiquidLaneUniswapXExecutor.ZeroAddress.selector);
        vm.prank(address(reactor));
        executor.reactorCallback(orders, abi.encode(_fillCall(10 ether, 9 ether)));
    }

    function testCallbackRejectsZeroOutputToken() public {
        UniswapXResolvedOrder[] memory orders = new UniswapXResolvedOrder[](1);
        orders[0] = _resolvedOrder(10 ether, 9 ether);
        orders[0].outputs[0].token = address(0);

        vm.expectRevert(ILiquidLaneUniswapXExecutor.ZeroAddress.selector);
        vm.prank(address(reactor));
        executor.reactorCallback(orders, abi.encode(_fillCall(10 ether, 9 ether)));
    }

    function testExecuteRejectsInsufficientRouteMinimum() public {
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(ILiquidLaneUniswapXExecutor.InsufficientMinimumOutput.selector, 8 ether, 9 ether)
        );
        executor.execute(UniswapXSignedOrder({order: hex"01", sig: hex"02"}), _fillCall(10 ether, 8 ether));
    }

    function testExecuteRejectsRouteThatNoLongerMeetsMinimum() public {
        adapter.setAmountOut(8 ether);

        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILiquidLaneUniswapXExecutor.RouteOutputTooLow.selector, address(adapter), 9 ether, 8 ether
            )
        );
        executor.execute(UniswapXSignedOrder({order: hex"01", sig: hex"02"}), _fillCall(10 ether, 9 ether));
    }

    function testExecuteAcceptsRoutePlannedBeforeExactOutputDecay() public {
        vm.prank(caller);
        executor.execute(UniswapXSignedOrder({order: hex"01", sig: hex"02"}), _fillCall(9 ether, 9 ether));

        assertEq(inputToken.balanceOf(address(adapter)), 9 ether);
        assertEq(inputToken.balanceOf(address(executor)), 1 ether);
        assertEq(outputToken.balanceOf(recipient), 9 ether);
    }

    function testExecuteAcceptsDiscountRoutePlannedBeforeExactOutputDecay() public {
        vm.prank(caller);
        executor.execute(UniswapXSignedOrder({order: hex"01", sig: hex"02"}), _discountFillCall(9 ether, 9 ether));

        assertEq(inputToken.balanceOf(address(adapter)), 9 ether);
        assertEq(inputToken.balanceOf(address(executor)), 1 ether);
        assertEq(outputToken.balanceOf(recipient), 9 ether);
    }

    function testExecuteRejectsInputAboveResolvedAmount() public {
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(ILiquidLaneUniswapXExecutor.RouteInputExceedsOrder.selector, 11 ether, 10 ether)
        );
        executor.execute(UniswapXSignedOrder({order: hex"01", sig: hex"02"}), _fillCall(11 ether, 9 ether));
    }

    function testExecuteRejectsZeroAdapter() public {
        ILiquidLaneUniswapXExecutor.FillCall memory fillCall = _fillCall(10 ether, 9 ether);
        fillCall.routes[0].adapter = address(0);

        vm.prank(caller);
        vm.expectRevert(ILiquidLaneUniswapXExecutor.ZeroAddress.selector);
        executor.execute(UniswapXSignedOrder({order: hex"01", sig: hex"02"}), fillCall);
    }

    function testExecuteRejectsZeroDiscountAdapter() public {
        ILiquidLaneUniswapXExecutor.FillCall memory fillCall = _discountFillCall(10 ether, 9 ether);
        fillCall.discountRoutes[0].adapter = address(0);

        vm.prank(caller);
        vm.expectRevert(ILiquidLaneUniswapXExecutor.ZeroAddress.selector);
        executor.execute(UniswapXSignedOrder({order: hex"01", sig: hex"02"}), fillCall);
    }

    function testExecuteRejectsDiscountForAnotherInputToken() public {
        ILiquidLaneUniswapXExecutor.FillCall memory fillCall = _discountFillCall(10 ether, 9 ether);
        fillCall.discountRoutes[0].discountSwap.discount.tokenToRedeem = address(outputToken);

        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILiquidLaneUniswapXExecutor.DiscountTokenMismatch.selector, address(inputToken), address(outputToken)
            )
        );
        executor.execute(UniswapXSignedOrder({order: hex"01", sig: hex"02"}), fillCall);
    }

    function _resolvedOrder(uint256 amountIn, uint256 amountOut) internal returns (UniswapXResolvedOrder memory order) {
        UniswapXOutputToken[] memory outputs = new UniswapXOutputToken[](1);
        outputs[0] = UniswapXOutputToken({token: address(outputToken), amount: amountOut, recipient: recipient});
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

    function _callers(address caller) internal pure returns (address[] memory callers_) {
        callers_ = new address[](1);
        callers_[0] = caller;
    }

    function _resolvedMultiOutputOrder(uint256 amountIn, uint256 swapperAmountOut, uint256 feeAmountOut)
        internal
        returns (UniswapXResolvedOrder memory order)
    {
        UniswapXOutputToken[] memory outputs = new UniswapXOutputToken[](2);
        outputs[0] = UniswapXOutputToken({token: address(outputToken), amount: swapperAmountOut, recipient: recipient});
        outputs[1] = UniswapXOutputToken({token: address(outputToken), amount: feeAmountOut, recipient: feeRecipient});
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
            hash: keccak256("multi-output-order")
        });
    }

    function _fillCall(uint256 amountIn, uint256 amountOut)
        internal
        view
        returns (ILiquidLaneUniswapXExecutor.FillCall memory fillCall)
    {
        ILiquidLaneUniswapXExecutor.FillRoute[] memory routes = new ILiquidLaneUniswapXExecutor.FillRoute[](1);
        routes[0] = ILiquidLaneUniswapXExecutor.FillRoute({
            adapter: address(adapter), amountIn: amountIn, amountOut: amountOut
        });
        fillCall = ILiquidLaneUniswapXExecutor.FillCall({
            routes: routes, discountRoutes: new ILiquidLaneUniswapXExecutor.DiscountRoute[](0)
        });
    }

    function _discountFillCall(uint256 amountIn, uint256 minAmountOut)
        internal
        view
        returns (ILiquidLaneUniswapXExecutor.FillCall memory fillCall)
    {
        ILiquidLaneUniswapXExecutor.DiscountRoute[] memory routes = new ILiquidLaneUniswapXExecutor.DiscountRoute[](1);
        routes[0] = ILiquidLaneUniswapXExecutor.DiscountRoute({
            adapter: address(adapter),
            amountIn: amountIn,
            minAmountOut: minAmountOut,
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
        fillCall = ILiquidLaneUniswapXExecutor.FillCall({
            routes: new ILiquidLaneUniswapXExecutor.FillRoute[](0), discountRoutes: routes
        });
    }
}

contract MockUniswapXReactor is IUniswapXReactor {
    using SafeERC20 for IERC20;

    address internal tokenIn;
    uint256 internal amountIn;
    UniswapXOutputToken[] internal storedOutputs;

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
            IERC20(outputs[i].token).safeTransferFrom(msg.sender, outputs[i].recipient, outputs[i].amount);
        }
    }
}

contract MockUniswapXAdapter is ILiquidLaneAdapter {
    using SafeERC20 for IERC20;

    TestToken internal immutable outputToken;
    uint256 internal amountOut = 10 ether;
    uint256 internal reportedAmountOut = 10 ether;

    constructor(TestToken outputToken_) {
        outputToken = outputToken_;
    }

    function setAmountOut(uint256 newAmountOut) external {
        amountOut = newAmountOut;
    }

    function setReportedAmountOut(uint256 newAmountOut) external {
        reportedAmountOut = newAmountOut;
    }

    function getAmountOut(address, uint256) external view returns (uint256) {
        return amountOut;
    }

    function getMaxAssets(address) external view returns (uint256) {
        return outputToken.balanceOf(address(this));
    }

    function minDiscount(address) external pure returns (uint256) {
        return 0;
    }

    function swap(Swap calldata swap_) external {
        IERC20(address(outputToken)).safeTransfer(swap_.recipient, _min(swap_.amountOut, amountOut));
    }

    function swap(SignedSwap calldata, bytes calldata) external pure {
        revert("unsupported");
    }

    function swap(DiscountSwap calldata, bytes calldata, address recipient_, uint256) external returns (uint256) {
        IERC20(address(outputToken)).safeTransfer(recipient_, amountOut);
        return reportedAmountOut;
    }

    function _min(uint256 left, uint256 right) private pure returns (uint256) {
        return left < right ? left : right;
    }
}

contract TestToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
