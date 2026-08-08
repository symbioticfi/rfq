// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.28;

import {
    IFlashLoanAavePool,
    IFlashLoanAaveReceiver,
    IFlashLoanBalancerRecipient,
    IFlashLoanBalancerVault,
    IFlashLoanCapability,
    IFlashLoanMorpho,
    IFlashLoanMorphoCallback
} from "./interfaces/IFlashLoanCapability.sol";
import {IRouter} from "./interfaces/IRouter.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title FlashLoanCapability
/// @notice Borrows one asset from Aave v3, Balancer v2, or Morpho Blue and runs the caller's calls
///         with the borrowed liquidity.
///
/// @dev A standalone contract, not a base class. The router reaches it the same way it reaches any
///      other venue — as one entry in its call list — so a flash loan is composed rather than built
///      into the router. That keeps the router ignorant of lending, and lets a loan wrap calls that
///      have nothing to do with one.
///
///      Modelled on `FlashLoanCapability` in symbioticfi/reinsurance, reduced to the part that
///      matters here. That version hands the borrowed funds to a vault and runs verified actions
///      through a manager; this one holds the funds for the duration and runs the calls it was
///      given.
///
///      `Provider` selects which interface to speak, never which lender to trust — the address is
///      supplied per call. A caller-controlled provider can therefore report any fee it likes, so
///      the fee is never trusted for anything but repayment, and callers must impose their own
///      economic bounds (the router's `Output.minAmount` is where that belongs).
///
///      This contract holds no allowances. Users approve the relayer, and the relayer only answers
///      to the router, so nothing here can be made to spend anyone's tokens. What it does hold is
///      borrowed liquidity, for the length of one call — hence the sweep.
///
///      Callbacks are authenticated from transient storage (EIP-1153): the request hash is
///      committed immediately before calling the provider, and each callback recomputes it using
///      its own `msg.sender` as the provider, so only the exact lender of the exact in-flight loan
///      can drive it. Loans may nest, so the guard is stacked on the call stack rather than
///      cleared, and an inner loan cannot clear the hash its parent is still serviced under.
contract FlashLoanCapability is
    IFlashLoanCapability,
    IFlashLoanBalancerRecipient,
    IFlashLoanAaveReceiver,
    IFlashLoanMorphoCallback
{
    using Address for address;
    using SafeERC20 for IERC20;

    /// @dev Hash of the loan being serviced at the current nesting depth.
    bytes32 private transient _activeFlashLoan;

    /// @inheritdoc IFlashLoanCapability
    function flashLoan(
        Provider providerType,
        address provider,
        address token,
        uint256 amount,
        IRouter.Call[] calldata calls
    ) external {
        _initiate(providerType, provider, token, amount, abi.encode(calls));

        // Anything the calls produced beyond the repayment belongs to whoever asked for the loan.
        // Without this it would sit here for the next caller to take.
        uint256 surplus = IERC20(token).balanceOf(address(this));
        if (surplus > 0) {
            IERC20(token).safeTransfer(msg.sender, surplus);
        }
    }

    /// @dev Commits the request hash, then hands off to the provider.
    function _initiate(Provider providerType, address provider, address token, uint256 amount, bytes memory data)
        private
    {
        bytes32 enclosing = _activeFlashLoan;
        _activeFlashLoan = keccak256(abi.encode(providerType, provider, token, amount, data));

        if (providerType == Provider.Balancer) {
            address[] memory tokens = new address[](1);
            uint256[] memory amounts = new uint256[](1);
            tokens[0] = token;
            amounts[0] = amount;
            IFlashLoanBalancerVault(provider).flashLoan(address(this), tokens, amounts, data);
        } else if (providerType == Provider.Aave) {
            IFlashLoanAavePool(provider).flashLoanSimple(address(this), token, amount, data, 0);
        } else {
            // Morpho's callback carries only the amount, so the token rides in the payload.
            IFlashLoanMorpho(provider).flashLoan(token, amount, abi.encode(token, data));
        }

        _activeFlashLoan = enclosing;
    }

    /// @dev `provider` is the callback's `msg.sender`; matching the transient hash proves the caller
    ///      is the exact lender we borrowed from.
    function _serviceFlashLoan(
        Provider providerType,
        address provider,
        address token,
        uint256 amount,
        uint256 fee,
        bytes memory data
    ) private {
        if (_activeFlashLoan != keccak256(abi.encode(providerType, provider, token, amount, data))) {
            revert UnexpectedFlashLoan();
        }

        IRouter.Call[] memory calls = abi.decode(data, (IRouter.Call[]));
        uint256 length = calls.length;
        for (uint256 i; i < length; ++i) {
            calls[i].target.functionCall(calls[i].data);
        }

        // Checked here rather than left to the provider so a shortfall names itself instead of
        // surfacing as an opaque transfer revert from inside the lender.
        uint256 owed = amount + fee;
        uint256 held = IERC20(token).balanceOf(address(this));
        if (held < owed) {
            revert FlashLoanNotRepaid(token, held, owed);
        }

        emit FlashLoan(providerType, provider, token, amount, fee);
    }

    /// @inheritdoc IFlashLoanBalancerRecipient
    function receiveFlashLoan(
        address[] calldata tokens,
        uint256[] calldata amounts,
        uint256[] calldata feeAmounts,
        bytes calldata userData
    ) external {
        _serviceFlashLoan(Provider.Balancer, msg.sender, tokens[0], amounts[0], feeAmounts[0], userData);
        // Balancer is repaid by transfer.
        IERC20(tokens[0]).safeTransfer(msg.sender, amounts[0] + feeAmounts[0]);
    }

    /// @inheritdoc IFlashLoanAaveReceiver
    function executeOperation(address asset, uint256 amount, uint256 premium, address, bytes calldata params)
        external
        returns (bool)
    {
        _serviceFlashLoan(Provider.Aave, msg.sender, asset, amount, premium, params);
        // Aave pulls principal + premium.
        IERC20(asset).forceApprove(msg.sender, amount + premium);
        return true;
    }

    /// @inheritdoc IFlashLoanMorphoCallback
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        (address token, bytes memory calls) = abi.decode(data, (address, bytes));
        // Morpho charges no fee.
        _serviceFlashLoan(Provider.Morpho, msg.sender, token, assets, 0, calls);
        // Morpho pulls the principal.
        IERC20(token).forceApprove(msg.sender, assets);
    }
}
