// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Adapter} from "@symbioticfi/core/src/contracts/vault/adapters/Adapter.sol";
import {IAdapter} from "@symbioticfi/core/src/interfaces/vault/adapters/IAdapter.sol";
import {IVaultV2} from "@symbioticfi/core/src/interfaces/vault/IVaultV2.sol";
import {IRewards} from "@symbioticfi/core/src/interfaces/vault/IRewards.sol";

import {IRequest} from "grunt/src/interfaces/request/IRequest.sol";
import {IRequestCallback} from "grunt/src/interfaces/request/IRequestCallback.sol";
import {IVaultController} from "grunt/src/interfaces/request/IVaultController.sol";
import {Offer} from "grunt/src/interfaces/request/IOfferReceiver.sol";
import {IWhitelist} from "3f-request-whitelist/src/IWhitelist.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title  BridgeFacilitatorAdapter
/// @notice Symbiotic VaultV2 adapter that participates in 3F (Grunt) bridge-loan auctions as a
///         Bridge Facilitator. It sources vault collateral (USDC) just-in-time inside 3F's
///         `onRequestConsumed` pull-mode callback (self-allocation, gated to consume time), holds
///         the resulting PT/YT until the loan is repaid, then realizes principal+yield back to the
///         vault via a permissionless `redeem`.
/// @dev    Design notes (see 3F_BRIDGE_FACILITATOR_INTEGRATION.md):
///         - Single-vault by construction: `VAULT` is immutable; all `IAdapter` hooks only serve it.
///         - The adapter is the `offer.maker`; it validates EIP-712 offer signatures via EIP-1271,
///           delegating to an owner-rotatable `offerSigner` key (the off-chain bot's key).
///         - Two-layer authorization: 3F's `RequestWhitelist` (upstream attestation, with a
///           compliance circuit breaker) and the owner's per-Request `requestMetadata` budget.
///         - Accounting deviates from AaveV3Adapter on purpose: a funded loan is illiquid until
///           repaid, so `deallocatable` reports only realized (redeemed) principal — never principal
///           still locked in a live loan — and `skimmable` is the realized balance above it.
contract BridgeFacilitatorAdapter is Adapter, IRequestCallback, IERC1271, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;
    using Math for uint256;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    /* ERRORS */

    /// @notice Request is not currently attested by the 3F whitelist registry.
    error NotAttested();
    /// @notice The vault could not fully fund the requested principal at consume time.
    error InsufficientLiquidity();
    /// @notice Offered principal is zero or exceeds the Request's remaining authorized budget.
    error InsufficientPrincipalAllowance();
    /// @notice Offered yield is below the Request's configured per-consume floor.
    error YieldBelowFloor();
    /// @notice The Request's underlying asset does not match the vault collateral.
    error AssetMismatch();

    /* TYPES */

    /// @param principal  Collateral fronted into this Request (offer-time).
    /// @param ytExpected Offer-time expected yield (YT). Observational only; the binding figure is
    ///                   the realized `yAssets` returned by `burnAll` at redemption.
    /// @param openedAt   Timestamp the position was consumed.
    /// @param redeemed   True once `burnAll` has realized this Request.
    struct Position {
        uint128 principal;
        uint128 ytExpected;
        uint48 openedAt;
        bool redeemed;
    }

    /// @param maxPrincipal Cumulative principal cap for this Request; decremented on each consume.
    ///                     A value of 0 means "not authorized" (the implicit local allow-list).
    /// @param minYield     Per-consume yield floor; offers with `yield < minYield` are rejected.
    ///                     Not decremented.
    struct RequestMetadata {
        uint128 maxPrincipal;
        uint128 minYield;
    }

    /* IMMUTABLES */

    /// @notice The single vault this adapter sources collateral from.
    address public immutable VAULT;
    /// @dev Rewards contract that redistributes realized yield to the vault's depositors.
    address internal immutable REWARDS;
    /// @notice 3F `RequestWhitelist` attestation registry (proxy address).
    address public immutable REQUEST_WHITELIST;

    /* STATE */

    /// @notice EOA whose signatures the adapter accepts under EIP-1271 (the off-chain bot key).
    address public offerSigner;
    /// @notice Per-Request position detail.
    mapping(address request => Position) public positions;
    /// @notice Per-Request owner-set policy (cap + yield floor).
    mapping(address request => RequestMetadata) public requestMetadata;
    /// @notice Realized, recallable collateral (redeemed, not yet deallocated to the vault).
    uint256 public realizedPrincipal;

    /// @dev Open (consumed, unredeemed) Requests.
    EnumerableSet.AddressSet private _activeRequests;
    /// @dev Gates `allocatable()` to consume time so the vault can never push standing collateral in.
    bool internal transient _inConsume;

    /* EVENTS */

    event SetRequestMetadata(address indexed request, uint128 maxPrincipal, uint128 minYield);
    event SetOfferSigner(address indexed signer);
    event PositionOpened(address indexed request, uint256 principal, uint256 ytExpected);
    event PositionRedeemed(address indexed request, uint256 principal, uint256 yield);

    /* CONSTRUCTOR */

    constructor(address vault, address rewards, address requestWhitelist, address vaultFactory, address curatorRegistry)
        Adapter(vaultFactory, curatorRegistry)
    {
        VAULT = vault;
        REWARDS = rewards;
        REQUEST_WHITELIST = requestWhitelist;
    }

    /* OWNER: AUTHORIZATION */

    /// @notice Pre-authorize `request` up to cumulative `maxPrincipal` (decremented per consume) and
    ///         a per-consume `minYield` floor. `maxPrincipal == 0` de-authorizes the Request locally.
    /// @dev Re-checks the registry when authorizing so the owner cannot enable a Request 3F has not
    ///      attested; de-authorization (zeroing) is always permitted as a fail-safe.
    function setRequestMetadata(address request, uint128 maxPrincipal, uint128 minYield) external onlyOwner {
        if (maxPrincipal != 0) _ensureAttested(request);
        requestMetadata[request] = RequestMetadata(maxPrincipal, minYield);
        emit SetRequestMetadata(request, maxPrincipal, minYield);
    }

    /// @notice Set the EOA whose signatures the adapter honors under EIP-1271 for offer signing.
    function setOfferSigner(address signer) external onlyOwner {
        offerSigner = signer;
        emit SetOfferSigner(signer);
    }

    /* 3F PULL-MODE CALLBACK */

    /// @inheritdoc IRequestCallback
    /// @dev Invoked by the Request inside `consume()`, before it pulls `principal` via
    ///      `safeTransferFrom(maker, ...)`. `principal` is the amount about to be pulled; `yield` is
    ///      the YT amount about to be minted (the future return, not pulled now).
    function onRequestConsumed(Offer calldata, bytes calldata, uint256 principal, uint256 yield) external override {
        address request = msg.sender;
        _ensureAttested(request);

        RequestMetadata memory md = requestMetadata[request];
        if (principal == 0 || principal > md.maxPrincipal) revert InsufficientPrincipalAllowance();
        if (yield < md.minYield) revert YieldBelowFloor();
        requestMetadata[request].maxPrincipal = md.maxPrincipal - uint128(principal);

        address asset = IRequest(request).asset();
        if (asset != _collateral()) revert AssetMismatch();

        // Pull `principal` from the vault just-in-time. `allocatable()` returns >0 only while
        // `_inConsume`, so this is the only path that can move standing vault collateral in.
        _inConsume = true;
        uint256 allocated = IVaultV2(VAULT).allocateAdapter(address(this), principal);
        _inConsume = false;
        if (allocated < principal) revert InsufficientLiquidity();

        // Approve the Request to pull exactly `principal` (consume() transferFroms right after).
        IERC20(asset).forceApprove(request, principal);

        positions[request] =
            Position(principal.toUint128(), yield.toUint128(), uint48(block.timestamp), false);
        _activeRequests.add(request);
        emit PositionOpened(request, principal, yield);
    }

    /* REALIZATION */

    /// @notice Permissionless. Realizes any ready Requests (`canWithdraw()`) in `requests` into the
    ///         adapter via `burnAll`, marking the recovered principal recallable. Works even if the
    ///         bot is down. Unknown / not-yet-ready Requests are skipped, not reverted.
    function redeem(address[] calldata requests) external nonReentrant {
        for (uint256 i; i < requests.length; ++i) {
            address request = requests[i];
            if (!_activeRequests.contains(request)) continue;
            if (!IVaultController(request).canWithdraw()) continue;

            (,, uint256 pAssets, uint256 yAssets) = IVaultController(request).burnAll(address(this), address(this));

            realizedPrincipal += pAssets;
            positions[request].redeemed = true;
            _activeRequests.remove(request);
            emit PositionRedeemed(request, pAssets, yAssets);
            // yAssets remains in balance, surfaces via skimmable(), and is distributed on skim().
        }
    }

    /* EIP-1271 */

    /// @inheritdoc IERC1271
    /// @dev Accepts `signature` iff produced by `offerSigner` over `hash`. The Request computes the
    ///      per-Request EIP-712 digest and verifies it against `offer.maker` (this adapter).
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        address signer = offerSigner;
        if (signer != address(0) && SignatureChecker.isValidSignatureNowCalldata(signer, hash, signature)) {
            return IERC1271.isValidSignature.selector;
        }
        return 0xffffffff;
    }

    /* VIEWS */

    /// @notice Enumerate open (consumed, unredeemed) Requests for the bot / reconciliation.
    function activeRequests() external view returns (address[] memory) {
        return _activeRequests.values();
    }

    /// @inheritdoc IAdapter
    /// @dev Vault collateral can only enter during a 3F consume on this vault.
    function allocatable(address vault) public view override(Adapter) returns (uint256) {
        return (_inConsume && vault == VAULT) ? super.allocatable(vault) : 0;
    }

    /// @inheritdoc IAdapter
    /// @dev Only realized principal is recallable; principal locked in live loans contributes 0.
    ///      Single-vault: anything other than `VAULT` has no claim here.
    function deallocatable(address vault) public view override returns (uint256) {
        return vault == VAULT ? realizedPrincipal : 0;
    }

    /// @inheritdoc IAdapter
    /// @dev Realized collateral held above the recallable principal (i.e. distributable yield).
    ///      Single-vault: anything other than `VAULT` has no claim here.
    function skimmable(address vault) public view override returns (uint256) {
        if (vault != VAULT) return 0;
        return IERC20(_collateral()).balanceOf(address(this)).saturatingSub(realizedPrincipal);
    }

    /* INTERNAL: IAdapter HOOKS */

    /// @dev Accounting only. The collateral is approved to, and pulled by, the 3F Request inside
    ///      `onRequestConsumed`. Kept minimal (no skim) so a consume cannot revert here.
    function _allocate(uint256 amount) internal override {
        if (msg.sender != VAULT) revert NotVault();
        _increaseGlobalAllocated(_collateral(), amount);
    }

    /// @dev Return realized principal on demand — a pure transfer, no 3F interaction.
    ///      Single-vault guard: only `VAULT` may recall, so a foreign registered vault that adds
    ///      this adapter cannot drain principal belonging to `VAULT`'s depositors. The base
    ///      `recover()` loss path bypasses this hook (handled in `Adapter.deallocate`).
    function _deallocate(uint256 amount) internal override returns (uint256 deallocated) {
        if (msg.sender != VAULT) revert NotVault();
        deallocated = Math.min(amount, realizedPrincipal);
        if (deallocated == 0) return 0;
        realizedPrincipal -= deallocated;
        _decreaseGlobalAllocated(_collateral(), deallocated);
        IERC20(_collateral()).forceApprove(msg.sender, deallocated);
    }

    /// @dev Distribute realized yield to the vault's depositors via the rewards contract.
    function _skim(address vault) internal override returns (uint256 amount) {
        if (vault != VAULT) revert NotVault();
        amount = skimmable(vault);
        if (amount == 0) return 0;
        address collateral = _collateral();
        if (IERC20(collateral).allowance(address(this), REWARDS) < amount) {
            IERC20(collateral).forceApprove(REWARDS, type(uint256).max);
        }
        IRewards(REWARDS).distributeDonationRewards(vault, amount);
    }

    /* INTERNAL: HELPERS */

    function _collateral() internal view returns (address) {
        return IVaultV2(VAULT).collateral();
    }

    /// @dev Reverts unless `request` is currently in the registry's live `Whitelisted` state — every
    ///      other value (incl. `PausedWhitelisted` while the circuit breaker is active) is rejected.
    function _ensureAttested(address request) internal view {
        if (IWhitelist(REQUEST_WHITELIST).isWhitelisted(request) != IWhitelist.WhitelistStatus.Whitelisted) {
            revert NotAttested();
        }
    }
}
