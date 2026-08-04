// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.28;

import {IRegistry} from "./interfaces/IRegistry.sol";
import {IRouter} from "./interfaces/IRouter.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title Router
/// @notice Atomically funds registered adapters and transfers their outputs to declared recipients.
contract Router is IRouter, ReentrancyGuard {
    using Address for address;
    using SafeERC20 for IERC20;

    /// @notice Factory registry used to validate LiquidLane adapter targets.
    address public immutable LIQUID_LANE_ADAPTER_FACTORY;

    constructor(address liquidLaneAdapterFactory) {
        LIQUID_LANE_ADAPTER_FACTORY = liquidLaneAdapterFactory;
    }

    /// @inheritdoc IRouter
    function execute(address tokenIn, SwapCall[] calldata calls, Output[] calldata outputs) public nonReentrant {
        uint256 callsLength = calls.length;
        for (uint256 i; i < callsLength; ++i) {
            SwapCall calldata swapCall = calls[i];
            if (!IRegistry(LIQUID_LANE_ADAPTER_FACTORY).isEntity(swapCall.adapter)) {
                revert InvalidAdapter();
            }

            IERC20(tokenIn).safeTransferFrom(msg.sender, swapCall.adapter, swapCall.amountIn);
            swapCall.adapter.functionCall(swapCall.data);
        }

        uint256 outputsLength = outputs.length;
        for (uint256 i; i < outputsLength; ++i) {
            Output calldata output = outputs[i];
            IERC20(output.token).safeTransfer(output.recipient, output.amount);
        }
    }

    /// @inheritdoc IRouter
    function execute(address tokenIn, SwapCall[] calldata calls, Output[] calldata outputs, uint256 deadline) external {
        if (block.timestamp > deadline) {
            revert Expired(deadline);
        }
        execute(tokenIn, calls, outputs);
    }
}
