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

    /* THE CALLS DO THE WORK, INCLUDING REPAYMENT */

    function test_FlashLoan_Morpho_RunsCallsAndTheCallsRepay() public {
        vm.prank(user);
        capability.flashLoan(_request(IFlashLoanCapability.Provider.Morpho, address(morpho), 100e18, 100e18, 100e18));

        assertEq(sink.calls(), 1, "borrowed-liquidity calls ran");
        assertEq(token.balanceOf(address(morpho)), 1_000_000e18, "lender made whole");
        assertEq(token.balanceOf(address(capability)), 0, "nothing stranded");
    }

    function test_FlashLoan_Aave_CallsCoverThePremium() public {
        aave.setPremiumBps(9);

        vm.prank(user);
        // The caller composes repayment, so it is the caller who accounts for the premium.
        capability.flashLoan(_request(IFlashLoanCapability.Provider.Aave, address(aave), 100e18, 100e18, 100.09e18));

        assertEq(token.balanceOf(address(aave)), 1_000_000e18 + 0.09e18, "premium paid by the calls");
        assertEq(token.balanceOf(address(capability)), 0, "nothing stranded");
    }

    function test_FlashLoan_SweepsSurplusToCaller() public {
        vm.prank(user);
        capability.flashLoan(_request(IFlashLoanCapability.Provider.Morpho, address(morpho), 100e18, 100e18, 130e18));

        assertEq(token.balanceOf(user), 30e18, "surplus returned to the caller");
        assertEq(token.balanceOf(address(capability)), 0, "nothing left for the next caller");
    }

    /// @dev Repayment is not this contract's concern, so a shortfall surfaces from the lender.
    function test_FlashLoan_ShortfallRevertsInTheLender() public {
        vm.prank(user);
        vm.expectRevert();
        capability.flashLoan(_request(IFlashLoanCapability.Provider.Morpho, address(morpho), 100e18, 100e18, 60e18));
    }

    function test_FlashLoan_LoansMayNest() public {
        IRouter.Call[] memory inner = _useAndRepay(50e18, 50e18, address(aave));
        IRouter.Call[] memory outer = new IRouter.Call[](4);
        outer[0] = IRouter.Call({
            target: address(capability),
            data: abi.encodeCall(
                IFlashLoanCapability.flashLoan,
                (abi.encode(
                        IFlashLoanCapability.Provider.Aave, address(aave), address(token), 50e18, abi.encode(inner)
                    ))
            )
        });
        outer[1] =
            IRouter.Call({target: address(token), data: abi.encodeCall(IERC20.transfer, (address(sink), 100e18))});
        outer[2] = IRouter.Call({target: address(sink), data: abi.encodeCall(MockSink.giveBack, (100e18))});
        // The outer lender pulls too, so the outer list carries its own repayment leg.
        outer[3] = IRouter.Call({
            target: address(token), data: abi.encodeCall(IERC20.approve, (address(morpho), type(uint256).max))
        });

        vm.prank(user);
        capability.flashLoan(
            abi.encode(IFlashLoanCapability.Provider.Morpho, address(morpho), address(token), 100e18, abi.encode(outer))
        );

        assertEq(token.balanceOf(address(capability)), 0, "both loans settled, nothing stranded");
    }

    /* WHAT THE MISSING AUTHENTICATION DOES AND DOES NOT COST */

    /// @dev The callbacks are open. This is only acceptable because the contract is empty at rest —
    ///      a direct callback can run calls, but there is nothing here for them to take.
    function test_Callback_IsOpenButFindsNothingToTake() public {
        IRouter.Call[] memory calls = new IRouter.Call[](1);
        calls[0] = IRouter.Call({target: address(token), data: abi.encodeCall(IERC20.transfer, (attacker, 1e18))});

        vm.prank(attacker);
        vm.expectRevert(); // no balance to transfer
        IFlashLoanMorphoCallback(address(capability)).onMorphoFlashLoan(0, abi.encode(calls));

        assertEq(token.balanceOf(attacker), 0, "nothing extracted");
    }

    /// @dev The relayer answers only to its router, so this second arbitrary-call surface is not a
    ///      route to anyone's allowances.
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
        IFlashLoanMorphoCallback(address(capability)).onMorphoFlashLoan(0, abi.encode(calls));

        assertEq(token.balanceOf(victim), 500e18, "victim untouched");
    }

    /* HELPERS */

    function _request(
        IFlashLoanCapability.Provider providerType,
        address provider,
        uint256 amount,
        uint256 spend,
        uint256 returned
    ) internal view returns (bytes memory) {
        return abi.encode(
            providerType, provider, address(token), amount, abi.encode(_useAndRepay(spend, returned, provider))
        );
    }

    /// @dev Spend the principal, take `returned` back, then repay the lender the way it expects.
    function _useAndRepay(uint256 spend, uint256 returned, address provider)
        internal
        view
        returns (IRouter.Call[] memory calls)
    {
        calls = new IRouter.Call[](3);
        calls[0] = IRouter.Call({target: address(token), data: abi.encodeCall(IERC20.transfer, (address(sink), spend))});
        calls[1] = IRouter.Call({target: address(sink), data: abi.encodeCall(MockSink.giveBack, (returned))});
        // Both mock lenders pull, so the repayment leg is an approval.
        calls[2] =
            IRouter.Call({target: address(token), data: abi.encodeCall(IERC20.approve, (provider, type(uint256).max))});
    }
}

contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockSink {
    using SafeERC20 for IERC20;

    IERC20 internal immutable TOKEN;
    uint256 public calls;

    constructor(MockERC20 token_) {
        TOKEN = IERC20(address(token_));
    }

    function giveBack(uint256 returned) external {
        ++calls;
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
