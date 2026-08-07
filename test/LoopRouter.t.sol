// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.28;

import {LoopRouter} from "../src/LoopRouter.sol";
import {ILoopRouter} from "../src/interfaces/ILoopRouter.sol";
import {IMorphoFlashLoanCallback} from "../src/interfaces/IMorphoBlue.sol";
import {MarketParams} from "../src/oev/interfaces/IMorpho.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Test} from "forge-std/Test.sol";

contract LoopRouterTest is Test {
    address internal user = makeAddr("user");
    address internal attacker = makeAddr("attacker");
    address internal owner = makeAddr("owner");

    MockERC20 internal loanToken;
    MockERC20 internal collateral;
    MockERC20 internal vaultAsset;
    MockMorpho internal morpho;
    MockAdapter internal adapter;
    MockAdapterFactory internal factory;
    MockVenue internal venue;
    LoopRouter internal router;

    MarketParams internal market;

    function setUp() public {
        loanToken = new MockERC20("USDC", "USDC");
        collateral = new MockERC20("mF-ONE", "mF-ONE");
        vaultAsset = new MockERC20("USDC-vault", "USDCv");

        morpho = new MockMorpho();
        factory = new MockAdapterFactory();
        adapter = new MockAdapter();
        factory.setEntity(address(adapter), true);
        venue = new MockVenue();

        router = new LoopRouter(address(morpho), address(factory), owner);
        vm.prank(owner);
        router.setVenue(address(venue), true);

        market = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateral),
            oracle: makeAddr("oracle"),
            irm: makeAddr("irm"),
            lltv: 0.92e18
        });

        loanToken.mint(address(morpho), 1_000_000e18);
        collateral.mint(address(venue), 1_000_000e18);
        loanToken.mint(address(adapter), 1_000_000e18);
        vaultAsset.mint(address(adapter), 1_000_000e18);
    }

    /* LOOP */

    function test_Loop_SuppliesAcquiredCollateralAndDrawsDebt() public {
        collateral.mint(user, 100e18);
        vm.prank(user);
        collateral.approve(address(router), type(uint256).max);

        // Venue converts 400 loanToken into 400 collateral at 1:1.
        venue.setRate(1e18);

        vm.prank(user);
        router.loop(_loopParams(100e18, 400e18, 400e18));

        assertEq(morpho.collateralOf(user), 500e18, "collateral supplied for the caller");
        assertEq(morpho.debtOf(user), 400e18, "debt drawn equals the flash loan");
        assertEq(collateral.balanceOf(address(router)), 0, "no collateral stranded");
        assertEq(loanToken.balanceOf(address(router)), 0, "no loan token stranded");
    }

    function test_Loop_RevertsWhenAcquiredBelowFloor() public {
        venue.setRate(0.5e18); // only 200 collateral for 400 loanToken

        vm.prank(user);
        vm.expectRevert(ILoopRouter.InsufficientAcquired.selector);
        router.loop(_loopParams(0, 400e18, 400e18));
    }

    function test_Loop_RevertsForUnallowlistedVenue() public {
        MockVenue rogue = new MockVenue();
        ILoopRouter.LoopParams memory params = _loopParams(0, 400e18, 0);
        params.acquire.target = address(rogue);

        vm.prank(user);
        vm.expectRevert(ILoopRouter.InvalidVenue.selector);
        router.loop(params);
    }

    function test_Loop_RevertsAfterDeadline() public {
        ILoopRouter.LoopParams memory params = _loopParams(0, 400e18, 0);
        params.deadline = block.timestamp - 1;

        vm.prank(user);
        vm.expectRevert(ILoopRouter.Expired.selector);
        router.loop(params);
    }

    /// @dev The core invariant: an attacker cannot lever a position that is not their own, even though
    ///      every user authorizes this router on Morpho.
    function test_Loop_CannotActOnAnotherUsersPosition() public {
        venue.setRate(1e18);
        morpho.setAuthorized(user, address(router), true);

        vm.prank(attacker);
        router.loop(_loopParams(0, 400e18, 400e18));

        assertEq(morpho.collateralOf(user), 0, "victim position untouched");
        assertEq(morpho.debtOf(user), 0, "no debt drawn against the victim");
        assertEq(morpho.collateralOf(attacker), 400e18, "attacker levered only themselves");
    }

    /* UNLOOP */

    function test_Unloop_RepaysWithdrawsAndRedeems() public {
        _seedPosition(user, 500e18, 400e18);

        // Asset-matched market: the adapter pays the loan token directly, no settle leg.
        adapter.setPayout(address(loanToken), 420e18);

        vm.prank(user);
        router.unloop(_unloopParams(400e18, 500e18, address(loanToken), 400e18, address(0)));

        assertEq(morpho.debtOf(user), 0, "debt cleared");
        assertEq(morpho.collateralOf(user), 0, "collateral withdrawn");
        assertEq(loanToken.balanceOf(user), 20e18, "surplus swept to the caller");
        assertEq(loanToken.balanceOf(address(router)), 0, "nothing stranded");
    }

    function test_Unloop_CrossAssetUsesSettleVenue() public {
        _seedPosition(user, 500e18, 400e18);

        // PRIME-style: adapter pays the vault asset, which is not the loan token.
        adapter.setPayout(address(vaultAsset), 420e18);
        venue.setSettle(address(vaultAsset), address(loanToken), 1e18);
        loanToken.mint(address(venue), 1_000_000e18);

        vm.prank(user);
        router.unloop(_unloopParams(400e18, 500e18, address(vaultAsset), 400e18, address(venue)));

        assertEq(morpho.debtOf(user), 0, "debt cleared");
        assertEq(loanToken.balanceOf(user), 20e18, "surplus swept in the loan token");
        assertEq(vaultAsset.balanceOf(address(router)), 0, "redeem asset fully settled");
    }

    function test_Unloop_RevertsForUnregisteredAdapter() public {
        _seedPosition(user, 500e18, 400e18);
        ILoopRouter.UnloopParams memory params = _unloopParams(400e18, 500e18, address(loanToken), 0, address(0));
        params.adapter = address(new MockAdapter());

        vm.prank(user);
        vm.expectRevert(ILoopRouter.InvalidAdapter.selector);
        router.unloop(params);
    }

    function test_Unloop_RevertsWhenRedeemBelowFloor() public {
        _seedPosition(user, 500e18, 400e18);
        adapter.setPayout(address(loanToken), 100e18);

        vm.prank(user);
        vm.expectRevert(ILoopRouter.InsufficientRedeemed.selector);
        router.unloop(_unloopParams(400e18, 500e18, address(loanToken), 400e18, address(0)));
    }

    function test_Unloop_RevertsWhenRedeemCannotCoverFlashLoan() public {
        _seedPosition(user, 500e18, 400e18);
        adapter.setPayout(address(loanToken), 300e18);

        vm.prank(user);
        vm.expectRevert(ILoopRouter.InsufficientRepayment.selector);
        router.unloop(_unloopParams(400e18, 500e18, address(loanToken), 0, address(0)));
    }

    /* CALLBACK AUTHENTICATION */

    function test_Callback_RevertsForNonMorphoCaller() public {
        vm.prank(attacker);
        vm.expectRevert(ILoopRouter.NotMorpho.selector);
        IMorphoFlashLoanCallback(address(router)).onMorphoFlashLoan(1e18, "");
    }

    function test_Callback_RevertsWithoutAnInFlightLoan() public {
        vm.prank(address(morpho));
        vm.expectRevert(ILoopRouter.UnexpectedCallback.selector);
        IMorphoFlashLoanCallback(address(router)).onMorphoFlashLoan(1e18, abi.encode(uint8(0), attacker));
    }

    /* OWNERSHIP */

    function test_SetVenue_OnlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        router.setVenue(address(0xBEEF), true);

        vm.prank(owner);
        router.setVenue(address(0xBEEF), true);
        assertTrue(router.isVenue(address(0xBEEF)));
    }

    /* HELPERS */

    function _loopParams(uint256 seed, uint256 flashAmount, uint256 minAcquired)
        internal
        view
        returns (ILoopRouter.LoopParams memory)
    {
        return ILoopRouter.LoopParams({
            market: market,
            seedCollateral: seed,
            flashLoanAmount: flashAmount,
            acquire: ILoopRouter.VenueCall({
                target: address(venue),
                data: abi.encodeCall(MockVenue.acquire, (address(loanToken), address(collateral), flashAmount))
            }),
            minCollateralAcquired: minAcquired,
            deadline: block.timestamp + 1 hours
        });
    }

    function _unloopParams(
        uint256 repay,
        uint256 withdraw,
        address redeemAsset,
        uint256 minRedeemed,
        address settleTarget
    ) internal view returns (ILoopRouter.UnloopParams memory) {
        return ILoopRouter.UnloopParams({
            market: market,
            repayAssets: repay,
            withdrawCollateral: withdraw,
            adapter: address(adapter),
            redeemData: abi.encodeCall(MockAdapter.redeem, (address(router))),
            redeemAsset: redeemAsset,
            minRedeemed: minRedeemed,
            settle: ILoopRouter.VenueCall({
                target: settleTarget,
                data: settleTarget == address(0)
                    ? bytes("")
                    : abi.encodeCall(MockVenue.settle, (address(vaultAsset), address(loanToken)))
            }),
            deadline: block.timestamp + 1 hours
        });
    }

    function _seedPosition(address account, uint256 collateralAmount, uint256 debt) internal {
        morpho.seed(account, collateralAmount, debt);
        collateral.mint(address(morpho), collateralAmount);
    }
}

/* MOCKS */

contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockAdapterFactory {
    mapping(address => bool) internal _entities;

    function setEntity(address entity, bool value) external {
        _entities[entity] = value;
    }

    function isEntity(address entity) external view returns (bool) {
        return _entities[entity];
    }
}

/// @dev Stands in for LiquidLaneAdapter: consumes whatever collateral was pushed to it and pays the
///      configured asset to the recipient named in the (mock) signed calldata.
contract MockAdapter {
    using SafeERC20 for IERC20;

    address internal _payoutToken;
    uint256 internal _payoutAmount;

    function setPayout(address token, uint256 amount) external {
        _payoutToken = token;
        _payoutAmount = amount;
    }

    function redeem(address recipient) external {
        IERC20(_payoutToken).safeTransfer(recipient, _payoutAmount);
    }
}

/// @dev Stands in for a DEX router or a Midas deposit vault.
contract MockVenue {
    using SafeERC20 for IERC20;

    uint256 internal _rate = 1e18;
    address internal _settleIn;
    address internal _settleOut;
    uint256 internal _settleRate = 1e18;

    function setRate(uint256 rate) external {
        _rate = rate;
    }

    function setSettle(address tokenIn, address tokenOut, uint256 rate) external {
        _settleIn = tokenIn;
        _settleOut = tokenOut;
        _settleRate = rate;
    }

    function acquire(address tokenIn, address tokenOut, uint256 amountIn) external {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(msg.sender, amountIn * _rate / 1e18);
    }

    function settle(address tokenIn, address tokenOut) external {
        uint256 amountIn = IERC20(tokenIn).allowance(msg.sender, address(this));
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(msg.sender, amountIn * _settleRate / 1e18);
    }
}

/// @dev Minimal Morpho Blue: fee-free flash loans plus per-account collateral and debt.
contract MockMorpho {
    using SafeERC20 for IERC20;

    mapping(address => uint256) public collateralOf;
    mapping(address => uint256) public debtOf;
    mapping(address => mapping(address => bool)) public isAuthorized;

    function setAuthorized(address authorizer, address authorized, bool value) external {
        isAuthorized[authorizer][authorized] = value;
    }

    function seed(address account, uint256 collateralAmount, uint256 debt) external {
        collateralOf[account] = collateralAmount;
        debtOf[account] = debt;
    }

    function flashLoan(address token, uint256 assets, bytes calldata data) external {
        IERC20(token).safeTransfer(msg.sender, assets);
        IMorphoFlashLoanCallback(msg.sender).onMorphoFlashLoan(assets, data);
        IERC20(token).safeTransferFrom(msg.sender, address(this), assets);
    }

    function supplyCollateral(MarketParams memory p, uint256 assets, address onBehalf, bytes calldata) external {
        IERC20(p.collateralToken).safeTransferFrom(msg.sender, address(this), assets);
        collateralOf[onBehalf] += assets;
    }

    function withdrawCollateral(MarketParams memory p, uint256 assets, address onBehalf, address receiver) external {
        collateralOf[onBehalf] -= assets;
        IERC20(p.collateralToken).safeTransfer(receiver, assets);
    }

    function borrow(MarketParams memory p, uint256 assets, uint256, address onBehalf, address receiver)
        external
        returns (uint256, uint256)
    {
        debtOf[onBehalf] += assets;
        IERC20(p.loanToken).safeTransfer(receiver, assets);
        return (assets, assets);
    }

    function repay(MarketParams memory p, uint256 assets, uint256, address onBehalf, bytes calldata)
        external
        returns (uint256, uint256)
    {
        debtOf[onBehalf] -= assets;
        IERC20(p.loanToken).safeTransferFrom(msg.sender, address(this), assets);
        return (assets, assets);
    }
}
