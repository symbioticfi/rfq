// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.28;

import {FlashLoanCapability} from "../src/FlashLoanCapability.sol";
import {Relayer} from "../src/Relayer.sol";
import {Router} from "../src/Router.sol";
import {IFlashLoanCapability, IFlashLoanMorphoCallback} from "../src/interfaces/IFlashLoanCapability.sol";
import {IRelayer} from "../src/interfaces/IRelayer.sol";
import {IRouter} from "../src/interfaces/IRouter.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Test} from "forge-std/Test.sol";

contract FlashLoanCapabilityTest is Test {
    address internal user = makeAddr("user");
    address internal attacker = makeAddr("attacker");
    address internal victim = makeAddr("victim");

    MockERC20 internal token;
    MockMorpho internal morpho;
    MockAave internal aave;
    MockSink internal sink;
    FlashLoanCapability internal capability;
    Router internal router;
    Relayer internal relayer;

    function setUp() public {
        token = new MockERC20("Token", "TKN");
        morpho = new MockMorpho();
        aave = new MockAave();
        capability = new FlashLoanCapability();
        router = new Router();
        relayer = Relayer(router.RELAYER());
        sink = new MockSink(token);

        token.mint(address(morpho), 1_000_000e18);
        token.mint(address(aave), 1_000_000e18);
        token.mint(address(sink), 1_000_000e18);
    }

    /* HAPPY PATH */

    function test_FlashLoan_Morpho_RunsCallsAndRepays() public {
        vm.prank(user);
        capability.flashLoan(
            IFlashLoanCapability.Provider.Morpho, address(morpho), address(token), 100e18, _useAndReturn(100e18, 100e18)
        );

        assertEq(sink.seen(), 1, "the borrowed-liquidity calls ran");
        assertEq(token.balanceOf(address(capability)), 0, "nothing stranded");
        assertEq(token.balanceOf(address(morpho)), 1_000_000e18, "principal repaid");
    }

    function test_FlashLoan_Aave_RepaysPrincipalPlusPremium() public {
        aave.setPremiumBps(9); // 0.09%, Aave's standard

        vm.prank(user);
        capability.flashLoan(
            IFlashLoanCapability.Provider.Aave, address(aave), address(token), 100e18, _useAndReturn(100e18, 100.09e18)
        );

        assertEq(token.balanceOf(address(aave)), 1_000_000e18 + 0.09e18, "premium paid");
        assertEq(token.balanceOf(address(capability)), 0, "nothing stranded");
    }

    function test_FlashLoan_SweepsSurplusToCaller() public {
        // The calls return more than was borrowed; the excess is the caller's.
        vm.prank(user);
        capability.flashLoan(
            IFlashLoanCapability.Provider.Morpho, address(morpho), address(token), 100e18, _useAndReturn(100e18, 130e18)
        );

        assertEq(token.balanceOf(user), 30e18, "surplus returned to the caller");
        assertEq(token.balanceOf(address(capability)), 0, "nothing left for the next caller");
    }

    function test_FlashLoan_RevertsWhenCallsCannotRepay() public {
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IFlashLoanCapability.FlashLoanNotRepaid.selector, address(token), 60e18, 100e18)
        );
        capability.flashLoan(
            IFlashLoanCapability.Provider.Morpho, address(morpho), address(token), 100e18, _useAndReturn(100e18, 60e18)
        );
    }

    /* CALLBACK AUTHENTICATION */

    function test_Callback_RevertsWithoutAnInFlightLoan() public {
        vm.prank(attacker);
        vm.expectRevert(IFlashLoanCapability.UnexpectedFlashLoan.selector);
        IFlashLoanMorphoCallback(address(capability))
            .onMorphoFlashLoan(100e18, abi.encode(address(token), abi.encode(new IRouter.Call[](0))));
    }

    /// @dev A real loan is in flight, but a different address tries to drive its callback. The hash
    ///      binds the provider, so only the lender we actually borrowed from can.
    function test_Callback_RevertsForAnImpostorLender() public {
        MockImpostor impostor = new MockImpostor(capability, token);
        token.mint(address(impostor), 1000e18);

        vm.prank(attacker);
        vm.expectRevert(IFlashLoanCapability.UnexpectedFlashLoan.selector);
        impostor.attack(100e18);
    }

    /* NESTING */

    function test_FlashLoan_LoansMayNest() public {
        IRouter.Call[] memory inner = _useAndReturn(50e18, 50e18);
        IRouter.Call[] memory outer = new IRouter.Call[](2);
        outer[0] = IRouter.Call({
            target: address(capability),
            data: abi.encodeCall(
                IFlashLoanCapability.flashLoan,
                (IFlashLoanCapability.Provider.Aave, address(aave), address(token), 50e18, inner)
            )
        });
        outer[1] = IRouter.Call({target: address(sink), data: abi.encodeCall(MockSink.giveBack, (100e18))});

        vm.prank(user);
        capability.flashLoan(IFlashLoanCapability.Provider.Morpho, address(morpho), address(token), 100e18, outer);

        assertEq(token.balanceOf(address(capability)), 0, "both loans settled, nothing stranded");
    }

    /* THE RELAYER IS OUT OF REACH FROM HERE */

    /// @dev The capability makes arbitrary calls too, so it is a second route to the relayer. The
    ///      relayer's own caller check is what closes it — it answers only to its router.
    function test_FlashLoan_CannotDrainTheRelayer() public {
        token.mint(victim, 500e18);
        vm.prank(victim);
        token.approve(address(relayer), type(uint256).max);

        IRouter.Call[] memory calls = new IRouter.Call[](1);
        calls[0] = IRouter.Call({
            target: address(relayer), data: abi.encodeCall(IRelayer.pull, (address(token), victim, 500e18))
        });

        vm.prank(attacker);
        vm.expectRevert(IRelayer.NotRouter.selector);
        capability.flashLoan(IFlashLoanCapability.Provider.Morpho, address(morpho), address(token), 0, calls);

        assertEq(token.balanceOf(victim), 500e18, "victim untouched");
    }

    /* HELPERS */

    /// @dev Spends the whole borrowed amount, then hands back `returned`. Consuming the principal
    ///      is what makes the repayment check meaningful — otherwise the borrowed funds alone would
    ///      always cover it and a shortfall could never be observed.
    function _useAndReturn(uint256 borrowed, uint256 returned) internal view returns (IRouter.Call[] memory calls) {
        calls = new IRouter.Call[](2);
        calls[0] =
            IRouter.Call({target: address(token), data: abi.encodeCall(IERC20.transfer, (address(sink), borrowed))});
        calls[1] = IRouter.Call({target: address(sink), data: abi.encodeCall(MockSink.giveBack, (returned))});
    }
}

contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Stands in for whatever the borrowed funds are used on.
contract MockSink {
    using SafeERC20 for IERC20;

    IERC20 internal immutable TOKEN;
    uint256 public seen;

    constructor(MockERC20 token_) {
        TOKEN = IERC20(address(token_));
    }

    function giveBack(uint256 returned) external {
        ++seen;
        TOKEN.safeTransfer(msg.sender, returned);
    }
}

contract MockMorpho {
    using SafeERC20 for IERC20;

    function flashLoan(address token, uint256 assets, bytes calldata data) external {
        IERC20(token).safeTransfer(msg.sender, assets);
        IFlashLoanMorphoCallback(msg.sender).onMorphoFlashLoan(assets, data);
        IERC20(token).safeTransferFrom(msg.sender, address(this), assets);
    }
}

contract MockAave {
    using SafeERC20 for IERC20;

    uint256 internal premiumBps;

    function setPremiumBps(uint256 bps) external {
        premiumBps = bps;
    }

    function flashLoanSimple(address receiver, address asset, uint256 amount, bytes calldata params, uint16) external {
        uint256 premium = amount * premiumBps / 10_000;
        IERC20(asset).safeTransfer(receiver, amount);
        FlashLoanCapability(receiver).executeOperation(asset, amount, premium, msg.sender, params);
        IERC20(asset).safeTransferFrom(receiver, address(this), amount + premium);
    }
}

/// @dev Borrows nothing but tries to drive the callback of a loan someone else has in flight.
contract MockImpostor {
    using SafeERC20 for IERC20;

    FlashLoanCapability internal immutable CAPABILITY;
    IERC20 internal immutable TOKEN;

    constructor(FlashLoanCapability capability_, MockERC20 token_) {
        CAPABILITY = capability_;
        TOKEN = IERC20(address(token_));
    }

    function attack(uint256 amount) external {
        // No loan of ours is in flight, so the transient hash cannot match.
        IFlashLoanMorphoCallback(address(CAPABILITY))
            .onMorphoFlashLoan(amount, abi.encode(address(TOKEN), abi.encode(new IRouter.Call[](0))));
    }
}
