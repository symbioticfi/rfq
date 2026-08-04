// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Router} from "../src/Router.sol";
import {IRouter} from "../src/interfaces/IRouter.sol";
import {DeployRouterScript} from "../script/deploy/DeployRouter.s.sol";

contract MockRegistry {
    mapping(address entity => bool registered) public isEntity;

    function setEntity(address entity, bool registered) external {
        isEntity[entity] = registered;
    }
}

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    uint256 public feeBps;
    bool public senderPaysFee;
    mapping(address account => uint256 balance) public balanceOf;
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }

    function setFee(uint256 feeBps_, bool senderPaysFee_) external {
        feeBps = feeBps_;
        senderPaysFee = senderPaysFee_;
    }

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
        totalSupply += amount;
    }

    function burn(address account, uint256 amount) external {
        balanceOf[account] -= amount;
        totalSupply -= amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address recipient, uint256 amount) external returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function transferFrom(address owner, address recipient, uint256 amount) external returns (bool) {
        uint256 approved = allowance[owner][msg.sender];
        if (approved != type(uint256).max) allowance[owner][msg.sender] = approved - amount;
        _transfer(owner, recipient, amount);
        return true;
    }

    function _transfer(address owner, address recipient, uint256 amount) internal {
        uint256 fee = amount * feeBps / 10_000;
        uint256 debit = senderPaysFee ? amount + fee : amount;
        uint256 credit = senderPaysFee ? amount : amount - fee;
        balanceOf[owner] -= debit;
        balanceOf[recipient] += credit;
        totalSupply -= fee;
    }
}

contract MockAdapter {
    bytes4 internal constant SIGNED_SWAP_SELECTOR = 0x9a4568b6;
    bytes4 internal constant DISCOUNT_SWAP_SELECTOR = 0x8fa5c671;

    MockERC20 public immutable inputToken;
    MockERC20 public immutable outputToken;
    address public immutable router;
    uint256 public outputAmount;
    uint256 public leaveInput;
    uint256 public callCount;
    bool public shouldRevert;
    bool public reduceRouterBalance;
    bool public reenter;

    constructor(MockERC20 inputToken_, MockERC20 outputToken_, address router_) {
        inputToken = inputToken_;
        outputToken = outputToken_;
        router = router_;
    }

    function configure(uint256 outputAmount_, uint256 leaveInput_) external {
        outputAmount = outputAmount_;
        leaveInput = leaveInput_;
    }

    function setShouldRevert(bool status) external {
        shouldRevert = status;
    }

    function setReduceRouterBalance(bool status) external {
        reduceRouterBalance = status;
    }

    function setReenter(bool status) external {
        reenter = status;
    }

    fallback() external {
        if (msg.sig != SIGNED_SWAP_SELECTOR && msg.sig != DISCOUNT_SWAP_SELECTOR) revert("selector");
        if (shouldRevert) revert("adapter failed");

        ++callCount;
        uint256 inputBalance = inputToken.balanceOf(address(this));
        if (inputBalance > leaveInput) inputToken.burn(address(this), inputBalance - leaveInput);
        if (reduceRouterBalance) outputToken.burn(router, 1 ether);
        if (outputAmount > 0) outputToken.mint(router, outputAmount);

        if (reenter) {
            IRouter.SwapCall[] memory calls = new IRouter.SwapCall[](0);
            IRouter.Output[] memory outputs = new IRouter.Output[](0);
            Router(router).execute(address(inputToken), calls, outputs);
        }
    }
}

contract RouterTest is Test {
    bytes4 internal constant SIGNED_SWAP_SELECTOR = 0x9a4568b6;
    bytes4 internal constant DISCOUNT_SWAP_SELECTOR = 0x8fa5c671;

    address internal swapper = makeAddr("swapper");
    address internal recipient = makeAddr("recipient");
    MockRegistry internal registry;
    MockERC20 internal inputToken;
    MockERC20 internal outputToken;
    MockERC20 internal secondOutputToken;
    Router internal router;
    MockAdapter internal adapter0;
    MockAdapter internal adapter1;

    function setUp() public {
        registry = new MockRegistry();
        router = new Router(address(registry));
        inputToken = new MockERC20("Input", "IN");
        outputToken = new MockERC20("Output", "OUT");
        secondOutputToken = new MockERC20("Second", "SECOND");
        adapter0 = new MockAdapter(inputToken, outputToken, address(router));
        adapter1 = new MockAdapter(inputToken, outputToken, address(router));
        registry.setEntity(address(adapter0), true);
        registry.setEntity(address(adapter1), true);
        inputToken.mint(swapper, 1_000 ether);
        vm.prank(swapper);
        inputToken.approve(address(router), type(uint256).max);
    }

    function testConstructorRejectsZeroFactory() public {
        vm.expectRevert(abi.encodeWithSelector(IRouter.InvalidFactory.selector, address(0)));
        new Router(address(0));
    }

    function testConstructorRejectsNonContractFactory() public {
        address notContract = makeAddr("notContract");
        vm.expectRevert(abi.encodeWithSelector(IRouter.InvalidFactory.selector, notContract));
        new Router(notContract);
    }

    function testStoresRegistryFactory() public view {
        assertEq(router.LIQUID_LANE_ADAPTER_FACTORY(), address(registry));
    }

    function testDeployRouterUsesFactoryEnvironment() public {
        vm.setEnv("LIQUID_LANE_ADAPTER_FACTORY", vm.toString(address(registry)));
        Router deployed = new DeployRouterScript().run();
        assertEq(deployed.LIQUID_LANE_ADAPTER_FACTORY(), address(registry));
    }

    function testDeadlineEqualityIsValid() public {
        vm.warp(100);
        vm.expectRevert(IRouter.EmptySwapCalls.selector);
        router.execute(address(inputToken), new IRouter.SwapCall[](0), new IRouter.Output[](0), 100);
    }

    function testExpiredDeadlineRevertsBeforeValidation() public {
        vm.warp(101);
        vm.expectRevert(abi.encodeWithSelector(IRouter.Expired.selector, 100));
        router.execute(address(0), new IRouter.SwapCall[](0), new IRouter.Output[](0), 100);
    }

    function testRejectsEmptySwapCalls() public {
        vm.expectRevert(IRouter.EmptySwapCalls.selector);
        router.execute(
            address(inputToken), new IRouter.SwapCall[](0), _oneOutput(address(outputToken), 1 ether, recipient)
        );
    }

    function testRejectsEmptyOutputs() public {
        vm.expectRevert(IRouter.EmptyOutputs.selector);
        router.execute(
            address(inputToken), _oneCall(address(adapter0), 1 ether, SIGNED_SWAP_SELECTOR), new IRouter.Output[](0)
        );
    }

    function testRejectsInvalidInputToken() public {
        address notContract = makeAddr("notToken");
        vm.expectRevert(abi.encodeWithSelector(IRouter.InvalidTokenIn.selector, notContract));
        router.execute(
            notContract,
            _oneCall(address(adapter0), 1 ether, SIGNED_SWAP_SELECTOR),
            _oneOutput(address(outputToken), 1 ether, recipient)
        );
    }

    function testRejectsSameInputAndOutputToken() public {
        vm.expectRevert(abi.encodeWithSelector(IRouter.InvalidOutputToken.selector, 0, address(inputToken)));
        router.execute(
            address(inputToken),
            _oneCall(address(adapter0), 1 ether, SIGNED_SWAP_SELECTOR),
            _oneOutput(address(inputToken), 1 ether, recipient)
        );
    }

    function testRejectsInvalidOutputToken() public {
        address notContract = makeAddr("notOutputToken");
        vm.expectRevert(abi.encodeWithSelector(IRouter.InvalidOutputToken.selector, 0, notContract));
        router.execute(
            address(inputToken),
            _oneCall(address(adapter0), 1 ether, SIGNED_SWAP_SELECTOR),
            _oneOutput(notContract, 1 ether, recipient)
        );
    }

    function testRejectsInvalidRecipient() public {
        vm.expectRevert(abi.encodeWithSelector(IRouter.InvalidRecipient.selector, 0, address(0)));
        router.execute(
            address(inputToken),
            _oneCall(address(adapter0), 1 ether, SIGNED_SWAP_SELECTOR),
            _oneOutput(address(outputToken), 1 ether, address(0))
        );
    }

    function testRejectsRouterAsRecipient() public {
        vm.expectRevert(abi.encodeWithSelector(IRouter.InvalidRecipient.selector, 0, address(router)));
        router.execute(
            address(inputToken),
            _oneCall(address(adapter0), 1 ether, SIGNED_SWAP_SELECTOR),
            _oneOutput(address(outputToken), 1 ether, address(router))
        );
    }

    function testRejectsZeroOutputAmount() public {
        vm.expectRevert(abi.encodeWithSelector(IRouter.InvalidAmount.selector, 0));
        router.execute(
            address(inputToken),
            _oneCall(address(adapter0), 1 ether, SIGNED_SWAP_SELECTOR),
            _oneOutput(address(outputToken), 0, recipient)
        );
    }

    function testRejectsZeroCallAmount() public {
        vm.expectRevert(abi.encodeWithSelector(IRouter.InvalidAmount.selector, 0));
        router.execute(
            address(inputToken),
            _oneCall(address(adapter0), 0, SIGNED_SWAP_SELECTOR),
            _oneOutput(address(outputToken), 1 ether, recipient)
        );
    }

    function testRejectsUnregisteredAdapter() public {
        MockAdapter unregistered = new MockAdapter(inputToken, outputToken, address(router));
        vm.expectRevert(abi.encodeWithSelector(IRouter.InvalidAdapter.selector, 0, address(unregistered)));
        router.execute(
            address(inputToken),
            _oneCall(address(unregistered), 1 ether, SIGNED_SWAP_SELECTOR),
            _oneOutput(address(outputToken), 1 ether, recipient)
        );
    }

    function testRejectsShortCalldata() public {
        IRouter.SwapCall[] memory calls = new IRouter.SwapCall[](1);
        calls[0] = IRouter.SwapCall({adapter: address(adapter0), amountIn: 1 ether, data: hex"9a4568"});
        vm.expectRevert(abi.encodeWithSelector(IRouter.InvalidCalldata.selector, 0));
        router.execute(address(inputToken), calls, _oneOutput(address(outputToken), 1 ether, recipient));
    }

    function testRejectsUnapprovedSelector() public {
        vm.expectRevert(abi.encodeWithSelector(IRouter.InvalidSelector.selector, 0, bytes4(0x12345678)));
        router.execute(
            address(inputToken),
            _oneCall(address(adapter0), 1 ether, 0x12345678),
            _oneOutput(address(outputToken), 1 ether, recipient)
        );
    }

    function testAcceptsDiscountSelector() public {
        adapter0.configure(1 ether, 0);
        vm.prank(swapper);
        router.execute(
            address(inputToken),
            _oneCall(address(adapter0), 1 ether, DISCOUNT_SWAP_SELECTOR),
            _oneOutput(address(outputToken), 1 ether, recipient)
        );
        assertEq(outputToken.balanceOf(recipient), 1 ether);
    }

    function testTransfersEachInputDirectlyAndCallsAllAdapters() public {
        adapter0.configure(4 ether, 0);
        adapter1.configure(6 ether, 0);
        IRouter.SwapCall[] memory calls = new IRouter.SwapCall[](2);
        calls[0] = IRouter.SwapCall({
            adapter: address(adapter0), amountIn: 4 ether, data: abi.encodePacked(SIGNED_SWAP_SELECTOR)
        });
        calls[1] = IRouter.SwapCall({
            adapter: address(adapter1), amountIn: 6 ether, data: abi.encodePacked(DISCOUNT_SWAP_SELECTOR)
        });

        vm.prank(swapper);
        router.execute(address(inputToken), calls, _oneOutput(address(outputToken), 10 ether, recipient));

        assertEq(inputToken.balanceOf(address(router)), 0);
        assertEq(inputToken.balanceOf(address(adapter0)), 0);
        assertEq(inputToken.balanceOf(address(adapter1)), 0);
        assertEq(adapter0.callCount(), 1);
        assertEq(adapter1.callCount(), 1);
        assertEq(outputToken.balanceOf(recipient), 10 ether);
    }

    function testRevertsWhenInputAllowanceIsMissing() public {
        vm.prank(swapper);
        inputToken.approve(address(router), 0);
        adapter0.configure(1 ether, 0);
        vm.expectRevert();
        vm.prank(swapper);
        router.execute(
            address(inputToken),
            _oneCall(address(adapter0), 1 ether, SIGNED_SWAP_SELECTOR),
            _oneOutput(address(outputToken), 1 ether, recipient)
        );
    }

    function testRevertsFeeOnTransferInput() public {
        inputToken.setFee(100, false);
        adapter0.configure(1 ether, 0);
        vm.expectRevert(abi.encodeWithSelector(IRouter.InputTransferMismatch.selector, 0, 1 ether, 0.99 ether));
        vm.prank(swapper);
        router.execute(
            address(inputToken),
            _oneCall(address(adapter0), 1 ether, SIGNED_SWAP_SELECTOR),
            _oneOutput(address(outputToken), 1 ether, recipient)
        );
    }

    function testRevertsSenderFeeInput() public {
        inputToken.setFee(100, true);
        adapter0.configure(1 ether, 0);
        vm.expectRevert(abi.encodeWithSelector(IRouter.InputTransferMismatch.selector, 0, 1 ether, 1.01 ether));
        vm.prank(swapper);
        router.execute(
            address(inputToken),
            _oneCall(address(adapter0), 1 ether, SIGNED_SWAP_SELECTOR),
            _oneOutput(address(outputToken), 1 ether, recipient)
        );
    }

    function testRevertsWhenAdapterDoesNotConsumeExactLeg() public {
        adapter0.configure(1 ether, 0.1 ether);
        vm.expectRevert(abi.encodeWithSelector(IRouter.InputConsumptionMismatch.selector, 0, 0, 0.1 ether));
        vm.prank(swapper);
        router.execute(
            address(inputToken),
            _oneCall(address(adapter0), 1 ether, SIGNED_SWAP_SELECTOR),
            _oneOutput(address(outputToken), 1 ether, recipient)
        );
    }

    function testWrapsAdapterRevertData() public {
        adapter0.setShouldRevert(true);
        bytes memory reason = abi.encodeWithSignature("Error(string)", "adapter failed");
        vm.expectRevert(abi.encodeWithSelector(IRouter.AdapterCallFailed.selector, 0, address(adapter0), reason));
        vm.prank(swapper);
        router.execute(
            address(inputToken),
            _oneCall(address(adapter0), 1 ether, SIGNED_SWAP_SELECTOR),
            _oneOutput(address(outputToken), 1 ether, recipient)
        );
    }

    function testLateLegFailureRollsBackEarlierLeg() public {
        adapter0.configure(4 ether, 0);
        adapter1.setShouldRevert(true);
        IRouter.SwapCall[] memory calls = new IRouter.SwapCall[](2);
        calls[0] = IRouter.SwapCall({
            adapter: address(adapter0), amountIn: 4 ether, data: abi.encodePacked(SIGNED_SWAP_SELECTOR)
        });
        calls[1] = IRouter.SwapCall({
            adapter: address(adapter1), amountIn: 6 ether, data: abi.encodePacked(SIGNED_SWAP_SELECTOR)
        });

        vm.expectRevert();
        vm.prank(swapper);
        router.execute(address(inputToken), calls, _oneOutput(address(outputToken), 10 ether, recipient));

        assertEq(inputToken.balanceOf(swapper), 1_000 ether);
        assertEq(outputToken.balanceOf(address(router)), 0);
        assertEq(adapter0.callCount(), 0);
    }

    function testPreexistingBalanceCannotSatisfyMinimumOrBecomeSurplus() public {
        outputToken.mint(address(router), 100 ether);
        adapter0.configure(9 ether, 0);
        vm.expectRevert(
            abi.encodeWithSelector(IRouter.InsufficientOutput.selector, address(outputToken), 10 ether, 9 ether)
        );
        vm.prank(swapper);
        router.execute(
            address(inputToken),
            _oneCall(address(adapter0), 10 ether, SIGNED_SWAP_SELECTOR),
            _oneOutput(address(outputToken), 10 ether, recipient)
        );
        assertEq(outputToken.balanceOf(address(router)), 100 ether);
    }

    function testSurplusGoesToCallerAfterExactRecipientPayments() public {
        adapter0.configure(12 ether, 0);
        vm.prank(swapper);
        router.execute(
            address(inputToken),
            _oneCall(address(adapter0), 10 ether, SIGNED_SWAP_SELECTOR),
            _oneOutput(address(outputToken), 10 ether, recipient)
        );
        assertEq(outputToken.balanceOf(recipient), 10 ether);
        assertEq(outputToken.balanceOf(swapper), 2 ether);
        assertEq(outputToken.balanceOf(address(router)), 0);
    }

    function testDuplicateOutputTokensUseOneAggregateMinimum() public {
        adapter0.configure(12 ether, 0);
        IRouter.Output[] memory outputs = new IRouter.Output[](2);
        outputs[0] = IRouter.Output({token: address(outputToken), recipient: recipient, amount: 4 ether});
        outputs[1] = IRouter.Output({token: address(outputToken), recipient: swapper, amount: 6 ether});

        vm.prank(swapper);
        router.execute(address(inputToken), _oneCall(address(adapter0), 10 ether, SIGNED_SWAP_SELECTOR), outputs);

        assertEq(outputToken.balanceOf(recipient), 4 ether);
        assertEq(outputToken.balanceOf(swapper), 8 ether);
        assertEq(outputToken.balanceOf(address(router)), 0);
    }

    function testMultipleOutputTokensSettleIndependently() public {
        adapter0.configure(5 ether, 0);
        secondOutputToken.mint(address(router), 100 ether);
        secondOutputToken.mint(address(router), 7 ether);
        IRouter.Output[] memory outputs = new IRouter.Output[](2);
        outputs[0] = IRouter.Output({token: address(outputToken), recipient: recipient, amount: 5 ether});
        outputs[1] = IRouter.Output({token: address(secondOutputToken), recipient: recipient, amount: 7 ether});

        vm.expectRevert(
            abi.encodeWithSelector(IRouter.InsufficientOutput.selector, address(secondOutputToken), 7 ether, 0)
        );
        vm.prank(swapper);
        router.execute(address(inputToken), _oneCall(address(adapter0), 5 ether, SIGNED_SWAP_SELECTOR), outputs);
    }

    function testFeeOnTransferOutputRevertsAndRollsBack() public {
        outputToken.setFee(100, false);
        adapter0.configure(10 ether, 0);
        vm.expectRevert(abi.encodeWithSelector(IRouter.OutputTransferMismatch.selector, 0, 10 ether, 9.9 ether));
        vm.prank(swapper);
        router.execute(
            address(inputToken),
            _oneCall(address(adapter0), 10 ether, SIGNED_SWAP_SELECTOR),
            _oneOutput(address(outputToken), 10 ether, recipient)
        );
        assertEq(outputToken.balanceOf(recipient), 0);
    }

    function testSenderFeeOutputRevertsAndRollsBack() public {
        outputToken.setFee(100, true);
        adapter0.configure(11 ether, 0);
        vm.expectRevert(abi.encodeWithSelector(IRouter.OutputTransferMismatch.selector, 0, 10 ether, 10.1 ether));
        vm.prank(swapper);
        router.execute(
            address(inputToken),
            _oneCall(address(adapter0), 10 ether, SIGNED_SWAP_SELECTOR),
            _oneOutput(address(outputToken), 10 ether, recipient)
        );
        assertEq(outputToken.balanceOf(recipient), 0);
    }

    function testAdapterCannotReducePreexistingOutputBalance() public {
        outputToken.mint(address(router), 100 ether);
        adapter0.configure(10 ether, 0);
        adapter0.setReduceRouterBalance(true);
        vm.expectRevert(
            abi.encodeWithSelector(IRouter.InsufficientOutput.selector, address(outputToken), 10 ether, 9 ether)
        );
        vm.prank(swapper);
        router.execute(
            address(inputToken),
            _oneCall(address(adapter0), 10 ether, SIGNED_SWAP_SELECTOR),
            _oneOutput(address(outputToken), 10 ether, recipient)
        );
        assertEq(outputToken.balanceOf(address(router)), 100 ether);
    }

    function testAdapterReentrancyRevertsWholeBatch() public {
        adapter0.configure(10 ether, 0);
        adapter0.setReenter(true);
        vm.expectRevert();
        vm.prank(swapper);
        router.execute(
            address(inputToken),
            _oneCall(address(adapter0), 10 ether, SIGNED_SWAP_SELECTOR),
            _oneOutput(address(outputToken), 10 ether, recipient)
        );
        assertEq(inputToken.balanceOf(swapper), 1_000 ether);
        assertEq(outputToken.balanceOf(recipient), 0);
    }

    function _oneCall(address adapter, uint256 amountIn, bytes4 selector)
        internal
        pure
        returns (IRouter.SwapCall[] memory calls)
    {
        calls = new IRouter.SwapCall[](1);
        calls[0] = IRouter.SwapCall({adapter: adapter, amountIn: amountIn, data: abi.encodePacked(selector)});
    }

    function _oneOutput(address token, uint256 amount, address to)
        internal
        pure
        returns (IRouter.Output[] memory outputs)
    {
        outputs = new IRouter.Output[](1);
        outputs[0] = IRouter.Output({token: token, recipient: to, amount: amount});
    }
}
