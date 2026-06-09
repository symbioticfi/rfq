// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BridgeFacilitatorAdapter} from "../../src/3f/BridgeFacilitatorAdapter.sol";

import {IAdapter} from "@symbioticfi/core/src/interfaces/vault/adapters/IAdapter.sol";

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

/// @dev Minimal IRegistry-style entity tracker for `Adapter._validateVault`.
contract MockVaultFactory {
    mapping(address => bool) public isEntity;

    function setEntity(address vault, bool flag) external {
        isEntity[vault] = flag;
    }
}

/// @dev Curator registry stub (only needed if the recover() path is exercised).
contract MockCuratorRegistry {
    mapping(address => address) internal _curator;

    function setCurator(address vault, address curator) external {
        _curator[vault] = curator;
    }

    function getCurator(address vault) external view returns (address) {
        return _curator[vault];
    }
}

/// @dev Receives donation rewards; pulls the approved collateral, mirroring the real Rewards contract.
///      `msg.sender` is the adapter (it approves this contract before calling).
contract MockRewards {
    IERC20 public token;
    uint256 public totalDistributed;

    constructor(IERC20 token_) {
        token = token_;
    }

    function distributeDonationRewards(address, uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        totalDistributed += amount;
    }
}

/// @dev Settable 3F RequestWhitelist stub.
contract MockWhitelist is IWhitelist {
    mapping(address => WhitelistStatus) internal _status;

    function set(address a, WhitelistStatus s) external {
        _status[a] = s;
    }

    function isWhitelisted(address a) external view returns (WhitelistStatus) {
        return _status[a];
    }
}

/// @dev Faithful VaultV2 stand-in: replicates the exact `_allocateAdapter` / `deallocateAdapter`
///      semantics read from core-mirror VaultV2.sol — min-caps (incl. `adapter.allocatable(this)`),
///      the callback into `adapter.allocate()`, and `adapterAllocated` tracking.
contract MockVaultV2 {
    TestERC20 public collateral;
    mapping(address => uint256) public adapterLimit;
    mapping(address => uint256) public adapterAllocated;

    constructor(TestERC20 collateral_) {
        collateral = collateral_;
    }

    function setAdapterLimit(address adapter, uint256 limit) external {
        adapterLimit[adapter] = limit;
    }

    /// @dev Idle collateral available to allocate (the vault's free balance).
    function allocatable() public view returns (uint256) {
        return collateral.balanceOf(address(this));
    }

    function allocateAdapter(address adapter, uint256 amount) external returns (uint256 allocated) {
        uint256 limitRoom = adapterLimit[adapter] - adapterAllocated[adapter];
        allocated = _min(_min(_min(amount, limitRoom), allocatable()), IAdapter(adapter).allocatable(address(this)));
        if (allocated > 0) {
            adapterAllocated[adapter] += allocated;
            collateral.transfer(adapter, allocated);
            IAdapter(adapter).allocate(allocated);
        }
    }

    function deallocateAdapter(address adapter, uint256 amount) external returns (uint256 deallocated) {
        deallocated = IAdapter(adapter).deallocate(amount);
        if (deallocated > 0) {
            adapterAllocated[adapter] -= deallocated;
            collateral.transferFrom(adapter, address(this), deallocated);
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

/// @dev 3F Request stand-in. Emulates `consume()` (callback then principal pull) and `burnAll()`
///      (returns principal + yield to the receiver). PT/YT issuance is elided; the test funds the
///      request with the yield to simulate the Facility's repayment.
contract MockRequest {
    TestERC20 public assetToken;
    bool public canWithdraw;
    uint256 public pAssets; // principal returned on burnAll (can be < principal for a loss)
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

    /// @dev Emulates grunt Request.consume: invoke the maker callback, then pull `principal`.
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

    /// @dev Configure the redemption payout, simulating Facility repayment of principal (+yield).
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
    MockCuratorRegistry internal curatorRegistry;
    MockRewards internal rewards;
    MockWhitelist internal whitelist;
    MockVaultV2 internal vault;
    MockRequest internal request;
    BridgeFacilitatorAdapter internal adapter;

    uint256 internal constant SIGNER_PK = 0xB0B;
    address internal signer;

    uint128 internal constant MAX_PRINCIPAL = 1_000_000e6;
    uint128 internal constant MIN_YIELD = 1_000e6;
    uint256 internal constant PRINCIPAL = 100_000e6;
    uint256 internal constant YIELD = 2_000e6;

    function setUp() public {
        signer = vm.addr(SIGNER_PK);

        usdc = new TestERC20();
        vaultFactory = new MockVaultFactory();
        curatorRegistry = new MockCuratorRegistry();
        rewards = new MockRewards(usdc);
        whitelist = new MockWhitelist();
        vault = new MockVaultV2(usdc);
        request = new MockRequest(usdc);

        adapter = new BridgeFacilitatorAdapter(
            address(vault), address(rewards), address(whitelist), address(vaultFactory), address(curatorRegistry)
        );
        adapter.initialize(); // sets owner = address(this)

        vaultFactory.setEntity(address(vault), true);

        // Owner-side setup: adapter-wide limit + per-Request budget + offer signer.
        adapter.setGlobalLimit(address(usdc), type(uint256).max);
        whitelist.set(address(request), IWhitelist.WhitelistStatus.Whitelisted);
        adapter.setRequestMetadata(address(request), MAX_PRINCIPAL, MIN_YIELD);
        adapter.setOfferSigner(signer);

        // Vault-side setup: per-adapter limit + idle liquidity.
        vault.setAdapterLimit(address(adapter), type(uint256).max);
        usdc.mint(address(vault), 10_000_000e6);
    }

    /* ---------------------------------------------------------------------- */
    /*                          onRequestConsumed                             */
    /* ---------------------------------------------------------------------- */

    function test_consume_happyPath() public {
        request.consume(address(adapter), PRINCIPAL, YIELD);

        // Principal moved vault -> adapter -> request.
        assertEq(usdc.balanceOf(address(request)), PRINCIPAL, "request holds principal");
        assertEq(vault.adapterAllocated(address(adapter)), PRINCIPAL, "vault books principal to adapter");
        assertEq(adapter.globalAllocated(address(usdc)), PRINCIPAL, "adapter tracks global allocated");

        // Position registered.
        (uint128 p, uint128 yt, uint48 openedAt, bool redeemed) = adapter.positions(address(request));
        assertEq(p, uint128(PRINCIPAL));
        assertEq(yt, uint128(YIELD));
        assertEq(openedAt, uint48(block.timestamp));
        assertFalse(redeemed);

        address[] memory active = adapter.activeRequests();
        assertEq(active.length, 1);
        assertEq(active[0], address(request));

        // maxPrincipal decremented; minYield untouched.
        (uint128 maxP, uint128 minY) = adapter.requestMetadata(address(request));
        assertEq(maxP, MAX_PRINCIPAL - uint128(PRINCIPAL));
        assertEq(minY, MIN_YIELD);
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

    function test_consume_revertsOnZeroPrincipal() public {
        vm.expectRevert(BridgeFacilitatorAdapter.InsufficientPrincipalAllowance.selector);
        request.consume(address(adapter), 0, YIELD);
    }

    function test_consume_revertsWhenPrincipalExceedsBudget() public {
        vm.expectRevert(BridgeFacilitatorAdapter.InsufficientPrincipalAllowance.selector);
        request.consume(address(adapter), uint256(MAX_PRINCIPAL) + 1, YIELD);
    }

    function test_consume_revertsWhenYieldBelowFloor() public {
        vm.expectRevert(BridgeFacilitatorAdapter.YieldBelowFloor.selector);
        request.consume(address(adapter), PRINCIPAL, MIN_YIELD - 1);
    }

    function test_consume_revertsOnAssetMismatch() public {
        MockRequest other = new MockRequest(new TestERC20()); // different asset
        whitelist.set(address(other), IWhitelist.WhitelistStatus.Whitelisted);
        adapter.setRequestMetadata(address(other), MAX_PRINCIPAL, 0);
        vm.expectRevert(BridgeFacilitatorAdapter.AssetMismatch.selector);
        other.consume(address(adapter), PRINCIPAL, YIELD);
    }

    function test_consume_revertsWhenVaultCannotFund() public {
        // Drain the vault's idle liquidity below the principal.
        uint256 vaultBal = usdc.balanceOf(address(vault));
        vm.prank(address(vault));
        usdc.transfer(address(0xdead), vaultBal);
        vm.expectRevert(BridgeFacilitatorAdapter.InsufficientLiquidity.selector);
        request.consume(address(adapter), PRINCIPAL, YIELD);
    }

    function test_consume_cumulativeBudgetDecrementsAcrossConsumes() public {
        request.consume(address(adapter), PRINCIPAL, YIELD);
        request.fundRedemption(0, 0); // reset request balance bookkeeping (not redeemed yet)
        request.consume(address(adapter), PRINCIPAL, YIELD);
        (uint128 maxP,) = adapter.requestMetadata(address(request));
        assertEq(maxP, MAX_PRINCIPAL - 2 * uint128(PRINCIPAL));
    }

    /* ---------------------------------------------------------------------- */
    /*                          allocatable gating                            */
    /* ---------------------------------------------------------------------- */

    function test_allocatable_zeroOutsideConsume() public view {
        assertEq(adapter.allocatable(address(vault)), 0, "no standing allocation outside consume");
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
        assertEq(usdc.balanceOf(address(adapter)), PRINCIPAL + YIELD, "adapter holds principal + yield");
        assertEq(adapter.activeRequests().length, 0, "removed from active set");
        (,,, bool redeemed) = adapter.positions(address(request));
        assertTrue(redeemed);
    }

    function test_redeem_lossScenarioRealizesLessThanPrincipal() public {
        _openPosition();
        uint256 recovered = PRINCIPAL - 10_000e6; // default: less than fronted principal
        request.fundRedemption(recovered, 0);
        request.setCanWithdraw(true);

        address[] memory reqs = new address[](1);
        reqs[0] = address(request);
        adapter.redeem(reqs);

        assertEq(adapter.realizedPrincipal(), recovered, "realized principal reflects the loss");
        assertEq(usdc.balanceOf(address(adapter)), recovered);
    }

    /* ---------------------------------------------------------------------- */
    /*                       deallocatable / deallocate                       */
    /* ---------------------------------------------------------------------- */

    function test_deallocate_returnsRealizedPrincipalToVault() public {
        _openPosition();
        request.fundRedemption(PRINCIPAL, YIELD);
        usdc.mint(address(request), YIELD);
        request.setCanWithdraw(true);
        address[] memory reqs = new address[](1);
        reqs[0] = address(request);
        adapter.redeem(reqs);

        assertEq(adapter.deallocatable(address(vault)), PRINCIPAL);

        uint256 vaultBefore = usdc.balanceOf(address(vault));
        uint256 pulled = vault.deallocateAdapter(address(adapter), PRINCIPAL);

        assertEq(pulled, PRINCIPAL);
        assertEq(usdc.balanceOf(address(vault)) - vaultBefore, PRINCIPAL, "vault recovered principal");
        assertEq(adapter.realizedPrincipal(), 0);
        assertEq(adapter.globalAllocated(address(usdc)), 0);
        assertEq(usdc.balanceOf(address(adapter)), YIELD, "only yield remains in adapter");
    }

    function test_deallocatable_zeroWhileLoanOutstanding() public {
        _openPosition(); // consumed but not redeemed
        assertEq(adapter.deallocatable(address(vault)), 0, "locked principal is not recallable");
    }

    function test_foreignVaultCannotDrainOrSkim() public {
        // Realize some principal so there's something a foreign vault might try to take.
        _openPosition();
        request.fundRedemption(PRINCIPAL, YIELD);
        usdc.mint(address(request), YIELD);
        request.setCanWithdraw(true);
        address[] memory reqs = new address[](1);
        reqs[0] = address(request);
        adapter.redeem(reqs);
        assertEq(adapter.realizedPrincipal(), PRINCIPAL);

        // A different, legitimately-registered Symbiotic vault adds this adapter and attacks.
        address foreignVault = makeAddr("foreignVault");
        vaultFactory.setEntity(foreignVault, true);

        // Views expose nothing to the foreign vault.
        assertEq(adapter.deallocatable(foreignVault), 0);
        assertEq(adapter.skimmable(foreignVault), 0);

        // Direct deallocate / skim from the foreign vault are rejected (funds stay put).
        vm.prank(foreignVault);
        vm.expectRevert(IAdapter.NotVault.selector);
        adapter.deallocate(PRINCIPAL);

        vm.expectRevert(IAdapter.NotVault.selector);
        adapter.skim(foreignVault);

        assertEq(adapter.realizedPrincipal(), PRINCIPAL, "principal untouched");
        assertEq(usdc.balanceOf(address(adapter)), PRINCIPAL + YIELD, "balance untouched");
    }

    /* ---------------------------------------------------------------------- */
    /*                            skimmable / skim                            */
    /* ---------------------------------------------------------------------- */

    function test_skim_distributesYieldToRewards() public {
        _openPosition();
        request.fundRedemption(PRINCIPAL, YIELD);
        usdc.mint(address(request), YIELD);
        request.setCanWithdraw(true);
        address[] memory reqs = new address[](1);
        reqs[0] = address(request);
        adapter.redeem(reqs);

        assertEq(adapter.skimmable(address(vault)), YIELD, "yield above realized principal is skimmable");

        adapter.skim(address(vault));

        assertEq(rewards.totalDistributed(), YIELD, "yield distributed to rewards");
        assertEq(adapter.skimmable(address(vault)), 0);
        assertEq(usdc.balanceOf(address(adapter)), PRINCIPAL, "only recallable principal remains");
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

    function test_setRequestMetadata_onlyOwner() public {
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert();
        adapter.setRequestMetadata(address(request), 1, 0);
    }

    function test_setRequestMetadata_revertsAuthorizingUnattested() public {
        MockRequest fresh = new MockRequest(usdc); // not whitelisted
        vm.expectRevert(BridgeFacilitatorAdapter.NotAttested.selector);
        adapter.setRequestMetadata(address(fresh), 1, 0);
    }

    function test_setRequestMetadata_zeroingAllowedWithoutAttestation() public {
        whitelist.set(address(request), IWhitelist.WhitelistStatus.NotWhitelisted);
        adapter.setRequestMetadata(address(request), 0, 0); // de-authorization is a fail-safe
        (uint128 maxP,) = adapter.requestMetadata(address(request));
        assertEq(maxP, 0);
    }

    function test_setOfferSigner_onlyOwner() public {
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert();
        adapter.setOfferSigner(makeAddr("x"));
    }
}
