// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.28;

import {IRecipeRoute} from "src/interfaces/IRecipeRoute.sol";
import {IRecipeExecutor} from "src/interfaces/IRecipeExecutor.sol";
import {
    MockRecipeExecutor,
    MockRecipeAccount,
    MockRecipeOutputExecutor,
    RecipeRouteBuilder
} from "test/mocks/MockRecipeExecutor.sol";

import {ILiquidLaneAdapter} from "../../src/interfaces/ILiquidLaneAdapter.sol";
import {IInputCallback} from "../../src/lifi/interfaces/IInputCallback.sol";
import {IInputSettler} from "../../src/lifi/interfaces/IInputSettler.sol";
import {LiquidLaneLifiExecutor} from "../../src/lifi/LiquidLaneLifiExecutor.sol";
import {ILiquidLaneLifiExecutor} from "../../src/lifi/interfaces/ILiquidLaneLifiExecutor.sol";
import {IOutputSettler, MandateOutput} from "../../src/lifi/interfaces/IOutputSettler.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
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
    address internal proxyAdminOwner = makeAddr("proxyAdminOwner");

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

        executor = _deployExecutor(address(inputSettler), address(outputSettler), owner);

        outputToken.mint(address(adapter), 100 ether);
    }

    function _deployExecutor(address inputSettler_, address outputSettler_, address owner_)
        internal
        returns (LiquidLaneLifiExecutor)
    {
        return _deployExecutor(inputSettler_, outputSettler_, owner_, _callers(owner_));
    }

    function _deployExecutor(address inputSettler_, address outputSettler_, address owner_, address[] memory callers_)
        internal
        returns (LiquidLaneLifiExecutor)
    {
        LiquidLaneLifiExecutor impl = new LiquidLaneLifiExecutor(inputSettler_, outputSettler_);
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(impl), proxyAdminOwner, abi.encodeCall(LiquidLaneLifiExecutor.initialize, (owner_, callers_))
        );
        return LiquidLaneLifiExecutor(address(proxy));
    }

    function _callers(address caller) internal pure returns (address[] memory callers_) {
        callers_ = new address[](1);
        callers_[0] = caller;
    }

    /* FINALISE HAPPY PATHS */

    function testFinaliseWithCurrentTimestampFillsAndAttestsDirectRoute() public {
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        bytes32 orderId = _openOrder(order);

        executor.finaliseWithCurrentTimestamp(
            order, _directRoutes(address(adapter), 10 ether, 10 ether), _noDiscountRoutes()
        );

        assertEq(rwa.balanceOf(address(adapter)), 10 ether);
        assertEq(outputToken.balanceOf(recipient), 9 ether);
        assertEq(outputToken.balanceOf(address(executor)), 1 ether);
        assertEq(outputToken.allowance(address(executor), address(outputSettler)), type(uint256).max);
        assertEq(inputSettler.orderStatus(orderId), ORDER_STATUS_CLAIMED);
        assertEq(inputSettler.lastTimestamp(), uint32(block.timestamp));
        assertEq(inputSettler.lastSolver(), _id(address(executor)));
        assertEq(inputSettler.lastDestination(), _id(address(executor)));
        assertEq(outputSettler.lastOrderId(), orderId);
        assertEq(outputSettler.lastSolver(), _id(address(executor)));
        assertTrue(outputSettler.attested());
    }

    function testFinaliseWithCurrentTimestampExecutesMultipleRoutesAndKeepsSurplus() public {
        MockLifiAdapter secondAdapter = new MockLifiAdapter(outputToken);
        outputToken.mint(address(secondAdapter), 100 ether);
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        bytes32 orderId = _openOrder(order);

        ILiquidLaneLifiExecutor.FillRoute[] memory routes = new ILiquidLaneLifiExecutor.FillRoute[](2);
        routes[0] = _directRoute(address(adapter), 4 ether, 4 ether);
        routes[1] = _directRoute(address(secondAdapter), 6 ether, 6 ether);

        executor.finaliseWithCurrentTimestamp(order, routes, _noDiscountRoutes());

        assertEq(rwa.balanceOf(address(adapter)), 4 ether);
        assertEq(rwa.balanceOf(address(secondAdapter)), 6 ether);
        assertEq(outputToken.balanceOf(recipient), 9 ether);
        assertEq(outputToken.balanceOf(address(executor)), 1 ether);
    }

    function testFinaliseWithCurrentTimestampExecutesDiscountRoute() public {
        vm.warp(1000);
        IInputSettler.StandardOrder memory order = _order(10 ether, 8 ether);
        _openOrder(order);

        ILiquidLaneLifiExecutor.DiscountRoute[] memory discountRoutes = new ILiquidLaneLifiExecutor.DiscountRoute[](1);
        discountRoutes[0] = _discountRoute(address(adapter), 10 ether, 100_000);

        executor.finaliseWithCurrentTimestamp(order, _noRoutes(), discountRoutes);

        assertEq(rwa.balanceOf(address(adapter)), 10 ether);
        assertEq(outputToken.balanceOf(recipient), 8 ether);
        assertEq(outputToken.balanceOf(address(executor)), 1 ether);
    }

    function testFinaliseWithCurrentTimestampExecutesDirectAndDiscountRoutes() public {
        vm.warp(1000);
        IInputSettler.StandardOrder memory order = _order(10 ether, 8 ether);
        _openOrder(order);

        ILiquidLaneLifiExecutor.DiscountRoute[] memory discountRoutes = new ILiquidLaneLifiExecutor.DiscountRoute[](1);
        discountRoutes[0] = _discountRoute(address(adapter), 6 ether, 100_000);

        executor.finaliseWithCurrentTimestamp(order, _directRoutes(address(adapter), 4 ether, 4 ether), discountRoutes);

        assertEq(rwa.balanceOf(address(adapter)), 10 ether);
        // 4 ether direct output plus 5.4 ether discounted output; 8 ether fill leaves 1.4 ether surplus.
        assertEq(outputToken.balanceOf(recipient), 8 ether);
        assertEq(outputToken.balanceOf(address(executor)), 1.4 ether);
    }

    function testFinaliseWithCurrentTimestampSupportsSameInputAndOutputToken() public {
        MockLifiAdapter sameTokenAdapter = new MockLifiAdapter(rwa);
        rwa.mint(address(sameTokenAdapter), 100 ether);
        rwa.mint(address(executor), 3 ether);
        IInputSettler.StandardOrder memory order = _order(10 ether, 9.5 ether, address(rwa));
        _openOrder(order);

        executor.finaliseWithCurrentTimestamp(
            order, _directRoutes(address(sameTokenAdapter), 10 ether, 10 ether), _noDiscountRoutes()
        );

        assertEq(rwa.balanceOf(recipient), 9.5 ether);
        // Pre-existing 3 ether plus 0.5 ether fill surplus stay with the executor.
        assertEq(rwa.balanceOf(address(executor)), 3.5 ether);
        assertEq(rwa.balanceOf(address(sameTokenAdapter)), 100 ether);
    }

    function testFinaliseWithCurrentTimestampFillsDutchOutputAtResolvedAmount() public {
        vm.warp(1000);
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        order.outputs[0].context = _dutchContext(900, 1100, 0.01 ether);
        _openOrder(order);

        executor.finaliseWithCurrentTimestamp(
            order, _directRoutes(address(adapter), 10 ether, 10.5 ether), _noDiscountRoutes()
        );

        assertEq(outputToken.balanceOf(recipient), 10 ether);
        assertEq(outputSettler.lastOutputAmount(), 10 ether);
        assertEq(outputToken.balanceOf(address(executor)), 0.5 ether);
    }

    function testFinaliseWithCurrentTimestampFillsExclusiveDutchOutputAtResolvedAmount() public {
        vm.warp(1000);
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        order.outputs[0].context = _exclusiveDutchContext(_id(makeAddr("otherSolver")), 900, 1100, 0.01 ether);
        _openOrder(order);

        executor.finaliseWithCurrentTimestamp(
            order, _directRoutes(address(adapter), 10 ether, 10.5 ether), _noDiscountRoutes()
        );

        assertEq(outputToken.balanceOf(recipient), 10 ether);
        assertEq(outputSettler.lastOutputAmount(), 10 ether);
    }

    function testFinaliseWithCurrentTimestampFillsExclusiveOutputAfterStartTime() public {
        vm.warp(1000);
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        order.outputs[0].context = _exclusiveContext(_id(makeAddr("otherSolver")), 1000);
        _openOrder(order);

        executor.finaliseWithCurrentTimestamp(
            order, _directRoutes(address(adapter), 10 ether, 10 ether), _noDiscountRoutes()
        );

        assertEq(outputToken.balanceOf(recipient), 9 ether);
    }

    function testFinaliseWithCurrentTimestampMatchesRoutesToReceivedAmountWhenSettlerTakesFee() public {
        inputSettler.setInputFee(1 ether);
        IInputSettler.StandardOrder memory order = _order(10 ether, 8.5 ether);
        _openOrder(order);

        executor.finaliseWithCurrentTimestamp(
            order, _directRoutes(address(adapter), 9 ether, 9 ether), _noDiscountRoutes()
        );

        assertEq(rwa.balanceOf(address(adapter)), 9 ether);
        assertEq(rwa.balanceOf(address(inputSettler)), 1 ether);
        assertEq(outputToken.balanceOf(recipient), 8.5 ether);
        assertEq(outputToken.balanceOf(address(executor)), 0.5 ether);
    }

    function testFinaliseWithCurrentTimestampPreservesExistingInputBalance() public {
        rwa.mint(address(executor), 5 ether);
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        _openOrder(order);

        executor.finaliseWithCurrentTimestamp(
            order, _directRoutes(address(adapter), 10 ether, 10 ether), _noDiscountRoutes()
        );

        assertEq(rwa.balanceOf(address(executor)), 5 ether);
        assertEq(outputToken.balanceOf(recipient), 9 ether);
    }

    function testFinaliseWithCurrentTimestampKeepsOutputWhenExecutorIsRecipient() public {
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        order.outputs[0].recipient = _id(address(executor));
        _openOrder(order);

        executor.finaliseWithCurrentTimestamp(
            order, _directRoutes(address(adapter), 10 ether, 10 ether), _noDiscountRoutes()
        );

        assertEq(outputToken.balanceOf(address(executor)), 10 ether);
    }

    function testFinaliseWithCurrentTimestampKeepsCallbackRefundSeparateFromSurplus() public {
        RefundingOutputRecipient outputRecipient = new RefundingOutputRecipient(outputToken, address(executor), 1 ether);
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        order.outputs[0].recipient = _id(address(outputRecipient));
        order.outputs[0].callbackData = hex"01";
        _openOrder(order);

        executor.finaliseWithCurrentTimestamp(
            order, _directRoutes(address(adapter), 10 ether, 10 ether), _noDiscountRoutes()
        );

        assertEq(outputToken.balanceOf(address(outputRecipient)), 8 ether);
        assertEq(outputToken.balanceOf(address(executor)), 2 ether);
    }

    /* FINALISE DELEGATED REVERTS */

    function testFinaliseWithCurrentTimestampBubblesExclusivityBeforeStartTime() public {
        vm.warp(1000);
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        order.outputs[0].context = _exclusiveContext(_id(makeAddr("otherSolver")), 1001);
        _openOrder(order);

        vm.expectRevert(bytes("exclusive"));
        executor.finaliseWithCurrentTimestamp(
            order, _directRoutes(address(adapter), 10 ether, 10 ether), _noDiscountRoutes()
        );
    }

    function testFinaliseWithCurrentTimestampBubblesInsufficientOutputForResolvedDutchAmount() public {
        vm.warp(1000);
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        order.outputs[0].context = _dutchContext(900, 1100, 0.01 ether);
        _openOrder(order);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(executor), 9.5 ether, 10 ether
            )
        );
        executor.finaliseWithCurrentTimestamp(
            order, _directRoutes(address(adapter), 10 ether, 9.5 ether), _noDiscountRoutes()
        );
    }

    function testFinaliseWithCurrentTimestampBubblesAlreadyClaimedOrder() public {
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        inputSettler.setOrderStatus(_orderId(order), ORDER_STATUS_CLAIMED);

        vm.expectRevert(MockInputSettler.InvalidOrderStatus.selector);
        executor.finaliseWithCurrentTimestamp(
            order, _directRoutes(address(adapter), 10 ether, 10 ether), _noDiscountRoutes()
        );
    }

    function testFinaliseWithCurrentTimestampBubblesExpiredFillDeadline() public {
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        order.fillDeadline = uint32(block.timestamp - 1);
        _openOrder(order);

        vm.expectRevert(bytes("deadline"));
        executor.finaliseWithCurrentTimestamp(
            order, _directRoutes(address(adapter), 10 ether, 10 ether), _noDiscountRoutes()
        );
    }

    /* CALLER AUTHORIZATION */

    function testFinaliseWithCurrentTimestampRejectsUnauthorizedCaller() public {
        address caller = makeAddr("caller");
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);

        vm.expectRevert(ILiquidLaneLifiExecutor.NotCaller.selector);
        vm.prank(caller);
        executor.finaliseWithCurrentTimestamp(
            order, _directRoutes(address(adapter), 10 ether, 10 ether), _noDiscountRoutes()
        );
    }

    function testSetCallersAllowsNonOwnerToFinaliseAndRevokesOldCaller() public {
        address caller = makeAddr("caller");
        executor.setCallers(_callers(caller));

        assertTrue(executor.isCaller(caller));
        assertFalse(executor.isCaller(owner));

        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        _openOrder(order);

        vm.prank(caller);
        executor.finaliseWithCurrentTimestamp(
            order, _directRoutes(address(adapter), 10 ether, 10 ether), _noDiscountRoutes()
        );
        assertEq(outputToken.balanceOf(recipient), 9 ether);

        IInputSettler.StandardOrder memory secondOrder = _order(10 ether, 8 ether);
        vm.expectRevert(ILiquidLaneLifiExecutor.NotCaller.selector);
        executor.finaliseWithCurrentTimestamp(
            secondOrder, _directRoutes(address(adapter), 10 ether, 10 ether), _noDiscountRoutes()
        );
    }

    function testSetCallersRejectsNonOwner() public {
        address caller = makeAddr("caller");

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", caller));
        vm.prank(caller);
        executor.setCallers(_callers(caller));
    }

    /* CALLBACK AUTHENTICATION */

    function testOrderFinalisedRejectsNonInputSettler() public {
        vm.expectRevert(ILiquidLaneLifiExecutor.NotInputSettler.selector);
        executor.orderFinalised(_inputs(10 ether), abi.encode(_unsolicitedFillCall()));
    }

    /* EIP-1271 REGISTRATION */

    function testIsValidSignatureAcceptsCallerWithRegistrationDomain() public {
        uint256 callerKey = 0xA11CE;
        LiquidLaneLifiExecutor callerExecutor =
            _deployExecutor(address(inputSettler), address(outputSettler), owner, _callers(vm.addr(callerKey)));
        bytes32 messageHash = keccak256("lifi registration");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(callerKey, callerExecutor.lifiRegistrationDigest(messageHash));

        assertEq(
            callerExecutor.isValidSignature(messageHash, abi.encodePacked(r, s, v)), IERC1271.isValidSignature.selector
        );
    }

    function testIsValidSignatureAcceptsAnyCaller() public {
        uint256 firstCallerKey = 0xA11CE;
        uint256 secondCallerKey = 0xB0B;
        address[] memory allowedCallers = new address[](2);
        allowedCallers[0] = vm.addr(firstCallerKey);
        allowedCallers[1] = vm.addr(secondCallerKey);
        LiquidLaneLifiExecutor callerExecutor =
            _deployExecutor(address(inputSettler), address(outputSettler), owner, allowedCallers);
        bytes32 messageHash = keccak256("lifi registration");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(secondCallerKey, callerExecutor.lifiRegistrationDigest(messageHash));

        assertEq(
            callerExecutor.isValidSignature(messageHash, abi.encodePacked(r, s, v)), IERC1271.isValidSignature.selector
        );
    }

    function testIsValidSignatureRejectsOwnerWhenNotCaller() public {
        uint256 ownerKey = 0xA11CE;
        LiquidLaneLifiExecutor callerExecutor =
            _deployExecutor(address(inputSettler), address(outputSettler), vm.addr(ownerKey), _callers(vm.addr(0xB0B)));
        bytes32 messageHash = keccak256("lifi registration");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, callerExecutor.lifiRegistrationDigest(messageHash));

        assertEq(callerExecutor.isValidSignature(messageHash, abi.encodePacked(r, s, v)), bytes4(0xffffffff));
    }

    function testIsValidSignatureRejectsRawMessageHashSignature() public {
        uint256 callerKey = 0xA11CE;
        LiquidLaneLifiExecutor callerExecutor =
            _deployExecutor(address(inputSettler), address(outputSettler), owner, _callers(vm.addr(callerKey)));
        bytes32 messageHash = keccak256("lifi registration");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(callerKey, messageHash);

        assertEq(callerExecutor.isValidSignature(messageHash, abi.encodePacked(r, s, v)), bytes4(0xffffffff));
    }

    function testIsValidSignatureRejectsSignatureForAnotherExecutor() public {
        uint256 callerKey = 0xA11CE;
        address caller = vm.addr(callerKey);
        LiquidLaneLifiExecutor firstExecutor =
            _deployExecutor(address(inputSettler), address(outputSettler), owner, _callers(caller));
        LiquidLaneLifiExecutor secondExecutor =
            _deployExecutor(address(inputSettler), address(outputSettler), owner, _callers(caller));
        bytes32 messageHash = keccak256("lifi registration");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(callerKey, firstExecutor.lifiRegistrationDigest(messageHash));

        assertEq(secondExecutor.isValidSignature(messageHash, abi.encodePacked(r, s, v)), bytes4(0xffffffff));
    }

    function testIsValidSignatureRejectsRemovedCaller() public {
        uint256 callerKey = 0xA11CE;
        LiquidLaneLifiExecutor callerExecutor =
            _deployExecutor(address(inputSettler), address(outputSettler), owner, _callers(vm.addr(callerKey)));
        bytes32 messageHash = keccak256("lifi registration");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(callerKey, callerExecutor.lifiRegistrationDigest(messageHash));

        callerExecutor.setCallers(new address[](0));

        assertEq(callerExecutor.isValidSignature(messageHash, abi.encodePacked(r, s, v)), bytes4(0xffffffff));
    }

    function testIsValidSignatureRejectsMalformedSignature() public {
        assertEq(executor.isValidSignature(keccak256("lifi registration"), hex"deadbeef"), bytes4(0xffffffff));
    }

    /* UPGRADEABILITY */

    function testInitializeSetsOwnerAndCallers() public view {
        assertEq(executor.owner(), owner);
        assertEq(executor.callers(0), owner);
        assertTrue(executor.isCaller(owner));
    }

    function testInitializeCannotBeCalledTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        executor.initialize(makeAddr("intruder"), _callers(makeAddr("intruder")));
    }

    function testImplementationInitializerIsDisabled() public {
        LiquidLaneLifiExecutor impl = new LiquidLaneLifiExecutor(address(inputSettler), address(outputSettler));

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(makeAddr("intruder"), _callers(makeAddr("intruder")));
    }

    /* MOCK SELF-TESTS */

    function testMockFinaliseRejectsStaleOrFutureTimestamp() public {
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        IInputSettler.SolveParams[] memory solveParams = new IInputSettler.SolveParams[](1);
        solveParams[0].solver = _id(address(executor));

        vm.warp(100);
        solveParams[0].timestamp = 99;
        vm.expectRevert(MockInputSettler.TimestampPassed.selector);
        inputSettler.finalise(order, solveParams, _id(address(executor)), hex"");

        solveParams[0].timestamp = 101;
        vm.expectRevert(MockInputSettler.TimestampNotPassed.selector);
        inputSettler.finalise(order, solveParams, _id(address(executor)), hex"");
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

    /* HELPERS */

    function _order(uint256 amountIn, uint256 amountOut) internal view returns (IInputSettler.StandardOrder memory) {
        return _order(amountIn, amountOut, address(outputToken));
    }

    /* RECIPE ROUTES */

    function testFinaliseRecipeDefersMismatchedFundingFailureToToken() public {
        (IRecipeRoute.RecipeRoute memory route, MockRecipeExecutor recipe) = _newRecipe(10 ether, 10 ether);
        address unfundedConnector = route.connector;
        (IRecipeRoute.RecipeRoute memory other,) = _newRecipe(10 ether, 10 ether);
        route.connector = other.connector;
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        bytes32 orderId = _openOrder(order);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, unfundedConnector, 0, 10 ether)
        );
        executor.finaliseWithCurrentTimestamp(order, _noRoutes(), _noDiscountRoutes(), _oneRecipe(route));
        _assertRecipeRollback(orderId, recipe);
        assertEq(rwa.balanceOf(other.connector), 0);
    }

    function testFinaliseRecipeAcceptsInputRecipientAndRecipeWithoutMetadata() public {
        (IRecipeRoute.RecipeRoute memory route,) = _newRecipe(10 ether, 10 ether);
        MockRecipeOutputExecutor target = new MockRecipeOutputExecutor();
        outputToken.mint(address(target), 10 ether);
        route.executor = address(target);
        route.connector = makeAddr("recipeInputRecipient");
        route.runtime = new bytes[](1);
        route.runtime[0] = abi.encode(address(outputToken), address(executor), 10 ether);
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        bytes32 orderId = _openOrder(order);
        executor.finaliseWithCurrentTimestamp(order, _noRoutes(), _noDiscountRoutes(), _oneRecipe(route));
        assertEq(rwa.balanceOf(route.connector), 10 ether);
        assertEq(outputToken.balanceOf(recipient), 9 ether);
        assertEq(outputToken.balanceOf(address(executor)), 1 ether);
        assertEq(inputSettler.orderStatus(orderId), ORDER_STATUS_CLAIMED);
        assertEq(target.executions(), 1);
        assertEq(
            target.lastCallHash(),
            keccak256(
                abi.encodeCall(IRecipeExecutor.execute, (route.queries, route.steps, route.inputs, route.runtime))
            )
        );
    }

    function testFinaliseRecipeDoesNotReadAccountOrVersionMetadata() public {
        (IRecipeRoute.RecipeRoute memory route, MockRecipeExecutor recipe) = _newRecipe(10 ether, 10 ether);
        address account = recipe.account();
        vm.mockCallRevert(address(recipe), abi.encodeWithSelector(IRecipeExecutor.account.selector), hex"feed");
        vm.mockCallRevert(route.connector, abi.encodeWithSelector(IRecipeExecutor.account.selector), hex"feed");
        vm.mockCallRevert(route.connector, abi.encodeWithSignature("version()"), hex"feed");
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        bytes32 orderId = _openOrder(order);
        executor.finaliseWithCurrentTimestamp(order, _noRoutes(), _noDiscountRoutes(), _oneRecipe(route));
        assertEq(rwa.balanceOf(account), 10 ether);
        assertEq(outputToken.balanceOf(recipient), 9 ether);
        assertEq(inputSettler.orderStatus(orderId), ORDER_STATUS_CLAIMED);
        assertEq(recipe.executions(), 1);
    }

    function testFinaliseWithRealUpstreamRecipeExecutor() public {
        IRecipeExecutor recipe = RecipeRouteBuilder.deployReal(vm, address(executor));
        outputToken.mint(recipe.account(), 100 ether);
        IRecipeRoute.RecipeRoute memory route = RecipeRouteBuilder.buildManaged(
            recipe, address(rwa), address(outputToken), address(executor), 10 ether, 10 ether
        );
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        bytes32 orderId = _openOrder(order);
        executor.finaliseWithCurrentTimestamp(order, _noRoutes(), _noDiscountRoutes(), _oneRecipe(route));
        assertEq(outputToken.balanceOf(recipient), 9 ether);
        assertEq(outputToken.balanceOf(address(executor)), 1 ether);
        assertEq(inputSettler.orderStatus(orderId), ORDER_STATUS_CLAIMED);
        assertTrue(outputSettler.attested());
    }

    function testFuzzFinaliseRecipeFundsVersion2ConnectorAndSettles(uint96 rawAmount) public {
        uint256 amount = bound(rawAmount, 1, 20 ether);
        (IRecipeRoute.RecipeRoute memory route, MockRecipeExecutor recipe) = _newRecipe(amount, amount);
        IInputSettler.StandardOrder memory order = _order(amount, amount);
        bytes32 orderId = _openOrder(order);
        executor.finaliseWithCurrentTimestamp(order, _noRoutes(), _noDiscountRoutes(), _oneRecipe(route));
        assertEq(rwa.balanceOf(address(recipe)), 0);
        assertEq(rwa.balanceOf(recipe.account()), amount);
        assertEq(rwa.balanceOf(route.connector), 0);
        assertEq(MockRecipeAccount(payable(recipe.account())).connectorInputBeforeSwap(), amount);
        assertEq(outputToken.balanceOf(recipient), amount);
        assertEq(recipe.executions(), 1);
        assertEq(inputSettler.orderStatus(orderId), ORDER_STATUS_CLAIMED);
        assertTrue(outputSettler.attested());
    }

    function testFinaliseRecipeTransfersZeroAmountAfterExistingFunding() public {
        (IRecipeRoute.RecipeRoute memory route, MockRecipeExecutor recipe) = _newRecipe(10 ether, 10 ether);
        route.amountIn = 0;
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        bytes32 orderId = _openOrder(order);
        vm.expectCall(address(rwa), abi.encodeCall(IERC20.transfer, (route.connector, 0)), 1);
        executor.finaliseWithCurrentTimestamp(
            order, _directRoutes(route.connector, 10 ether, 0), _noDiscountRoutes(), _oneRecipe(route)
        );
        assertEq(MockRecipeAccount(payable(recipe.account())).connectorInputBeforeSwap(), 10 ether);
        assertEq(rwa.balanceOf(recipe.account()), 10 ether);
        assertEq(outputToken.balanceOf(recipient), 9 ether);
        assertEq(recipe.executions(), 1);
        assertEq(inputSettler.orderStatus(orderId), ORDER_STATUS_CLAIMED);
    }

    function testFinaliseCombinesDirectDiscountAndRecipeRoutes() public {
        (IRecipeRoute.RecipeRoute memory route, MockRecipeExecutor recipe) = _newRecipe(5 ether, 5 ether);
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        _openOrder(order);
        ILiquidLaneLifiExecutor.DiscountRoute[] memory discounted = new ILiquidLaneLifiExecutor.DiscountRoute[](1);
        discounted[0] = _discountRoute(address(adapter), 2 ether, 0);
        executor.finaliseWithCurrentTimestamp(
            order, _directRoutes(address(adapter), 3 ether, 3 ether), discounted, _oneRecipe(route)
        );
        assertEq(rwa.balanceOf(address(adapter)), 5 ether);
        assertEq(MockRecipeAccount(payable(recipe.account())).connectorInputBeforeSwap(), 5 ether);
        assertEq(outputToken.balanceOf(recipient), 9 ether);
        assertEq(outputToken.balanceOf(address(executor)), 1 ether);
    }

    function testFinaliseMultipleRecipeAccounts() public {
        (IRecipeRoute.RecipeRoute memory first, MockRecipeExecutor firstRecipe) = _newRecipe(3 ether, 3 ether);
        (IRecipeRoute.RecipeRoute memory second, MockRecipeExecutor secondRecipe) = _newRecipe(7 ether, 7 ether);
        IRecipeRoute.RecipeRoute[] memory routes = new IRecipeRoute.RecipeRoute[](2);
        routes[0] = first;
        routes[1] = second;
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        _openOrder(order);
        executor.finaliseWithCurrentTimestamp(order, _noRoutes(), _noDiscountRoutes(), routes);
        assertEq(firstRecipe.executions(), 1);
        assertEq(secondRecipe.executions(), 1);
        assertEq(outputToken.balanceOf(recipient), 9 ether);
    }

    function testFinaliseRecipeUsesInputAfterSettlerFeeAndKeepsSurplus() public {
        inputSettler.setInputFee(1 ether);
        (IRecipeRoute.RecipeRoute memory route, MockRecipeExecutor recipe) = _newRecipe(9 ether, 9 ether);
        IInputSettler.StandardOrder memory order = _order(10 ether, 8.5 ether);
        _openOrder(order);
        rwa.mint(address(executor), 5 ether);
        executor.finaliseWithCurrentTimestamp(order, _noRoutes(), _noDiscountRoutes(), _oneRecipe(route));
        assertEq(rwa.balanceOf(address(inputSettler)), 1 ether);
        assertEq(rwa.balanceOf(address(executor)), 5 ether);
        assertEq(MockRecipeAccount(payable(recipe.account())).connectorInputBeforeSwap(), 9 ether);
        assertEq(outputToken.balanceOf(recipient), 8.5 ether);
        assertEq(outputToken.balanceOf(address(executor)), 0.5 ether);
    }

    function testFinaliseRecipeRejectsUnauthorizedCaller() public {
        (IRecipeRoute.RecipeRoute memory route,) = _newRecipe(10 ether, 10 ether);
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        _openOrder(order);
        vm.prank(makeAddr("intruder"));
        vm.expectRevert(ILiquidLaneLifiExecutor.NotCaller.selector);
        executor.finaliseWithCurrentTimestamp(order, _noRoutes(), _noDiscountRoutes(), _oneRecipe(route));
    }

    function testFinaliseRecipeCallerFailureRestoresClaimAndInput() public {
        (IRecipeRoute.RecipeRoute memory route, MockRecipeExecutor recipe) = _newRecipe(10 ether, 10 ether);
        recipe.setCaller(address(this));
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        bytes32 orderId = _openOrder(order);
        vm.expectRevert(IRecipeExecutor.InvalidCaller.selector);
        executor.finaliseWithCurrentTimestamp(order, _noRoutes(), _noDiscountRoutes(), _oneRecipe(route));
        _assertRecipeRollback(orderId, recipe);
    }

    function testFinaliseChangedRecipeRestoresClaimAndInput() public {
        (IRecipeRoute.RecipeRoute memory route, MockRecipeExecutor recipe) = _newRecipe(10 ether, 10 ether);
        route.queries = new bytes[](1);
        route.queries[0] = hex"1234";
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        bytes32 orderId = _openOrder(order);
        vm.expectRevert(IRecipeExecutor.InvalidRecipe.selector);
        executor.finaliseWithCurrentTimestamp(order, _noRoutes(), _noDiscountRoutes(), _oneRecipe(route));
        _assertRecipeRollback(orderId, recipe);
    }

    function testFinaliseRecipeOutputShortfallRestoresAllState() public {
        (IRecipeRoute.RecipeRoute memory route, MockRecipeExecutor recipe) = _newRecipe(10 ether, 8 ether);
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        bytes32 orderId = _openOrder(order);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(executor), 8 ether, 9 ether)
        );
        executor.finaliseWithCurrentTimestamp(order, _noRoutes(), _noDiscountRoutes(), _oneRecipe(route));
        _assertRecipeRollback(orderId, recipe);
        assertEq(outputToken.allowance(address(executor), address(outputSettler)), 0);
        assertFalse(outputSettler.attested());
    }

    function testFinaliseRecipeOverdrawRestoresClaimAndInput() public {
        (IRecipeRoute.RecipeRoute memory route, MockRecipeExecutor recipe) = _newRecipe(11 ether, 11 ether);
        IInputSettler.StandardOrder memory order = _order(10 ether, 9 ether);
        bytes32 orderId = _openOrder(order);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(executor), 10 ether, 11 ether
            )
        );
        executor.finaliseWithCurrentTimestamp(order, _noRoutes(), _noDiscountRoutes(), _oneRecipe(route));
        _assertRecipeRollback(orderId, recipe);
    }

    function _newRecipe(uint256 amountIn, uint256 amountOut)
        internal
        returns (IRecipeRoute.RecipeRoute memory route, MockRecipeExecutor recipe)
    {
        recipe = new MockRecipeExecutor(address(executor));
        outputToken.mint(recipe.account(), 100 ether);
        route = RecipeRouteBuilder.build(
            recipe, address(rwa), address(outputToken), address(executor), amountIn, amountOut
        );
    }

    function _oneRecipe(IRecipeRoute.RecipeRoute memory route)
        internal
        pure
        returns (IRecipeRoute.RecipeRoute[] memory routes)
    {
        routes = new IRecipeRoute.RecipeRoute[](1);
        routes[0] = route;
    }

    function _assertRecipeRollback(bytes32 orderId, MockRecipeExecutor recipe) internal view {
        assertEq(inputSettler.orderStatus(orderId), ORDER_STATUS_DEPOSITED);
        assertEq(rwa.balanceOf(address(inputSettler)), 10 ether);
        assertEq(rwa.balanceOf(address(executor)), 0);
        assertEq(rwa.balanceOf(recipe.account()), 0);
        assertEq(rwa.balanceOf(address(MockRecipeAccount(payable(recipe.account())).connector())), 0);
        assertEq(outputToken.balanceOf(recipe.account()), 100 ether);
        assertEq(recipe.executions(), 0);
    }

    function _order(uint256 amountIn, uint256 amountOut, address tokenOut)
        internal
        view
        returns (IInputSettler.StandardOrder memory)
    {
        MandateOutput[] memory outputs = new MandateOutput[](1);
        outputs[0] = _output(amountOut, tokenOut);

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

    function _openOrder(IInputSettler.StandardOrder memory order) internal returns (bytes32 orderId) {
        orderId = _orderId(order);
        inputSettler.setOrderStatus(orderId, ORDER_STATUS_DEPOSITED);
        rwa.mint(address(inputSettler), order.inputs[0][1]);
    }

    function _directRoutes(address fillAdapter, uint256 amountIn, uint256 amountOut)
        internal
        pure
        returns (ILiquidLaneLifiExecutor.FillRoute[] memory routes)
    {
        routes = new ILiquidLaneLifiExecutor.FillRoute[](1);
        routes[0] = _directRoute(fillAdapter, amountIn, amountOut);
    }

    function _directRoute(address fillAdapter, uint256 amountIn, uint256 amountOut)
        internal
        pure
        returns (ILiquidLaneLifiExecutor.FillRoute memory)
    {
        return ILiquidLaneLifiExecutor.FillRoute({adapter: fillAdapter, amountIn: amountIn, amountOut: amountOut});
    }

    function _discountRoute(address fillAdapter, uint256 amountIn, uint256 discount)
        internal
        view
        returns (ILiquidLaneLifiExecutor.DiscountRoute memory)
    {
        return ILiquidLaneLifiExecutor.DiscountRoute({
            adapter: fillAdapter,
            amountIn: amountIn,
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
        });
    }

    function _noRoutes() internal pure returns (ILiquidLaneLifiExecutor.FillRoute[] memory routes) {}

    function _noDiscountRoutes()
        internal
        pure
        returns (ILiquidLaneLifiExecutor.DiscountRoute[] memory discountRoutes)
    {}

    function _unsolicitedFillCall() internal view returns (ILiquidLaneLifiExecutor.FillCall memory) {
        return ILiquidLaneLifiExecutor.FillCall({
            orderId: ORDER_ID,
            output: _output(9 ether),
            fillDeadline: uint32(block.timestamp + 1 hours),
            routes: _directRoutes(address(adapter), 10 ether, 10 ether),
            discountRoutes: _noDiscountRoutes()
        });
    }

    function _output(uint256 amount) internal view returns (MandateOutput memory) {
        return _output(amount, address(outputToken));
    }

    function _output(uint256 amount, address token) internal view returns (MandateOutput memory) {
        return MandateOutput({
            oracle: _id(address(outputSettler)),
            settler: _id(address(outputSettler)),
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

    error InvalidOrderStatus();
    error InvalidTimestampLength();
    error TimestampNotPassed();
    error TimestampPassed();

    mapping(bytes32 orderId => uint8 status) public orderStatus;
    uint256 public inputFee;
    uint32 public lastTimestamp;
    bytes32 public lastSolver;
    bytes32 public lastDestination;

    function setOrderStatus(bytes32 orderId, uint8 status) public {
        orderStatus[orderId] = status;
    }

    function setInputFee(uint256 fee) public {
        inputFee = fee;
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

        bytes32 orderId = _orderId(order);
        if (orderStatus[orderId] != ORDER_STATUS_DEPOSITED) revert InvalidOrderStatus();

        lastTimestamp = solveParams[0].timestamp;
        lastSolver = solveParams[0].solver;
        lastDestination = destination;

        address destinationAddress = address(uint160(uint256(destination)));
        // The claimed input amounts are forwarded verbatim even when a fee is retained.
        for (uint256 i; i < order.inputs.length; ++i) {
            IERC20(address(uint160(order.inputs[i][0]))).safeTransfer(destinationAddress, order.inputs[i][1] - inputFee);
        }

        orderStatus[orderId] = ORDER_STATUS_CLAIMED;
        IInputCallback(destinationAddress).orderFinalised(order.inputs, call);

        (ILiquidLaneLifiExecutor.FillCall memory fillCall,) =
            abi.decode(call, (ILiquidLaneLifiExecutor.FillCall, IRecipeRoute.RecipeRoute[]));
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
    function version() external pure returns (uint64) {
        return 1;
    }

    TestToken public immutable outputToken;

    constructor(TestToken outputToken_) {
        outputToken = outputToken_;
    }

    function swap(ILiquidLaneAdapter.Swap calldata swap_) public {
        require(IERC20(swap_.tokenIn).balanceOf(address(this)) >= swap_.amountIn, "missing input");
        outputToken.transfer(swap_.recipient, swap_.amountOut);
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
