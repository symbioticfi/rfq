// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.28;

import {IRegistry} from "./interfaces/IRegistry.sol";
import {IRouter} from "./interfaces/IRouter.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title Router
/// @notice Atomically funds registered adapters and transfers their outputs to declared recipients.
/// @custom:security-contact security@symbiotic.fi
contract Router is IRouter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable LIQUID_LANE_ADAPTER_FACTORY;

    constructor(address liquidLaneAdapterFactory) {
        if (liquidLaneAdapterFactory == address(0) || liquidLaneAdapterFactory.code.length == 0) {
            revert InvalidFactory(liquidLaneAdapterFactory);
        }
        LIQUID_LANE_ADAPTER_FACTORY = liquidLaneAdapterFactory;
    }

    /// @inheritdoc IRouter
    function execute(address tokenIn, SwapCall[] calldata calls, Output[] calldata outputs) external nonReentrant {
        _execute(tokenIn, calls, outputs);
    }

    /// @inheritdoc IRouter
    function execute(address tokenIn, SwapCall[] calldata calls, Output[] calldata outputs, uint256 deadline)
        external
        nonReentrant
    {
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert Expired(deadline);
        _execute(tokenIn, calls, outputs);
    }

    function _execute(address tokenIn, SwapCall[] calldata calls, Output[] calldata outputs) internal {
        IRegistry registry = IRegistry(LIQUID_LANE_ADAPTER_FACTORY);
        IERC20 inputToken = IERC20(tokenIn);

        for (uint256 i; i < calls.length; ++i) {
            SwapCall calldata swapCall = calls[i];
            if (!registry.isEntity(swapCall.adapter)) revert InvalidAdapter(i, swapCall.adapter);

            inputToken.safeTransferFrom(msg.sender, swapCall.adapter, swapCall.amountIn);
            (bool success, bytes memory reason) = swapCall.adapter.call(swapCall.data);
            if (!success) revert AdapterCallFailed(i, swapCall.adapter, reason);
        }

        for (uint256 i; i < outputs.length; ++i) {
            Output calldata output = outputs[i];
            IERC20(output.token).safeTransfer(output.recipient, output.amount);
        }
    }
}
