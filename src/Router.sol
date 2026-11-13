// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.28;

import {Relayer} from "./Relayer.sol";
import {IRelayer} from "./interfaces/IRelayer.sol";
import {IRouter} from "./interfaces/IRouter.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Router
/// @notice Pulls one token from the caller, runs arbitrary calls, and pays out declared minimums.
///
/// @dev Deliberately knows nothing about what it is used for. There is no lending protocol, no
///      adapter registry, and no venue allowlist here — a caller supplies the calls, and the router
///      supplies atomicity plus the guarantees below. The user signs and submits the transaction
///      themselves; the router custodies nothing between transactions.
///
///      Three properties carry the safety of arbitrary execution:
///
///      1. **Allowances live on the relayer, not here.** Users approve `RELAYER`, whose only
///         function moves tokens to this router and is callable only by this router. So a call
///         cannot spend anyone's allowance — there is none held here to spend.
///      2. **No call may target the relayer.** Without this, a call could invoke `pull` directly and
///         drain any address that had approved it. This is the single check that makes property 1
///         hold, and it is why the relayer must be a separate contract rather than a modifier.
///      3. **The router ends every call with a zero balance.** Every token it touched is swept to
///         the caller. A call can still approve a third party against this router, but because
///         transactions are atomic that approval can only be exercised in a later transaction, by
///         which point there is nothing here to take.
contract Router is IRouter, ReentrancyGuard {
    using Address for address;
    using SafeERC20 for IERC20;

    /// @inheritdoc IRouter
    address public immutable RELAYER;

    constructor() {
        RELAYER = address(new Relayer());
    }

    /// @inheritdoc IRouter
    function execute(
        address tokenIn,
        uint256 amountIn,
        Call[] calldata calls,
        Output[] calldata outputs,
        uint256 deadline
    ) external nonReentrant {
        if (block.timestamp > deadline) {
            revert Expired();
        }

        if (amountIn > 0) {
            IRelayer(RELAYER).pull(tokenIn, msg.sender, amountIn);
        }

        uint256 callsLength = calls.length;
        for (uint256 i; i < callsLength; ++i) {
            Call calldata call = calls[i];
            // Property 2. Everything else this contract does is safe only because of this line.
            if (call.target == RELAYER) {
                revert RelayerCallForbidden();
            }
            call.target.functionCall(call.data);
        }

        uint256 outputsLength = outputs.length;
        for (uint256 i; i < outputsLength; ++i) {
            Output calldata output = outputs[i];
            uint256 balance = IERC20(output.token).balanceOf(address(this));
            if (balance < output.minAmount) {
                revert InsufficientOutput(output.token, balance, output.minAmount);
            }
            if (balance > 0) {
                IERC20(output.token).safeTransfer(output.recipient, balance);
            }
        }

        // Property 3: nothing of the input survives the call either, including an unspent remainder
        // or a refund a venue returned after the outputs were measured.
        if (amountIn > 0) {
            uint256 remaining = IERC20(tokenIn).balanceOf(address(this));
            if (remaining > 0) {
                IERC20(tokenIn).safeTransfer(msg.sender, remaining);
            }
        }

        emit Executed(msg.sender, tokenIn, amountIn);
    }
}
