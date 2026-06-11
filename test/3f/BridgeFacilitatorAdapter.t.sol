// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BridgeFacilitatorAdapter} from "../../src/3f/BridgeFacilitatorAdapter.sol";

import {AdapterFactory} from "@symbioticfi/core/src/contracts/adapters/AdapterFactory.sol";
import {IAdapter} from "@symbioticfi/core/src/interfaces/adapters/IAdapter.sol";

import {IRequestCallback} from "grunt/src/interfaces/request/IRequestCallback.sol";
import {Offer} from "grunt/src/interfaces/request/IOfferReceiver.sol";
import {IWhitelist} from "3f-request-whitelist/src/IWhitelist.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

import {Test} from "forge-std/Test.sol";

/// @dev Plain ERC20 standing in for USDC (vault collateral / loan token).
contract TestERC20 is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Minimal IRegistry-style entity tracker for `Adapter._initialize`'s vault validation.
contract MockVaultFactory {
    mapping(address => bool) public isEntity;

    function setEntity(address vault, bool flag) external {
        isEntity[vault] = flag;
    }
}

/// @dev Settable RequestWhitelist stub, to exercise the not-attested / circuit-breaker reverts that the
///      always-attesting production `MockWhitelist` can't.
contract SettableWhitelist is IWhitelist {
    mapping(address => WhitelistStatus) internal _status;

    function set(address a, WhitelistStatus s) external {
        _status[a] = s;
    }

    function isWhitelisted(address a) external view returns (WhitelistStatus) {
        return _status[a];
    }
}

/// @dev VaultV2 stand-in: `asset()`, `delegator()`, and delegator-only `pull`/`recall`. Holds the idle
///      collateral the JIT pull draws from; `recall` relies on the max approval set in `Adapter._initialize`.
contract MockVaultV2 {
    TestERC20 public collateral;
    address public delegator;

    constructor(TestERC20 collateral_) {
        collateral = collateral_;
    }

    function setDelegator(address delegator_) external {
        delegator = delegator_;
    }

    function asset() external view returns (address) {
        return address(collateral);
    }

    function pull(address to, uint256 amount) external {
        require(msg.sender == delegator, "only delegator");
        collateral.transfer(to, amount);
    }

    function recall(address from, uint256 amount) external {
        require(msg.sender == delegator, "only delegator");
        collateral.transferFrom(from, address(this), amount);
    }
}

/// @dev UniversalDelegator stand-in replicating `allocateExact`'s clamp/pull semantics (cap by
///      `limitOf - totalAssets`, vault free balance, `allocatable()`) and the `deallocate` recall path.
///      As the registered delegator it is the only authorized caller of the adapter's `onlyDelegator` hooks.
contract MockDelegator {
    MockVaultV2 public vault;
    mapping(address => uint256) public limit;

    constructor(MockVaultV2 vault_) {
        vault = vault_;
    }

    function setLimit(address adapter, uint256 newLimit) external {
        limit[adapter] = newLimit;
    }

    function limitOf(address adapter) external view returns (uint256) {
        return limit[adapter];
    }

    function allocateExact(address adapter, uint256 assets) external returns (uint256 allocated) {
        uint256 totalAssets_ = IAdapter(adapter).totalAssets();
        uint256 cap = limit[adapter] > totalAssets_ ? limit[adapter] - totalAssets_ : 0;
        if (assets > cap) assets = cap;
        uint256 free = vault.collateral().balanceOf(address(vault));
        if (assets > free) assets = free;
        uint256 allocatable_ = IAdapter(adapter).allocatable();
        if (assets > allocatable_) assets = allocatable_;
        if (assets == 0) return 0;

        vault.pull(adapter, assets);
        allocated = IAdapter(adapter).allocate(assets);
    }

    function deallocate(address adapter, uint256 amount) external returns (uint256 deallocated) {
        deallocated = IAdapter(adapter).deallocate(amount);
        if (deallocated > 0) {
            vault.recall(adapter, deallocated);
        }
    }
}

/// @dev 3F Request stand-in. `consume()` emulates pull-mode (maker callback, then pull `principal`);
///      `burnAll()` returns principal + yield, simulating Facility repayment. PT/YT issuance is elided.
contract MockRequest {
    TestERC20 public assetToken;
    bool public canWithdraw;
    uint256 public pAssets; // principal returned on burnAll (can be < principal on a loss)
    uint256 public yAssets; // yield returned on burnAll

    constructor(TestERC20 assetToken_) {
        assetToken = assetToken_;
    }

    function asset() external view returns (address) {
        return address(assetToken);
    }

    function setCanWithdraw(bool v) external {
        canWithdraw = v;
    }

    function consume(address adapter, uint256 principal, uint256 yield) external {
        Offer memory o = Offer({
            maker: adapter,
            amount: principal,
            expectedReturn: yield,
            nonce: 1,
            expiration: type(uint256).max,
            useCallback: true
        });
        IRequestCallback(adapter).onRequestConsumed(o, "", principal, yield);
        assetToken.transferFrom(adapter, address(this), principal);
    }

    function fundRedemption(uint256 pAssets_, uint256 yAssets_) external {
        pAssets = pAssets_;
        yAssets = yAssets_;
    }

    function burnAll(address, address receiver) external returns (uint256, uint256, uint256, uint256) {
        uint256 p = pAssets;
        uint256 y = yAssets;
        pAssets = 0;
        yAssets = 0;
        assetToken.transfer(receiver, p + y);
        return (0, 0, p, y);
    }
}

contract BridgeFacilitatorAdapterTest is Test {
    TestERC20 internal usdc;
    MockVaultFactory internal vaultFactory;
    SettableWhitelist internal whitelist;
    MockVaultV2 internal vault;
    MockDelegator internal delegator;
    MockRequest internal request;
    AdapterFactory internal adapterFactory;
    BridgeFacilitatorAdapter internal adapter;

    uint256 internal constant SIGNER_PK = 0xB0B;
    address internal signer;

    uint256 internal constant PRINCIPAL = 100_000e6;
    uint256 internal constant YIELD = 2_000e6;
    uint256 internal constant VAULT_LIQUIDITY = 10_000_000e6;

    function setUp() public {
        signer = vm.addr(SIGNER_PK);

        usdc = new TestERC20();
        vaultFactory = new MockVaultFactory();
        whitelist = new SettableWhitelist();
        vault = new MockVaultV2(usdc);
        delegator = new MockDelegator(vault);
        vault.setDelegator(address(delegator));
        request = new MockRequest(usdc);

        // Deploy through the real AdapterFactory proxy flow: the impl disables initializers in its
        // constructor, so it can only be initialized behind a factory-created proxy.
        adapterFactory = new AdapterFactory(address(this));
        BridgeFacilitatorAdapter impl =
            new BridgeFacilitatorAdapter(address(whitelist), address(vaultFactory), address(adapterFactory));
        adapterFactory.whitelist(address(impl));

        vaultFactory.setEntity(address(vault), true);
        adapter = BridgeFacilitatorAdapter(
            adapterFactory.create(1, address(this), abi.encode(address(vault), bytes("")))
        );

        adapter.setOfferSigner(signer);
        whitelist.set(address(request), IWhitelist.WhitelistStatus.Whitelisted);

        // Curator setup: per-adapter cap + the vault's idle liquidity the JIT pull draws from.
        delegator.setLimit(address(adapter), type(uint256).max);
        usdc.mint(address(vault), VAULT_LIQUIDITY);
    }

    /* ---------------------------------------------------------------------- */
    /*                          onRequestConsumed (JIT)                       */
    /* ---------------------------------------------------------------------- */

    function test_consume_happyPath_pullsPrincipalJustInTime() public {
        request.consume(address(adapter), PRINCIPAL, YIELD);

        // Principal moved vault -> adapter (JIT) -> request; adapter holds no idle balance after.
        assertEq(usdc.balanceOf(address(request)), PRINCIPAL, "request holds principal");
        assertEq(usdc.balanceOf(address(vault)), VAULT_LIQUIDITY - PRINCIPAL, "vault funded the principal");
        assertEq(usdc.balanceOf(address(adapter)), 0, "adapter holds no standing collateral");
        assertEq(adapter.outstandingPrincipal(), PRINCIPAL, "outstanding principal tracked");
        assertEq(adapter.totalAssets(), PRINCIPAL, "totalAssets = locked principal");

        (uint128 p, uint128 yt, uint48 openedAt, bool redeemed) = adapter.positions(address(request));
        assertEq(p, uint128(PRINCIPAL));
        assertEq(yt, uint128(YIELD));
        assertEq(openedAt, uint48(block.timestamp));
        assertFalse(redeemed);

        address[] memory active = adapter.activeRequests();
        assertEq(active.length, 1);
        assertEq(active[0], address(request));
    }

    function test_consume_spendsIdleBalanceBeforePulling() public {
        // Idle realized balance should be spent first; only the shortfall pulled from the vault.
        uint256 idle = 30_000e6;
        usdc.mint(address(adapter), idle);

        request.consume(address(adapter), PRINCIPAL, YIELD);

        assertEq(usdc.balanceOf(address(request)), PRINCIPAL, "request holds principal");
        assertEq(usdc.balanceOf(address(vault)), VAULT_LIQUIDITY - (PRINCIPAL - idle), "vault funded only the shortfall");
        assertEq(usdc.balanceOf(address(adapter)), 0, "idle balance fully spent");
    }

    function test_consume_revertsWhenNotAttested() public {
        whitelist.set(address(request), IWhitelist.WhitelistStatus.NotWhitelisted);
        vm.expectRevert(BridgeFacilitatorAdapter.NotAttested.selector);
        request.consume(address(adapter), PRINCIPAL, YIELD);
    }

    function test_consume_revertsWhenPausedWhitelisted() public {
        // Circuit breaker active: even a previously-attested request must be rejected.
        whitelist.set(address(request), IWhitelist.WhitelistStatus.PausedWhitelisted);
        vm.expectRevert(BridgeFacilitatorAdapter.NotAttested.selector);
        request.consume(address(adapter), PRINCIPAL, YIELD);
    }

    function test_consume_revertsOnAssetMismatch() public {
        MockRequest other = new MockRequest(new TestERC20()); // different asset
        whitelist.set(address(other), IWhitelist.WhitelistStatus.Whitelisted);
        vm.expectRevert(BridgeFacilitatorAdapter.AssetMismatch.selector);
        other.consume(address(adapter), PRINCIPAL, YIELD);
    }

    function test_consume_revertsWhenVaultLiquidityDry() public {
        // Drain the vault's idle liquidity below the principal: the JIT pull comes up short.
        vm.prank(address(delegator));
        vault.pull(address(0xdead), VAULT_LIQUIDITY);
        vm.expectRevert(BridgeFacilitatorAdapter.InsufficientLiquidity.selector);
        request.consume(address(adapter), PRINCIPAL, YIELD);
    }

    function test_consume_revertsWhenCapExceeded() public {
        // Per-adapter cap below the principal: the JIT pull is clamped under the requested amount.
        delegator.setLimit(address(adapter), PRINCIPAL - 1);
        vm.expectRevert(BridgeFacilitatorAdapter.InsufficientLiquidity.selector);
        request.consume(address(adapter), PRINCIPAL, YIELD);
    }

    /* ---------------------------------------------------------------------- */
    /*                          exposure limits                               */
    /* ---------------------------------------------------------------------- */

    function test_setExposureLimits_onlyOwner() public {
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert();
        adapter.setExposureLimits(1, 2, 3, 4);
    }

    function test_setExposureLimits_storesValues() public {
        adapter.setExposureLimits(PRINCIPAL, 5 * PRINCIPAL, 100, 10);
        assertEq(adapter.perRequestMaxCollateral(), PRINCIPAL);
        assertEq(adapter.totalMaxCollateral(), 5 * PRINCIPAL);
        assertEq(adapter.minRequestYieldBps(), 100);
        assertEq(adapter.maxConcurrentLoans(), 10);
    }

    function test_consume_withinExposureLimits_succeeds() public {
        // YIELD/PRINCIPAL = 2_000/100_000 = 200 bps, above the 100 bps floor.
        adapter.setExposureLimits(PRINCIPAL, 5 * PRINCIPAL, 100, 10);
        request.consume(address(adapter), PRINCIPAL, YIELD);
        assertEq(adapter.outstandingPrincipal(), PRINCIPAL);
    }

    function test_consume_revertsWhenPerRequestCapExceeded() public {
        adapter.setExposureLimits(PRINCIPAL - 1, 0, 0, 0);
        vm.expectRevert(BridgeFacilitatorAdapter.PerRequestCapExceeded.selector);
        request.consume(address(adapter), PRINCIPAL, YIELD);
    }

    function test_consume_revertsWhenSleeveCapExceeded() public {
        // One loan already open; a second would push outstanding past the total cap.
        adapter.setExposureLimits(0, PRINCIPAL + (PRINCIPAL / 2), 0, 0);
        request.consume(address(adapter), PRINCIPAL, YIELD);
        MockRequest second = new MockRequest(usdc);
        whitelist.set(address(second), IWhitelist.WhitelistStatus.Whitelisted);
        vm.expectRevert(BridgeFacilitatorAdapter.SleeveCapExceeded.selector);
        second.consume(address(adapter), PRINCIPAL, YIELD);
    }

    function test_consume_revertsWhenTooManyConcurrentLoans() public {
        adapter.setExposureLimits(0, 0, 0, 1); // at most one open loan
        request.consume(address(adapter), PRINCIPAL, YIELD);
        MockRequest second = new MockRequest(usdc);
        whitelist.set(address(second), IWhitelist.WhitelistStatus.Whitelisted);
        vm.expectRevert(BridgeFacilitatorAdapter.TooManyConcurrentLoans.selector);
        second.consume(address(adapter), PRINCIPAL, YIELD);
    }

    function test_consume_revertsWhenYieldTooLow() public {
        // Require 300 bps; the offer's 200 bps (YIELD/PRINCIPAL) is below it.
        adapter.setExposureLimits(0, 0, 300, 0);
        vm.expectRevert(BridgeFacilitatorAdapter.YieldTooLow.selector);
        request.consume(address(adapter), PRINCIPAL, YIELD);
    }

    function test_consume_yieldExactlyAtFloor_succeeds() public {
        adapter.setExposureLimits(0, 0, 200, 0); // floor == offer's 200 bps
        request.consume(address(adapter), PRINCIPAL, YIELD);
        assertEq(adapter.outstandingPrincipal(), PRINCIPAL);
    }

    /* ---------------------------------------------------------------------- */
    /*                          allocatable gating                            */
    /* ---------------------------------------------------------------------- */

    function test_allocatable_zeroOutsideConsume() public view {
        assertEq(adapter.allocatable(), 0, "no standing allocation outside a consume");
    }

    /* ---------------------------------------------------------------------- */
    /*                               redeem                                   */
    /* ---------------------------------------------------------------------- */

    function _openPosition() internal {
        request.consume(address(adapter), PRINCIPAL, YIELD);
    }

    function test_redeem_skipsUnknownRequest() public {
        address[] memory reqs = new address[](1);
        reqs[0] = makeAddr("strangerRequest");
        adapter.redeem(reqs); // no revert, no state change
        assertEq(adapter.realizedPrincipal(), 0);
    }

    function test_redeem_skipsNotReady() public {
        _openPosition();
        request.setCanWithdraw(false);
        address[] memory reqs = new address[](1);
        reqs[0] = address(request);
        adapter.redeem(reqs);
        assertEq(adapter.realizedPrincipal(), 0, "nothing realized while not withdrawable");
        assertEq(adapter.activeRequests().length, 1, "still active");
    }

    function test_redeem_realizesReadyPosition() public {
        _openPosition();
        request.fundRedemption(PRINCIPAL, YIELD);
        usdc.mint(address(request), YIELD); // Facility tops up the yield (principal already pulled)
        request.setCanWithdraw(true);

        address[] memory reqs = new address[](1);
        reqs[0] = address(request);
        adapter.redeem(reqs);

        assertEq(adapter.realizedPrincipal(), PRINCIPAL, "principal realized");
        assertEq(adapter.outstandingPrincipal(), 0, "outstanding cleared");
        assertEq(usdc.balanceOf(address(adapter)), PRINCIPAL + YIELD, "adapter holds principal + yield");
        assertEq(adapter.activeRequests().length, 0, "removed from active set");
        (,,, bool redeemed) = adapter.positions(address(request));
        assertTrue(redeemed);
    }

    function test_redeem_lossScenarioRealizesLessThanPrincipal() public {
        _openPosition();
        uint256 recovered = PRINCIPAL - 10_000e6; // less than fronted principal
        request.fundRedemption(recovered, 0);
        request.setCanWithdraw(true);

        address[] memory reqs = new address[](1);
        reqs[0] = address(request);
        adapter.redeem(reqs);

        assertEq(adapter.realizedPrincipal(), recovered, "realized principal reflects the loss");
        assertEq(adapter.outstandingPrincipal(), 0, "offer-time principal retired from outstanding");
        assertEq(usdc.balanceOf(address(adapter)), recovered);
    }

    /* ---------------------------------------------------------------------- */
    /*                              deallocate                                */
    /* ---------------------------------------------------------------------- */

    function test_deallocate_recallsRealizedBalanceToVault() public {
        _openPosition();
        request.fundRedemption(PRINCIPAL, YIELD);
        usdc.mint(address(request), YIELD);
        request.setCanWithdraw(true);
        address[] memory reqs = new address[](1);
        reqs[0] = address(request);
        adapter.redeem(reqs);

        uint256 vaultBefore = usdc.balanceOf(address(vault));
        uint256 pulled = delegator.deallocate(address(adapter), PRINCIPAL);

        // Base `deallocate` recalls the entire free balance (principal + yield); override floors `realizedPrincipal` at 0.
        assertEq(pulled, PRINCIPAL + YIELD, "delegator recalled the full realized balance");
        assertEq(usdc.balanceOf(address(vault)) - vaultBefore, PRINCIPAL + YIELD, "vault recovered principal + yield");
        assertEq(adapter.realizedPrincipal(), 0);
        assertEq(usdc.balanceOf(address(adapter)), 0, "nothing left idle in the adapter");
    }

    function test_deallocate_onlyDelegator() public {
        _openPosition();
        vm.prank(makeAddr("notDelegator"));
        vm.expectRevert(IAdapter.NotVault.selector);
        adapter.deallocate(PRINCIPAL);
    }

    /* ---------------------------------------------------------------------- */
    /*                              EIP-1271                                  */
    /* ---------------------------------------------------------------------- */

    function test_isValidSignature_acceptsOfferSigner() public view {
        bytes32 digest = keccak256("some offer digest");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, digest);
        bytes memory sig = abi.encodePacked(r, s, v);
        assertEq(adapter.isValidSignature(digest, sig), IERC1271.isValidSignature.selector);
    }

    function test_isValidSignature_rejectsOtherSigner() public view {
        bytes32 digest = keccak256("some offer digest");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xDEAD, digest); // not the offer signer
        bytes memory sig = abi.encodePacked(r, s, v);
        assertEq(adapter.isValidSignature(digest, sig), bytes4(0xffffffff));
    }

    function test_isValidSignature_rejectsWhenSignerUnset() public {
        adapter.setOfferSigner(address(0));
        bytes32 digest = keccak256("some offer digest");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, digest);
        bytes memory sig = abi.encodePacked(r, s, v);
        assertEq(adapter.isValidSignature(digest, sig), bytes4(0xffffffff));
    }

    /* ---------------------------------------------------------------------- */
    /*                         owner-gated config                             */
    /* ---------------------------------------------------------------------- */

    function test_setOfferSigner_onlyOwner() public {
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert();
        adapter.setOfferSigner(makeAddr("x"));
    }
}
