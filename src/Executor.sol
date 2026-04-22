// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.28;

import {IExecutor, CALLER_ROLE} from "./interfaces/IExecutor.sol";
import {IInstantRedemptionAdapter} from "./interfaces/IInstantRedemptionAdapter.sol";
import {IReactor, NATIVE} from "./interfaces/IReactor.sol";

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LibCall as Address} from "@solady/src/utils/LibCall.sol";
import {SafeTransferLib as SafeERC20} from "@solady/src/utils/SafeTransferLib.sol";

/// @title Executor
/// @notice Role-gated executor that forwards fills into Reactor and handles execution callbacks.
contract Executor is AccessControl, IExecutor {
    using Address for address;
    using SafeERC20 for address;

    /* IMMUTABLES */

    /// @dev Reactor that is allowed to trigger execution callbacks.
    address internal immutable REACTOR;
    /// @dev Instant redemption adapter used for swap execution.
    address internal immutable IR_ADAPTER;

    /* CONSTRUCTOR */

    constructor(address reactor, address irAdapter, address admin) {
        REACTOR = reactor;
        IR_ADAPTER = irAdapter;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /* MODIFIERS */

    /// @dev Reverts unless the caller has the caller role.
    modifier onlyCaller() {
        if (!hasRole(CALLER_ROLE, msg.sender)) {
            revert NotCaller();
        }

        _;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IExecutor
    function fill(
        IReactor.Order calldata order,
        bytes calldata protocolSignature,
        IInstantRedemptionAdapter.Swap calldata swap,
        bytes calldata executorData
    ) public onlyCaller {
        IReactor(REACTOR).fill(order, protocolSignature, swap, executorData);
    }

    /// @inheritdoc IExecutor
    function fill(
        IReactor.Order calldata order,
        bytes calldata protocolSignature,
        IInstantRedemptionAdapter.Swap[] calldata swapInputs,
        bytes calldata executorData
    ) public onlyCaller {
        IReactor(REACTOR).fill(order, protocolSignature, swapInputs, executorData);
    }

    /// @inheritdoc IExecutor
    function fill(
        IReactor.Order calldata order,
        bytes calldata protocolSignature,
        IInstantRedemptionAdapter.Swap[] calldata swapInputs,
        IReactor.DiscountSwapInput[] calldata discountSwapInputs,
        bytes calldata executorData
    ) public onlyCaller {
        IReactor(REACTOR).fill(order, protocolSignature, swapInputs, discountSwapInputs, executorData);
    }

    /// @inheritdoc IExecutor
    function execute(
        IReactor.Order calldata order,
        IInstantRedemptionAdapter.Swap[] calldata swapInputs,
        IReactor.DiscountSwapInput[] calldata discountSwapInputs,
        bytes calldata executorData
    ) public {
        if (REACTOR != msg.sender) {
            revert NotReactor();
        }

        for (uint256 i; i < swapInputs.length; ++i) {
            IInstantRedemptionAdapter(IR_ADAPTER).swap(swapInputs[i]);
        }
        for (uint256 i; i < discountSwapInputs.length; ++i) {
            IInstantRedemptionAdapter(IR_ADAPTER)
                .swap(
                    discountSwapInputs[i].discountSwap,
                    discountSwapInputs[i].protocolSignature,
                    discountSwapInputs[i].recipient,
                    discountSwapInputs[i].amountIn,
                    discountSwapInputs[i].amountOut
                );
        }

        Call[] memory calls = abi.decode(executorData, (Call[]));
        for (uint256 i; i < calls.length; ++i) {
            calls[i].target.callContract(calls[i].value, calls[i].data);
        }

        for (uint256 i; i < order.request.outputs.length; ++i) {
            address token = order.request.outputs[i].token;
            if (token != NATIVE && IERC20(token).allowance(address(this), REACTOR) < type(uint256).max) {
                token.safeApproveWithRetry(REACTOR, type(uint256).max);
            }
        }

        REACTOR.trySafeTransferAllETH(gasleft());
    }

    /* RECEIVE FUNCTION */

    /// @dev Accepts native asset used for downstream output delivery or refunds.
    receive() external payable {}
}
