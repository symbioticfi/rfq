// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.28;

import {Relayer} from "../src/Relayer.sol";
import {Router} from "../src/Router.sol";
import {IRelayer} from "../src/interfaces/IRelayer.sol";
import {IRouter} from "../src/interfaces/IRouter.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Test} from "forge-std/Test.sol";

contract RouterTest is Test {
    address internal user = makeAddr("user");
    address internal attacker = makeAddr("attacker");
    address internal victim = makeAddr("victim");

    MockERC20 internal tokenIn;
    MockERC20 internal tokenOut;
    MockVenue internal venue;
    Router internal router;
    Relayer internal relayer;

    function setUp() public {
        tokenIn = new MockERC20("In", "IN");
        tokenOut = new MockERC20("Out", "OUT");
        router = new Router();
        relayer = Relayer(router.RELAYER());
        venue = new MockVenue(tokenIn, tokenOut);

        tokenOut.mint(address(venue), 1_000_000e18);
        tokenIn.mint(user, 1000e18);
        vm.prank(user);
        tokenIn.approve(address(relayer), type(uint256).max);
    }

    /* PAIRING */

    function test_RouterOwnsItsRelayer() public view {
        assertEq(relayer.ROUTER(), address(router), "relayer points back at its deployer");
        assertTrue(router.RELAYER() != address(0));
    }

    /* HAPPY PATH */

    function test_Execute_PullsRunsCallsAndPaysOutputs() public {
        vm.prank(user);
        router.execute(
            address(tokenIn),
            100e18,
            _swapCalls(100e18),
            _outputs(address(tokenOut), user, 100e18),
            block.timestamp + 1 hours
        );

        assertEq(tokenOut.balanceOf(user), 100e18, "output delivered");
        assertEq(tokenIn.balanceOf(user), 900e18, "input spent");
        assertEq(tokenIn.balanceOf(address(router)), 0, "no input stranded");
        assertEq(tokenOut.balanceOf(address(router)), 0, "no output stranded");
    }

    function test_Execute_WithoutInputRunsCallsOnly() public {
        IRouter.Call[] memory calls = new IRouter.Call[](1);
        calls[0] = IRouter.Call({target: address(venue), data: abi.encodeCall(MockVenue.gift, (5e18))});

        vm.prank(user);
        router.execute(address(0), 0, calls, _outputs(address(tokenOut), user, 5e18), block.timestamp + 1 hours);

        assertEq(tokenOut.balanceOf(user), 5e18);
    }

    function test_Execute_RefundsUnspentInput() public {
        // The venue consumes half and leaves the rest sitting on the router.
        venue.setConsumeBps(5000);

        vm.prank(user);
        router.execute(
            address(tokenIn),
            100e18,
            _swapCalls(100e18),
            _outputs(address(tokenOut), user, 50e18),
            block.timestamp + 1 hours
        );

        assertEq(tokenIn.balanceOf(user), 950e18, "unspent input returned");
        assertEq(tokenIn.balanceOf(address(router)), 0, "router left empty");
    }

    /* THE INVARIANT THAT MAKES ARBITRARY CALLS SAFE */

    function test_Execute_CannotCallTheRelayer() public {
        // Victim has approved the relayer, exactly as every user must.
        tokenIn.mint(victim, 500e18);
        vm.prank(victim);
        tokenIn.approve(address(relayer), type(uint256).max);

        IRouter.Call[] memory calls = new IRouter.Call[](1);
        calls[0] = IRouter.Call({
            target: address(relayer), data: abi.encodeCall(IRelayer.pull, (address(tokenIn), victim, 500e18))
        });

        vm.prank(attacker);
        vm.expectRevert(IRouter.RelayerCallForbidden.selector);
        router.execute(address(0), 0, calls, new IRouter.Output[](0), block.timestamp + 1 hours);

        assertEq(tokenIn.balanceOf(victim), 500e18, "victim untouched");
    }

    function test_Relayer_RejectsEveryCallerButTheRouter() public {
        tokenIn.mint(victim, 500e18);
        vm.prank(victim);
        tokenIn.approve(address(relayer), type(uint256).max);

        vm.prank(attacker);
        vm.expectRevert(IRelayer.NotRouter.selector);
        relayer.pull(address(tokenIn), victim, 500e18);

        assertEq(tokenIn.balanceOf(victim), 500e18, "victim untouched");
    }

    /// @dev A call may approve a third party against the router, but the sweep means a later
    ///      transaction finds nothing to take.
    function test_Execute_LeavesNothingForALingeringApproval() public {
        IRouter.Call[] memory calls = new IRouter.Call[](3);
        // A hostile leg grants the attacker an unlimited allowance on the router...
        calls[0] = IRouter.Call({
            target: address(tokenIn), data: abi.encodeCall(IERC20.approve, (attacker, type(uint256).max))
        });
        // ...while the batch otherwise does its honest work.
        calls[1] =
            IRouter.Call({target: address(tokenIn), data: abi.encodeCall(IERC20.approve, (address(venue), 100e18))});
        calls[2] = IRouter.Call({target: address(venue), data: abi.encodeCall(MockVenue.swap, (100e18))});

        vm.prank(user);
        router.execute(
            address(tokenIn), 100e18, calls, _outputs(address(tokenOut), user, 100e18), block.timestamp + 1 hours
        );

        assertEq(tokenIn.balanceOf(address(router)), 0, "router swept");

        vm.prank(attacker);
        vm.expectRevert();
        tokenIn.transferFrom(address(router), attacker, 1);
    }

    /// @dev The router pulls for its own caller and nobody else, so an attacker cannot name a victim.
    function test_Execute_PullsOnlyFromItsCaller() public {
        tokenIn.mint(victim, 500e18);
        vm.prank(victim);
        tokenIn.approve(address(relayer), type(uint256).max);

        vm.prank(attacker);
        vm.expectRevert();
        router.execute(
            address(tokenIn), 100e18, new IRouter.Call[](0), new IRouter.Output[](0), block.timestamp + 1 hours
        );

        assertEq(tokenIn.balanceOf(victim), 500e18, "victim untouched");
    }

    /* GUARDS */

    function test_Execute_RevertsBelowMinOutput() public {
        venue.setConsumeBps(5000);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IRouter.InsufficientOutput.selector, address(tokenOut), 50e18, 100e18));
        router.execute(
            address(tokenIn),
            100e18,
            _swapCalls(100e18),
            _outputs(address(tokenOut), user, 100e18),
            block.timestamp + 1 hours
        );
    }

    function test_Execute_RevertsAfterDeadline() public {
        vm.prank(user);
        vm.expectRevert(IRouter.Expired.selector);
        router.execute(address(tokenIn), 100e18, _swapCalls(100e18), new IRouter.Output[](0), block.timestamp - 1);
    }

    function test_Execute_BubblesCallRevert() public {
        venue.setRevertOnSwap(true);

        vm.prank(user);
        vm.expectRevert(MockVenue.VenueFailed.selector);
        router.execute(address(tokenIn), 100e18, _swapCalls(100e18), new IRouter.Output[](0), block.timestamp + 1 hours);
    }

    /* HELPERS */

    function _swapCalls(uint256 amount) internal view returns (IRouter.Call[] memory calls) {
        calls = new IRouter.Call[](2);
        calls[0] =
            IRouter.Call({target: address(tokenIn), data: abi.encodeCall(IERC20.approve, (address(venue), amount))});
        calls[1] = IRouter.Call({target: address(venue), data: abi.encodeCall(MockVenue.swap, (amount))});
    }

    function _outputs(address token, address recipient, uint256 minAmount)
        internal
        pure
        returns (IRouter.Output[] memory outputs)
    {
        outputs = new IRouter.Output[](1);
        outputs[0] = IRouter.Output({token: token, recipient: recipient, minAmount: minAmount});
    }
}

contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockVenue {
    using SafeERC20 for IERC20;

    error VenueFailed();

    IERC20 internal immutable TOKEN_IN;
    IERC20 internal immutable TOKEN_OUT;
    uint256 internal consumeBps = 10_000;
    bool internal revertOnSwap;

    constructor(MockERC20 tokenIn_, MockERC20 tokenOut_) {
        TOKEN_IN = IERC20(address(tokenIn_));
        TOKEN_OUT = IERC20(address(tokenOut_));
    }

    function setConsumeBps(uint256 bps) external {
        consumeBps = bps;
    }

    function setRevertOnSwap(bool value) external {
        revertOnSwap = value;
    }

    function swap(uint256 amountIn) external {
        if (revertOnSwap) {
            revert VenueFailed();
        }

        uint256 consumed = amountIn * consumeBps / 10_000;
        TOKEN_IN.safeTransferFrom(msg.sender, address(this), consumed);
        TOKEN_OUT.safeTransfer(msg.sender, consumed);
    }

    function gift(uint256 amount) external {
        TOKEN_OUT.safeTransfer(msg.sender, amount);
    }
}
