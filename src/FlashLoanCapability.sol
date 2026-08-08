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
/// @notice Borrows from Aave v3, Balancer v2, or Morpho Blue and runs the calls it was handed.
///
/// @dev A venue, not a base class. The router reaches it as one entry in its call list, so a flash
///      loan is composed rather than built into the router.
///
///      Every provider callback does the same two things: decode `Call[]`, run them. Repaying the
///      lender is part of that list, composed by whoever asked for the loan — this contract does
///      not model fees, does not decide how a provider is repaid, and does not need to know which
///      provider it is talking to beyond dispatching the initial request.
///
///      **This contract is unauthenticated by design, and safe only because it is empty.** Anyone
///      may call `flashLoan`, and anyone may call a callback directly with calls of their choosing;
///      the callbacks do not check that a loan is in flight. That grants no capability that
///      `flashLoan` does not already give the same caller for free. What makes it acceptable is
///      that this contract holds nothing to steal: it has no allowances (users approve the relayer,
///      which answers only to its router), and it sweeps its balance to the caller at the end of
///      every request. Anything that changes either of those facts — a token left at rest, an
///      allowance granted to this address — reintroduces the authentication requirement, and the
///      transient-hash guard from `FlashLoanCapability` in symbioticfi/reinsurance is the pattern
///      to restore.
///
///      A consequence worth stating: a caller can make this contract approve or transfer to an
///      address of their choosing, because a call list can say anything. Only the sweep keeps that
///      from mattering, so the sweep is load-bearing rather than tidy-up.
contract FlashLoanCapability is
    IFlashLoanCapability,
    IFlashLoanBalancerRecipient,
    IFlashLoanAaveReceiver,
    IFlashLoanMorphoCallback
{
    using Address for address;
    using SafeERC20 for IERC20;

    /// @inheritdoc IFlashLoanCapability
    function flashLoan(bytes calldata data) external {
        (Provider providerType, address provider, address token, uint256 amount, bytes memory calls) =
            abi.decode(data, (Provider, address, address, uint256, bytes));

        if (providerType == Provider.Balancer) {
            address[] memory tokens = new address[](1);
            uint256[] memory amounts = new uint256[](1);
            tokens[0] = token;
            amounts[0] = amount;
            IFlashLoanBalancerVault(provider).flashLoan(address(this), tokens, amounts, calls);
        } else if (providerType == Provider.Aave) {
            IFlashLoanAavePool(provider).flashLoanSimple(address(this), token, amount, calls, 0);
        } else {
            IFlashLoanMorpho(provider).flashLoan(token, amount, calls);
        }

        // Load-bearing: this is the whole reason an unauthenticated contract that makes arbitrary
        // calls is safe. Whatever the calls produced goes back to whoever asked, leaving nothing
        // here for the next caller.
        uint256 surplus = IERC20(token).balanceOf(address(this));
        if (surplus > 0) {
            IERC20(token).safeTransfer(msg.sender, surplus);
        }

        emit FlashLoan(providerType, provider, token, amount);
    }

    /// @inheritdoc IFlashLoanBalancerRecipient
    function receiveFlashLoan(address[] calldata, uint256[] calldata, uint256[] calldata, bytes calldata userData)
        external
    {
        _run(userData);
    }

    /// @inheritdoc IFlashLoanAaveReceiver
    function executeOperation(address, uint256, uint256, address, bytes calldata params) external returns (bool) {
        _run(params);

        return true;
    }

    /// @inheritdoc IFlashLoanMorphoCallback
    function onMorphoFlashLoan(uint256, bytes calldata data) external {
        _run(data);
    }

    /// @dev The whole of every callback: decode the calls, run them. Repayment is one of them.
    function _run(bytes calldata data) private {
        IRouter.Call[] memory calls = abi.decode(data, (IRouter.Call[]));

        uint256 length = calls.length;
        for (uint256 i; i < length; ++i) {
            calls[i].target.functionCall(calls[i].data);
        }
    }
}
