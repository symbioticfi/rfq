// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Router} from "../src/Router.sol";
import {IRouter} from "../src/interfaces/IRouter.sol";
import {DeployRouterScript} from "../script/deploy/DeployRouter.s.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";

error MockAdapterFailure();

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
    bool public failTransfer;
    mapping(address account => uint256 balance) public balanceOf;
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }

    function setFailTransfer(bool status) external {
        failTransfer = status;
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
        if (failTransfer) return false;
        balanceOf[msg.sender] -= amount;
        balanceOf[recipient] += amount;
        return true;
    }

    function transferFrom(address owner, address recipient, uint256 amount) external returns (bool) {
        uint256 approved = allowance[owner][msg.sender];
        if (approved != type(uint256).max) allowance[owner][msg.sender] = approved - amount;
        balanceOf[owner] -= amount;
        balanceOf[recipient] += amount;
        return true;
    }
}

contract MockAdapter {
    MockERC20 public immutable inputToken;
    MockERC20 public immutable outputToken;
    address public immutable router;

    uint256 public outputAmount;
    uint256 public callCount;
    uint256 public inputBalanceAtCall;
    address public lastCaller;
    bytes public lastData;
    bool public consumeInput;
    bool public reenter;
    bool public shouldRevert;

    constructor(MockERC20 inputToken_, MockERC20 outputToken_, address router_) {
        inputToken = inputToken_;
        outputToken = outputToken_;
        router = router_;
    }

    function configure(uint256 outputAmount_, bool consumeInput_, bool reenter_, bool shouldRevert_) external {
        outputAmount = outputAmount_;
        consumeInput = consumeInput_;
        reenter = reenter_;
        shouldRevert = shouldRevert_;
    }

    fallback() external {
        if (shouldRevert) revert MockAdapterFailure();

        ++callCount;
        inputBalanceAtCall = inputToken.balanceOf(address(this));
        lastCaller = msg.sender;
        lastData = msg.data;

        if (reenter) {
            Router(router).execute(address(inputToken), new IRouter.SwapCall[](0), new IRouter.Output[](0));
        }

        if (consumeInput) {
            uint256 inputBalance = inputToken.balanceOf(address(this));
            if (inputBalance != 0) inputToken.burn(address(this), inputBalance);
        }
        if (outputAmount != 0) outputToken.mint(router, outputAmount);
    }
}

contract RouterTest is Test {
    address internal swapper = makeAddr("swapper");
    address internal recipient = makeAddr("recipient");
    address internal secondRecipient = makeAddr("secondRecipient");

    MockRegistry internal registry;
    MockERC20 internal inputToken;
    MockERC20 internal outputToken;
    Router internal router;
    MockAdapter internal adapter0;
    MockAdapter internal adapter1;

    function setUp() public {
        registry = new MockRegistry();
        router = new Router(address(registry));
        inputToken = new MockERC20("Input", "IN");
        outputToken = new MockERC20("Output", "OUT");
        adapter0 = new MockAdapter(inputToken, outputToken, address(router));
        adapter1 = new MockAdapter(inputToken, outputToken, address(router));

        registry.setEntity(address(adapter0), true);
        registry.setEntity(address(adapter1), true);
        inputToken.mint(swapper, 1000 ether);
        vm.prank(swapper);
        inputToken.approve(address(router), type(uint256).max);
    }

    function testConstructorStoresZeroFactory() public {
        Router zeroFactoryRouter = new Router(address(0));

        assertEq(zeroFactoryRouter.LIQUID_LANE_ADAPTER_FACTORY(), address(0));
    }

    function testConstructorStoresNonContractFactory() public {
        address notContract = makeAddr("notContract");
        Router nonContractFactoryRouter = new Router(notContract);

        assertEq(nonContractFactoryRouter.LIQUID_LANE_ADAPTER_FACTORY(), notContract);
    }

    function testStoresRegistryFactory() public view {
        assertEq(router.LIQUID_LANE_ADAPTER_FACTORY(), address(registry));
    }

    function testDeployRouterUsesFactoryEnvironment() public {
        vm.setEnv("LIQUID_LANE_ADAPTER_FACTORY", vm.toString(address(registry)));
        Router deployed = new DeployRouterScript().run();
        assertEq(deployed.LIQUID_LANE_ADAPTER_FACTORY(), address(registry));
    }

    function testSwapCallUsesThreeFieldAbiAndForwardsOpaqueCalldata() public {
        bytes memory data = hex"deadbeef010203";
        IRouter.SwapCall[] memory calls = _oneCall(address(adapter0), 0, data);
        IRouter.Output[] memory outputs = new IRouter.Output[](0);
        bytes4 selector = bytes4(keccak256("execute(address,(address,uint256,bytes)[],(address,address,uint256)[])"));

        vm.prank(swapper);
        (bool success,) = address(router).call(abi.encodeWithSelector(selector, address(inputToken), calls, outputs));

        assertTrue(success);
        assertEq(adapter0.callCount(), 1);
        assertEq(adapter0.lastCaller(), address(router));
        assertEq(adapter0.lastData(), data);
    }

    function testEmptyBatchSucceedsWithoutTokenValidation() public {
        router.execute(address(0), new IRouter.SwapCall[](0), new IRouter.Output[](0));
    }

    function testZeroOutputAmountAndRecipientAreNotPrevalidated() public {
        IRouter.Output[] memory outputs = _oneOutput(address(inputToken), 0, address(0));
        router.execute(address(inputToken), new IRouter.SwapCall[](0), outputs);
    }

    function testDeadlineEqualityIsValid() public {
        vm.warp(100);
        router.execute(address(0), new IRouter.SwapCall[](0), new IRouter.Output[](0), 100);
    }

    function testExpiredDeadlineRevertsBeforeAnyOtherInteraction() public {
        vm.warp(101);
        vm.expectRevert(abi.encodeWithSelector(IRouter.Expired.selector, 100));
        router.execute(address(0), new IRouter.SwapCall[](0), new IRouter.Output[](0), 100);
    }

    function testTransfersEachInputDirectlyAndAggregatesAdapterOutputs() public {
        bytes memory firstData = hex"8fa5c6710102";
        bytes memory secondData = hex"9a4568b60304";
        adapter0.configure(4 ether, true, false, false);
        adapter1.configure(6 ether, true, false, false);
        IRouter.SwapCall[] memory calls = new IRouter.SwapCall[](2);
        calls[0] = _call(address(adapter0), 4 ether, firstData);
        calls[1] = _call(address(adapter1), 6 ether, secondData);

        vm.prank(swapper);
        router.execute(address(inputToken), calls, _oneOutput(address(outputToken), 10 ether, recipient));

        assertEq(inputToken.balanceOf(address(router)), 0);
        assertEq(adapter0.inputBalanceAtCall(), 4 ether);
        assertEq(adapter1.inputBalanceAtCall(), 6 ether);
        assertEq(adapter0.lastData(), firstData);
        assertEq(adapter1.lastData(), secondData);
        assertEq(outputToken.balanceOf(recipient), 10 ether);
    }

    function testTransfersOutputsInCallerSpecifiedOrder() public {
        outputToken.mint(address(router), 10 ether);
        IRouter.Output[] memory outputs = new IRouter.Output[](2);
        outputs[0] = IRouter.Output({token: address(outputToken), recipient: recipient, amount: 4 ether});
        outputs[1] = IRouter.Output({token: address(outputToken), recipient: secondRecipient, amount: 6 ether});

        router.execute(address(0), new IRouter.SwapCall[](0), outputs);

        assertEq(outputToken.balanceOf(recipient), 4 ether);
        assertEq(outputToken.balanceOf(secondRecipient), 6 ether);
    }

    function testPreexistingRouterBalanceCanFundDeclaredOutput() public {
        outputToken.mint(address(router), 3 ether);

        router.execute(address(0), new IRouter.SwapCall[](0), _oneOutput(address(outputToken), 3 ether, recipient));

        assertEq(outputToken.balanceOf(recipient), 3 ether);
        assertEq(outputToken.balanceOf(address(router)), 0);
    }

    function testUndeclaredSurplusRemainsInRouter() public {
        adapter0.configure(12 ether, true, false, false);

        vm.prank(swapper);
        router.execute(
            address(inputToken),
            _oneCall(address(adapter0), 10 ether, hex"01"),
            _oneOutput(address(outputToken), 10 ether, recipient)
        );

        assertEq(outputToken.balanceOf(recipient), 10 ether);
        assertEq(outputToken.balanceOf(address(router)), 2 ether);
    }

    function testDoesNotRequireAdapterToConsumeInput() public {
        adapter0.configure(0, false, false, false);

        vm.prank(swapper);
        router.execute(address(inputToken), _oneCall(address(adapter0), 7 ether, bytes("")), new IRouter.Output[](0));

        assertEq(inputToken.balanceOf(address(adapter0)), 7 ether);
        assertEq(adapter0.callCount(), 1);
    }

    function testRejectsUnregisteredAdapterBeforeFundingIt() public {
        registry.setEntity(address(adapter0), false);
        vm.expectRevert(abi.encodeWithSelector(IRouter.InvalidAdapter.selector, 0, address(adapter0)));

        vm.prank(swapper);
        router.execute(address(inputToken), _oneCall(address(adapter0), 1 ether, hex"00"), new IRouter.Output[](0));

        assertEq(inputToken.balanceOf(swapper), 1000 ether);
        assertEq(inputToken.balanceOf(address(adapter0)), 0);
    }

    function testLaterUnregisteredAdapterRollsBackEarlierLeg() public {
        adapter0.configure(4 ether, true, false, false);
        registry.setEntity(address(adapter1), false);
        IRouter.SwapCall[] memory calls = new IRouter.SwapCall[](2);
        calls[0] = _call(address(adapter0), 4 ether, hex"01");
        calls[1] = _call(address(adapter1), 6 ether, hex"02");
        vm.expectRevert(abi.encodeWithSelector(IRouter.InvalidAdapter.selector, 1, address(adapter1)));

        vm.prank(swapper);
        router.execute(address(inputToken), calls, new IRouter.Output[](0));

        assertEq(inputToken.balanceOf(swapper), 1000 ether);
        assertEq(adapter0.callCount(), 0);
        assertEq(inputToken.balanceOf(address(adapter0)), 0);
    }

    function testBubblesAdapterRevertData() public {
        adapter0.configure(0, false, false, true);
        vm.expectRevert(MockAdapterFailure.selector);

        vm.prank(swapper);
        router.execute(address(inputToken), _oneCall(address(adapter0), 1 ether, hex"1234"), new IRouter.Output[](0));
    }

    function testRegisteredNonContractAdapterReverts() public {
        address nonContractAdapter = makeAddr("nonContractAdapter");
        registry.setEntity(nonContractAdapter, true);
        vm.expectRevert(abi.encodeWithSelector(Address.AddressEmptyCode.selector, nonContractAdapter));

        vm.prank(swapper);
        router.execute(address(inputToken), _oneCall(nonContractAdapter, 1 ether, hex"1234"), new IRouter.Output[](0));
    }

    function testLaterAdapterFailureRollsBackWholeBatch() public {
        adapter0.configure(4 ether, true, false, false);
        adapter1.configure(0, false, false, true);
        IRouter.SwapCall[] memory calls = new IRouter.SwapCall[](2);
        calls[0] = _call(address(adapter0), 4 ether, hex"01");
        calls[1] = _call(address(adapter1), 6 ether, hex"02");
        vm.expectRevert();

        vm.prank(swapper);
        router.execute(address(inputToken), calls, new IRouter.Output[](0));

        assertEq(inputToken.balanceOf(swapper), 1000 ether);
        assertEq(adapter0.callCount(), 0);
        assertEq(inputToken.balanceOf(address(adapter0)), 0);
        assertEq(inputToken.balanceOf(address(adapter1)), 0);
    }

    function testOutputTransferFailureRollsBackAdapterExecution() public {
        adapter0.configure(10 ether, true, false, false);
        outputToken.setFailTransfer(true);
        vm.expectRevert();

        vm.prank(swapper);
        router.execute(
            address(inputToken),
            _oneCall(address(adapter0), 10 ether, hex"01"),
            _oneOutput(address(outputToken), 10 ether, recipient)
        );

        assertEq(inputToken.balanceOf(swapper), 1000 ether);
        assertEq(adapter0.callCount(), 0);
        assertEq(outputToken.balanceOf(address(router)), 0);
        assertEq(outputToken.balanceOf(recipient), 0);
    }

    function testAdapterReentrancyRevertsWholeBatch() public {
        adapter0.configure(10 ether, true, true, false);
        bytes memory reentrancyReason = abi.encodeWithSignature("ReentrancyGuardReentrantCall()");
        vm.expectRevert(reentrancyReason);

        vm.prank(swapper);
        router.execute(
            address(inputToken),
            _oneCall(address(adapter0), 10 ether, hex"01"),
            _oneOutput(address(outputToken), 10 ether, recipient)
        );

        assertEq(inputToken.balanceOf(swapper), 1000 ether);
        assertEq(adapter0.callCount(), 0);
        assertEq(outputToken.balanceOf(recipient), 0);
    }

    function testDeadlineExecutionRemainsReentrancyProtected() public {
        adapter0.configure(10 ether, true, true, false);
        bytes memory reentrancyReason = abi.encodeWithSignature("ReentrancyGuardReentrantCall()");
        vm.expectRevert(reentrancyReason);

        vm.prank(swapper);
        router.execute(
            address(inputToken),
            _oneCall(address(adapter0), 10 ether, hex"01"),
            _oneOutput(address(outputToken), 10 ether, recipient),
            block.timestamp
        );
    }

    function testFuzzAggregatesRegisteredLegs(uint96 rawAmount0, uint96 rawAmount1) public {
        uint256 amount0 = bound(uint256(rawAmount0), 0, 100 ether);
        uint256 amount1 = bound(uint256(rawAmount1), 0, 100 ether);
        adapter0.configure(amount0, true, false, false);
        adapter1.configure(amount1, true, false, false);
        IRouter.SwapCall[] memory calls = new IRouter.SwapCall[](2);
        calls[0] = _call(address(adapter0), amount0, hex"8fa5c671");
        calls[1] = _call(address(adapter1), amount1, hex"9a4568b6");

        vm.prank(swapper);
        router.execute(address(inputToken), calls, _oneOutput(address(outputToken), amount0 + amount1, recipient));

        assertEq(outputToken.balanceOf(recipient), amount0 + amount1);
        assertEq(inputToken.balanceOf(address(router)), 0);
    }

    function _oneCall(address adapter, uint256 amountIn, bytes memory data)
        internal
        pure
        returns (IRouter.SwapCall[] memory calls)
    {
        calls = new IRouter.SwapCall[](1);
        calls[0] = _call(adapter, amountIn, data);
    }

    function _call(address adapter, uint256 amountIn, bytes memory data)
        internal
        pure
        returns (IRouter.SwapCall memory)
    {
        return IRouter.SwapCall({adapter: adapter, amountIn: amountIn, data: data});
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
