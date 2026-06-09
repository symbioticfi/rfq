// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Adapter} from "@symbioticfi/core/src/contracts/adapters/Adapter.sol";
import {IAdapter} from "@symbioticfi/core/src/interfaces/adapters/IAdapter.sol";
import {IUniversalDelegator} from "@symbioticfi/core/src/interfaces/delegator/IUniversalDelegator.sol";
import {IVaultV2} from "@symbioticfi/core/src/interfaces/vault/IVaultV2.sol";

import {IRequest} from "grunt/src/interfaces/request/IRequest.sol";
import {IRequestCallback} from "grunt/src/interfaces/request/IRequestCallback.sol";
import {IVaultController} from "grunt/src/interfaces/request/IVaultController.sol";
import {Offer} from "grunt/src/interfaces/request/IOfferReceiver.sol";
import {IWhitelist} from "3f-request-whitelist/src/IWhitelist.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

import {EnumerableSetLib} from "@solady/src/utils/EnumerableSetLib.sol";
import {FixedPointMathLib as Math} from "@solady/src/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "@solady/src/utils/SafeCastLib.sol";
import {SafeTransferLib as SafeERC20} from "@solady/src/utils/SafeTransferLib.sol";
import {SignatureCheckerLib} from "@solady/src/utils/SignatureCheckerLib.sol";

/// @title  BridgeFacilitatorAdapter
/// @notice Symbiotic VaultV2 adapter that participates in 3F (Grunt) bridge-loan auctions as a Bridge
///         Facilitator. It funds won loans just-in-time: inside 3F's `onRequestConsumed` callback it
///         pulls the loan principal from the vault via the delegator, holds the PT/YT until repayment,
///         then realizes principal+yield via a permissionless `redeem`; the delegator recalls liquidity
///         through `deallocate`.
/// @dev    Just-in-time funding (mirrors `LiquidLaneAdapter._swap`): the adapter holds no standing idle
///         collateral. `allocatable()` is 0 except while mid-consume (`_inConsume`), so the delegator can
///         only push collateral in during the JIT pull and the curator cannot pre-stage funds here. The
///         per-adapter cap is `delegator.limitOf`. The adapter is the `offer.maker`, validating offer
///         signatures via EIP-1271 against an owner-rotatable `offerSigner`. Every consume is gated by
///         3F's `RequestWhitelist`; no local per-Request budget is kept. See
///         3F_BRIDGE_FACILITATOR_INTEGRATION.md.
contract BridgeFacilitatorAdapter is Adapter, IRequestCallback, IERC1271 {
    using EnumerableSetLib for EnumerableSetLib.AddressSet;
    using Math for uint256;
    using SafeCastLib for uint256;
    using SafeERC20 for address;

    /* ERRORS */

    /// @notice Request is not currently attested by the 3F whitelist registry.
    error NotAttested();
    /// @notice The just-in-time pull came up short (cap `limitOf` reached, or vault liquidity is dry).
    error InsufficientLiquidity();
    /// @notice The Request's underlying asset does not match the vault asset.
    error AssetMismatch();

    /* TYPES */

    /// @param principal  Collateral fronted into this Request (offer-time).
    /// @param ytExpected Offer-time expected yield; observational only (the binding figure is the
    ///                   realized `yAssets` from `burnAll`).
    /// @param openedAt   Timestamp the position was consumed.
    /// @param redeemed   True once `burnAll` has realized this Request.
    struct Position {
        uint128 principal;
        uint128 ytExpected;
        uint48 openedAt;
        bool redeemed;
    }

    /* IMMUTABLES */

    /// @notice 3F `RequestWhitelist` attestation registry (proxy address).
    address public immutable REQUEST_WHITELIST;

    /* STATE */

    /// @notice EOA whose signatures the adapter accepts under EIP-1271 (the off-chain bot key).
    address public offerSigner;
    /// @notice Per-Request position detail.
    mapping(address request => Position) public positions;
    /// @notice Realized, recallable collateral (redeemed principal sitting in the free balance).
    uint256 public realizedPrincipal;
    /// @notice Principal currently locked in live (consumed, unredeemed) loans.
    uint256 public outstandingPrincipal;

    /// @dev Open (consumed, unredeemed) Requests.
    EnumerableSetLib.AddressSet private _activeRequests;

    /// @dev Set only while pulling collateral to fund a consume; gates `allocatable()`.
    bool internal transient _inConsume;

    /* EVENTS */

    event SetOfferSigner(address indexed signer);
    event PositionOpened(address indexed request, uint256 principal, uint256 ytExpected);
    event PositionRedeemed(address indexed request, uint256 principal, uint256 yield);

    /* CONSTRUCTOR */

    constructor(
        address requestWhitelist,
        address vaultFactory,
        address adapterFactory
    ) Adapter(vaultFactory, adapterFactory) {
        REQUEST_WHITELIST = requestWhitelist;
    }

    /* OWNER: AUTHORIZATION */

    /// @notice Set the EOA whose signatures the adapter honors under EIP-1271.
    function setOfferSigner(
        address signer
    ) external onlyOwner {
        offerSigner = signer;
        emit SetOfferSigner(signer);
    }

    /* 3F PULL-MODE CALLBACK */

    /// @inheritdoc IRequestCallback
    /// @dev Invoked by the Request inside `consume()`, right before it pulls `principal` from the maker
    ///      (`yield` is the YT about to be minted, not pulled now). Funds `principal` just-in-time: idle
    ///      realized balance first, then the shortfall via the delegator's `allocateExact`. The delegator
    ///      clamps the pull to `limitOf - totalAssets` and the vault's free liquidity, so an undersized
    ///      pull means the vault cannot back the loan now — fail closed.
    function onRequestConsumed(Offer calldata, bytes calldata, uint256 principal, uint256 yield) external override {
        address request = msg.sender;
        _ensureAttested(request);

        address asset = IRequest(request).asset();
        if (asset != _asset()) revert AssetMismatch();

        // `_inConsume` opens `allocatable()` so the delegator may push the pulled collateral in via `allocate()`.
        uint256 free = IERC20(asset).balanceOf(address(this));
        if (free < principal) {
            uint256 shortfall = principal - free;
            _inConsume = true;
            uint256 pulled = IUniversalDelegator(IVaultV2(vault).delegator()).allocateExact(address(this), shortfall);
            _inConsume = false;
            if (pulled < shortfall) revert InsufficientLiquidity();
        }

        asset.safeApprove(request, principal);

        positions[request] = Position(principal.toUint128(), yield.toUint128(), uint48(block.timestamp), false);
        outstandingPrincipal += principal;
        _activeRequests.add(request);
        emit PositionOpened(request, principal, yield);
    }

    /* REALIZATION */

    /// @notice Permissionless. Realizes any ready (`canWithdraw()`) Requests via `burnAll`, booking the
    ///         recovered principal as recallable. Unknown / not-yet-ready Requests are skipped, not reverted.
    function redeem(
        address[] calldata requests
    ) external nonReentrant {
        for (uint256 i; i < requests.length; ++i) {
            address request = requests[i];
            if (!_activeRequests.contains(request)) continue;
            if (!IVaultController(request).canWithdraw()) continue;

            (,, uint256 pAssets, uint256 yAssets) = IVaultController(request).burnAll(address(this), address(this));

            // Retire offer-time principal; book actually-recovered principal. These differ on a loss
            // (recovered < fronted); the delegator's loss path reconciles via deallocate.
            outstandingPrincipal -= positions[request].principal;
            realizedPrincipal += pAssets;
            positions[request].redeemed = true;
            _activeRequests.remove(request);
            emit PositionRedeemed(request, pAssets, yAssets);
            // yAssets stays in the free balance; recalled to the vault on the next deallocate().
        }
    }

    /* EIP-1271 */

    /// @inheritdoc IERC1271
    /// @dev Accepts `signature` iff produced by `offerSigner` over `hash`.
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        address signer = offerSigner;
        if (signer != address(0) && SignatureCheckerLib.isValidSignatureNowCalldata(signer, hash, signature)) {
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
    /// @dev 0 outside a consume (no standing collateral, curator cannot pre-stage); during the JIT pull
    ///      returns the base max and the delegator clamps to `limitOf - totalAssets` and vault liquidity.
    function allocatable() public view override returns (uint256) {
        return _inConsume ? super.allocatable() : 0;
    }

    /// @inheritdoc IAdapter
    /// @dev Realized free balance (normally ~0) plus principal locked in live loans.
    function totalAssets() public view override returns (uint256) {
        return freeAssets() + outstandingPrincipal;
    }

    /// @inheritdoc IAdapter
    /// @dev Mirror the recalled amount into `realizedPrincipal` (floored at 0) so it stays an accurate
    ///      count of realized-but-not-yet-recalled principal that the off-chain bot reads.
    function deallocate(
        uint256 amount
    ) public override onlyDelegator returns (uint256 deallocated) {
        deallocated = super.deallocate(amount);
        realizedPrincipal = realizedPrincipal.saturatingSub(deallocated);
    }

    /* INTERNAL: IAdapter HOOKS */

    /// @dev Accounting passthrough for the JIT-pulled collateral; never reverts.
    function _allocate(
        uint256 amount
    ) internal pure override returns (uint256) {
        return amount;
    }

    /// @dev Principal locked in a live loan is illiquid, so this hook produces nothing beyond the free
    ///      balance the base `deallocate` already recalled (shortfalls are satisfied as loans redeem).
    function _deallocate(
        uint256
    ) internal pure override returns (uint256) {
        return 0;
    }

    /* INTERNAL: HELPERS */

    /// @dev The vault's underlying ERC4626 asset.
    function _asset() internal view returns (address) {
        return IERC4626(vault).asset();
    }

    /// @dev Reverts unless `request` is live `Whitelisted` — `PausedWhitelisted` (circuit breaker active)
    ///      and every other state are rejected.
    function _ensureAttested(
        address request
    ) internal view {
        if (IWhitelist(REQUEST_WHITELIST).isWhitelisted(request) != IWhitelist.WhitelistStatus.Whitelisted) {
            revert NotAttested();
        }
    }
}
