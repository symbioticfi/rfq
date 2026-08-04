// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.28;

import {ILiquidLaneAdapterAuthorization} from "./interfaces/ILiquidLaneAdapterAuthorization.sol";
import {IRegistry} from "./interfaces/IRegistry.sol";
import {IRouter} from "./interfaces/IRouter.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/// @title Router
/// @notice Atomically funds registered adapters and settles transaction-local output balances.
/// @custom:security-contact security@symbiotic.fi
contract Router is IRouter, EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes4 internal constant SIGNED_SWAP_SELECTOR = 0x9a4568b6;
    bytes4 internal constant DISCOUNT_SWAP_SELECTOR = 0x8fa5c671;
    bytes32 public constant SWAP_AUTHORIZATION_TYPEHASH = keccak256(
        "SwapAuthorization(address swapper,address authSigner,address tokenIn,address adapter,uint256 amountIn,bytes32 dataHash,uint256 executionDeadline,uint256 authorizationDeadline)"
    );

    address public immutable LIQUID_LANE_ADAPTER_FACTORY;

    constructor(address liquidLaneAdapterFactory) EIP712("Router", "1") {
        if (liquidLaneAdapterFactory == address(0) || liquidLaneAdapterFactory.code.length == 0) {
            revert InvalidFactory(liquidLaneAdapterFactory);
        }
        LIQUID_LANE_ADAPTER_FACTORY = liquidLaneAdapterFactory;
    }

    /// @inheritdoc IRouter
    function execute(address tokenIn, SwapCall[] calldata calls, Output[] calldata outputs) external nonReentrant {
        _execute(tokenIn, calls, outputs, 0);
    }

    /// @inheritdoc IRouter
    function execute(address tokenIn, SwapCall[] calldata calls, Output[] calldata outputs, uint256 deadline)
        external
        nonReentrant
    {
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert Expired(deadline);
        _execute(tokenIn, calls, outputs, deadline);
    }

    function _execute(address tokenIn, SwapCall[] calldata calls, Output[] calldata outputs, uint256 executionDeadline)
        internal
    {
        uint256 totalAmountIn = _validate(tokenIn, calls, outputs, executionDeadline);

        (address[] memory tokens, uint256[] memory baselines, uint256[] memory required, uint256 uniqueCount) =
            _snapshotOutputs(outputs);
        _executeCalls(tokenIn, calls);
        uint256[] memory produced = _measureOutputs(tokens, baselines, required, uniqueCount);

        _transferOutputs(outputs);
        _transferSurplus(tokens, baselines, required, produced, uniqueCount);

        emit Execute(msg.sender, tokenIn, totalAmountIn, calls.length, outputs.length);
    }

    function _executeCalls(address tokenIn, SwapCall[] calldata calls) internal {
        IERC20 inputToken = IERC20(tokenIn);
        for (uint256 i; i < calls.length; ++i) {
            SwapCall calldata swapCall = calls[i];
            uint256 senderBaseline = inputToken.balanceOf(msg.sender);
            uint256 adapterBaseline = inputToken.balanceOf(swapCall.adapter);

            inputToken.safeTransferFrom(msg.sender, swapCall.adapter, swapCall.amountIn);

            uint256 adapterFunded = inputToken.balanceOf(swapCall.adapter);
            uint256 adapterReceived = adapterFunded >= adapterBaseline ? adapterFunded - adapterBaseline : 0;
            if (adapterReceived != swapCall.amountIn) {
                revert InputTransferMismatch(i, swapCall.amountIn, adapterReceived);
            }

            uint256 senderAfter = inputToken.balanceOf(msg.sender);
            uint256 senderSpent = senderAfter <= senderBaseline ? senderBaseline - senderAfter : 0;
            if (senderSpent != swapCall.amountIn) {
                revert InputTransferMismatch(i, swapCall.amountIn, senderSpent);
            }

            (bool success, bytes memory reason) = swapCall.adapter.call(swapCall.data);
            if (!success) revert AdapterCallFailed(i, swapCall.adapter, reason);

            uint256 remaining = inputToken.balanceOf(swapCall.adapter);
            if (remaining != adapterBaseline) {
                revert InputConsumptionMismatch(i, adapterBaseline, remaining);
            }
        }
    }

    function _transferOutputs(Output[] calldata outputs) internal {
        for (uint256 i; i < outputs.length; ++i) {
            Output calldata output = outputs[i];
            IERC20 token = IERC20(output.token);
            uint256 routerBaseline = token.balanceOf(address(this));
            uint256 recipientBaseline = token.balanceOf(output.recipient);

            token.safeTransfer(output.recipient, output.amount);

            uint256 recipientAfter = token.balanceOf(output.recipient);
            uint256 received = recipientAfter >= recipientBaseline ? recipientAfter - recipientBaseline : 0;
            if (received != output.amount) revert OutputTransferMismatch(i, output.amount, received);

            uint256 routerAfter = token.balanceOf(address(this));
            uint256 spent = routerAfter <= routerBaseline ? routerBaseline - routerAfter : 0;
            if (spent != output.amount) revert OutputTransferMismatch(i, output.amount, spent);

            emit OutputTransferred(output.token, output.recipient, output.amount);
        }
    }

    function _transferSurplus(
        address[] memory tokens,
        uint256[] memory baselines,
        uint256[] memory required,
        uint256[] memory produced,
        uint256 uniqueCount
    ) internal {
        for (uint256 i; i < uniqueCount; ++i) {
            uint256 surplus = produced[i] - required[i];
            IERC20 token = IERC20(tokens[i]);
            if (surplus > 0) {
                uint256 routerBaseline = token.balanceOf(address(this));
                uint256 swapperBaseline = token.balanceOf(msg.sender);

                token.safeTransfer(msg.sender, surplus);

                uint256 swapperAfter = token.balanceOf(msg.sender);
                uint256 received = swapperAfter >= swapperBaseline ? swapperAfter - swapperBaseline : 0;
                if (received != surplus) revert SurplusTransferMismatch(tokens[i], surplus, received);

                uint256 routerAfter = token.balanceOf(address(this));
                uint256 spent = routerAfter <= routerBaseline ? routerBaseline - routerAfter : 0;
                if (spent != surplus) revert SurplusTransferMismatch(tokens[i], surplus, spent);

                emit SurplusTransferred(tokens[i], msg.sender, surplus);
            }

            uint256 finalBalance = token.balanceOf(address(this));
            if (finalBalance != baselines[i]) {
                revert BalanceIsolationViolation(tokens[i], baselines[i], finalBalance);
            }
        }
    }

    function _snapshotOutputs(Output[] calldata outputs)
        internal
        view
        returns (address[] memory tokens, uint256[] memory baselines, uint256[] memory required, uint256 uniqueCount)
    {
        tokens = new address[](outputs.length);
        baselines = new uint256[](outputs.length);
        required = new uint256[](outputs.length);

        for (uint256 i; i < outputs.length; ++i) {
            address token = outputs[i].token;
            uint256 tokenIndex = uniqueCount;
            for (uint256 j; j < uniqueCount; ++j) {
                if (tokens[j] == token) {
                    tokenIndex = j;
                    break;
                }
            }

            if (tokenIndex == uniqueCount) {
                tokens[uniqueCount] = token;
                baselines[uniqueCount] = IERC20(token).balanceOf(address(this));
                ++uniqueCount;
            }
            required[tokenIndex] += outputs[i].amount;
        }
    }

    function _measureOutputs(
        address[] memory tokens,
        uint256[] memory baselines,
        uint256[] memory required,
        uint256 uniqueCount
    ) internal view returns (uint256[] memory produced) {
        produced = new uint256[](uniqueCount);
        for (uint256 i; i < uniqueCount; ++i) {
            uint256 finalBalance = IERC20(tokens[i]).balanceOf(address(this));
            if (finalBalance < baselines[i]) {
                revert BalanceIsolationViolation(tokens[i], baselines[i], finalBalance);
            }
            produced[i] = finalBalance - baselines[i];
            if (produced[i] < required[i]) {
                revert InsufficientOutput(tokens[i], required[i], produced[i]);
            }
        }
    }

    function _validate(address tokenIn, SwapCall[] calldata calls, Output[] calldata outputs, uint256 executionDeadline)
        internal
        view
        returns (uint256 totalAmountIn)
    {
        if (tokenIn == address(0) || tokenIn.code.length == 0) revert InvalidTokenIn(tokenIn);
        if (calls.length == 0) revert EmptySwapCalls();
        if (outputs.length == 0) revert EmptyOutputs();

        for (uint256 i; i < outputs.length; ++i) {
            Output calldata output = outputs[i];
            if (output.token == address(0) || output.token == tokenIn || output.token.code.length == 0) {
                revert InvalidOutputToken(i, output.token);
            }
            if (output.recipient == address(0) || output.recipient == address(this)) {
                revert InvalidRecipient(i, output.recipient);
            }
            if (output.amount == 0) revert InvalidAmount(i);
        }

        for (uint256 i; i < calls.length; ++i) {
            SwapCall calldata swapCall = calls[i];
            if (swapCall.adapter == address(0) || swapCall.adapter.code.length == 0) {
                revert InvalidAdapter(i, swapCall.adapter);
            }
            if (swapCall.amountIn == 0) revert InvalidAmount(i);
            totalAmountIn += swapCall.amountIn;
            if (swapCall.data.length < 4) revert InvalidCalldata(i);

            bytes4 selector = _selector(swapCall.data);
            if (selector != SIGNED_SWAP_SELECTOR && selector != DISCOUNT_SWAP_SELECTOR) {
                revert InvalidSelector(i, selector);
            }
        }

        IRegistry registry = IRegistry(LIQUID_LANE_ADAPTER_FACTORY);
        for (uint256 i; i < calls.length; ++i) {
            SwapCall calldata swapCall = calls[i];
            if (!registry.isEntity(swapCall.adapter)) revert InvalidAdapter(i, swapCall.adapter);
            _validateAuthorization(tokenIn, swapCall, i, executionDeadline);
        }
    }

    function _validateAuthorization(
        address tokenIn,
        SwapCall calldata swapCall,
        uint256 index,
        uint256 executionDeadline
    ) internal view {
        // forge-lint: disable-next-line(block-timestamp)
        if (swapCall.authDeadline == 0 || block.timestamp > swapCall.authDeadline) {
            revert InvalidAuthorizationDeadline(index, swapCall.authDeadline);
        }

        ILiquidLaneAdapterAuthorization adapter = ILiquidLaneAdapterAuthorization(swapCall.adapter);
        address signer = swapCall.authSigner;
        if (signer != adapter.owner()) {
            address marketMaker = adapter.marketMaker();
            if (signer != marketMaker && !adapter.isFiller(marketMaker, signer)) {
                revert UnauthorizedAuthSigner(index, swapCall.adapter, signer);
            }
        }

        bytes32 structHash = keccak256(
            abi.encode(
                SWAP_AUTHORIZATION_TYPEHASH,
                msg.sender,
                signer,
                tokenIn,
                swapCall.adapter,
                swapCall.amountIn,
                keccak256(swapCall.data),
                executionDeadline,
                swapCall.authDeadline
            )
        );
        if (!SignatureChecker.isValidSignatureNowCalldata(signer, _hashTypedDataV4(structHash), swapCall.authSignature))
        {
            revert InvalidAuthorizationSignature(index, signer);
        }
    }

    function _selector(bytes calldata data) internal pure returns (bytes4 selector) {
        assembly ("memory-safe") {
            selector := calldataload(data.offset)
        }
    }
}
