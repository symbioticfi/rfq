// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.28;

import {ILoopRouter} from "./interfaces/ILoopRouter.sol";
import {IMorphoBlue, IMorphoFlashLoanCallback} from "./interfaces/IMorphoBlue.sol";
import {IRegistry} from "./interfaces/IRegistry.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title LoopRouter
/// @notice Levers a Morpho Blue position up in one transaction, and unwinds it in one transaction by
///         redeeming the collateral through a registered LiquidLane adapter's synchronous swap.
///
/// @dev The user signs and submits the transaction themselves; the router never holds a position and
///      never custodies funds between transactions. Anything left behind by a leg is swept back to the
///      caller before the outer call returns.
///
///      Two invariants carry the safety of this contract:
///
///      1. `onBehalf` is *always* `msg.sender`. Looping requires the user to call
///         `Morpho.setAuthorization(loopRouter, true)`, which would otherwise let the router move any
///         authorizing user's position. Hard-coding the caller as the position owner means an
///         authorization can only ever be exercised by its own grantor.
///      2. Venue calls are restricted to an owner-curated allowlist. A venue call is arbitrary calldata
///         to an arbitrary target, so an unrestricted one would let anybody spend the ERC-20 allowances
///         users grant this router. Every economic outcome is additionally bounded by a balance delta
///         rather than by trusting the venue or the adapter to behave.
contract LoopRouter is ILoopRouter, Ownable2Step, ReentrancyGuard, IMorphoFlashLoanCallback {
    using Address for address;
    using SafeERC20 for IERC20;

    /// @dev Discriminates the two flows sharing the flash-loan callback.
    enum Flow {
        Loop,
        Unloop
    }

    /// @inheritdoc ILoopRouter
    address public immutable MORPHO;

    /// @inheritdoc ILoopRouter
    address public immutable LIQUID_LANE_ADAPTER_FACTORY;

    /// @inheritdoc ILoopRouter
    mapping(address target => bool allowed) public isVenue;

    /// @dev Hash of the flash loan being serviced, in transient storage (EIP-1153). Committed
    ///      immediately before calling Morpho and cleared once the callback runs, so the callback can
    ///      only ever be driven by the exact loan this contract just requested. Implicitly zeroed at
    ///      end of transaction. Modelled on `FlashLoanCapability` in symbioticfi/reinsurance.
    bytes32 private transient _activeFlashLoan;

    constructor(address morpho, address liquidLaneAdapterFactory, address initialOwner) Ownable(initialOwner) {
        MORPHO = morpho;
        LIQUID_LANE_ADAPTER_FACTORY = liquidLaneAdapterFactory;
    }

    /// @inheritdoc ILoopRouter
    function setVenue(address target, bool allowed) external onlyOwner {
        isVenue[target] = allowed;

        emit SetVenue(target, allowed);
    }

    /// @inheritdoc ILoopRouter
    function loop(LoopParams calldata params) external nonReentrant {
        if (block.timestamp > params.deadline) {
            revert Expired();
        }
        if (params.flashLoanAmount == 0) {
            revert ZeroAmount();
        }
        _checkVenue(params.acquire.target);

        _flashLoan(params.market.loanToken, params.flashLoanAmount, abi.encode(Flow.Loop, msg.sender, params));

        _sweep(params.market.loanToken, msg.sender);
        _sweep(params.market.collateralToken, msg.sender);
    }

    /// @inheritdoc ILoopRouter
    function unloop(UnloopParams calldata params) external nonReentrant {
        if (block.timestamp > params.deadline) {
            revert Expired();
        }
        if (params.repayAssets == 0 || params.withdrawCollateral == 0) {
            revert ZeroAmount();
        }
        if (!IRegistry(LIQUID_LANE_ADAPTER_FACTORY).isEntity(params.adapter)) {
            revert InvalidAdapter();
        }
        if (params.settle.target != address(0)) {
            _checkVenue(params.settle.target);
        }

        _flashLoan(params.market.loanToken, params.repayAssets, abi.encode(Flow.Unloop, msg.sender, params));

        _sweep(params.market.loanToken, msg.sender);
        _sweep(params.market.collateralToken, msg.sender);
        _sweep(params.redeemAsset, msg.sender);
    }

    /// @notice Morpho Blue flash-loan callback. Unreachable outside a loan this contract requested.
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        if (msg.sender != MORPHO) {
            revert NotMorpho();
        }
        if (_activeFlashLoan != keccak256(abi.encode(assets, data))) {
            revert UnexpectedCallback();
        }
        delete _activeFlashLoan;

        address loanToken;
        if (abi.decode(data[:32], (Flow)) == Flow.Loop) {
            (, address account, LoopParams memory params) = abi.decode(data, (Flow, address, LoopParams));
            _runLoop(account, params, assets);
            loanToken = params.market.loanToken;
        } else {
            (, address account, UnloopParams memory params) = abi.decode(data, (Flow, address, UnloopParams));
            _runUnloop(account, params, assets);
            loanToken = params.market.loanToken;
        }

        // Morpho pulls the principal back once this returns. Its flash loans are fee-free.
        IERC20(loanToken).forceApprove(MORPHO, assets);
    }

    /// @dev Converts the borrowed loan token into collateral, supplies it for `account`, and draws the
    ///      debt that repays the flash loan.
    function _runLoop(address account, LoopParams memory params, uint256 assets) internal {
        IERC20 collateral = IERC20(params.market.collateralToken);

        uint256 collateralBefore = collateral.balanceOf(address(this));
        _callVenue(params.market.loanToken, params.acquire, assets);
        uint256 acquired = collateral.balanceOf(address(this)) - collateralBefore;
        if (acquired < params.minCollateralAcquired) {
            revert InsufficientAcquired();
        }

        if (params.seedCollateral > 0) {
            collateral.safeTransferFrom(account, address(this), params.seedCollateral);
        }

        uint256 supplied = acquired + params.seedCollateral;
        collateral.forceApprove(MORPHO, supplied);
        IMorphoBlue(MORPHO).supplyCollateral(params.market, supplied, account, "");

        // Drawn against the caller's own position; `receiver` is this router so the loan can be repaid.
        IMorphoBlue(MORPHO).borrow(params.market, assets, 0, account, address(this));

        emit Looped(account, params.market.collateralToken, supplied, assets);
    }

    /// @dev Repays debt, withdraws collateral, and redeems it through the LiquidLane adapter.
    function _runUnloop(address account, UnloopParams memory params, uint256 assets) internal {
        IERC20 loanToken = IERC20(params.market.loanToken);

        loanToken.forceApprove(MORPHO, assets);
        IMorphoBlue(MORPHO).repay(params.market, assets, 0, account, "");
        IMorphoBlue(MORPHO).withdrawCollateral(params.market, params.withdrawCollateral, account, address(this));

        // The adapter spends from its own balance, so the collateral is pushed before the call. The
        // signed quote inside `redeemData` must name this router as recipient; that is enforced by the
        // balance delta below rather than by decoding adapter calldata.
        uint256 redeemBefore = IERC20(params.redeemAsset).balanceOf(address(this));
        IERC20(params.market.collateralToken).safeTransfer(params.adapter, params.withdrawCollateral);
        params.adapter.functionCall(params.redeemData);

        uint256 redeemed = IERC20(params.redeemAsset).balanceOf(address(this)) - redeemBefore;
        if (redeemed < params.minRedeemed) {
            revert InsufficientRedeemed();
        }

        // Cross-asset unwind: the adapter pays the vault asset, which need not be the loan token.
        if (params.settle.target != address(0)) {
            _callVenue(params.redeemAsset, params.settle, redeemed);
        }

        if (loanToken.balanceOf(address(this)) < assets) {
            revert InsufficientRepayment();
        }

        emit Unlooped(account, params.market.collateralToken, assets, params.withdrawCollateral);
    }

    /// @dev Requests a flash loan, committing to the exact callback payload first.
    function _flashLoan(address token, uint256 assets, bytes memory data) internal {
        _activeFlashLoan = keccak256(abi.encode(assets, data));
        IMorphoBlue(MORPHO).flashLoan(token, assets, data);
    }

    /// @dev Calls a venue with an exact, immediately-revoked approval of `amount` of `token`.
    function _callVenue(address token, VenueCall memory call, uint256 amount) internal {
        IERC20(token).forceApprove(call.target, amount);
        call.target.functionCall(call.data);
        IERC20(token).forceApprove(call.target, 0);
    }

    /// @dev Reverts unless `target` is an allowlisted venue.
    function _checkVenue(address target) internal view {
        if (!isVenue[target]) {
            revert InvalidVenue();
        }
    }

    /// @dev Returns any residual balance to the caller so nothing is ever stranded in the router.
    function _sweep(address token, address recipient) internal {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            IERC20(token).safeTransfer(recipient, balance);
        }
    }
}
