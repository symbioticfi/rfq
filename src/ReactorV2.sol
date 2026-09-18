// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.36;

import {
    IReactorV2,
    NATIVE,
    ORDER_TYPEHASH,
    OUTPUT_TYPEHASH,
    REQUEST_TYPEHASH,
    PERMIT2_WITNESS_TYPE_STRING
} from "src/interfaces/IReactorV2.sol";
import {IReactorV2Callback} from "src/interfaces/IReactorV2Callback.sol";
import {IRegistry} from "src/interfaces/IRegistry.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/// @title ReactorV2
/// @notice Permit2 witness settlement into a single factory-registered Liquid Lane adapter or connector.
/// @custom:security-contact https://github.com/symbioticfi/rfq/security
contract ReactorV2 is EIP712, IReactorV2, ReentrancyGuardTransient {
    using Address for address payable;
    using SafeERC20 for IERC20;

    /// @inheritdoc IReactorV2
    ISignatureTransfer public immutable PERMIT2;
    /// @inheritdoc IReactorV2
    address public immutable LL_ADAPTER_FACTORY;
    /// @inheritdoc IReactorV2
    address public immutable LL_CONNECTOR_FACTORY;

    constructor(address permit2, address adapterFactory, address connectorFactory) EIP712("Reactor", "2") {
        if (permit2.code.length == 0 || adapterFactory.code.length == 0 || connectorFactory.code.length == 0) {
            revert ReactorV2__InvalidConfiguration();
        }
        PERMIT2 = ISignatureTransfer(permit2);
        LL_ADAPTER_FACTORY = adapterFactory;
        LL_CONNECTOR_FACTORY = connectorFactory;
    }

    /// @dev Accepts native output funding from the filler.
    receive() external payable {}

    /// @inheritdoc IReactorV2
    function fill(Order calldata order, bytes calldata protocolSignature, bytes calldata executorData)
        external
        nonReentrant
    {
        if (order.filler != msg.sender) revert ReactorV2__InvalidFiller();
        if (
            !IRegistry(LL_ADAPTER_FACTORY).isEntity(order.adapter)
                && !IRegistry(LL_CONNECTOR_FACTORY).isEntity(order.adapter)
        ) revert ReactorV2__InvalidAdapter();

        bytes32 requestHash = _hashRequest(order.request);
        if (!SignatureChecker.isValidSignatureNow(
                order.request.protocol, _hashTypedDataV4(_hashOrder(order, requestHash)), protocolSignature
            )) {
            revert ReactorV2__InvalidProtocolSignature();
        }

        if (order.request.outputs.length != order.outputs.length) revert ReactorV2__InvalidOutput();
        for (uint256 i; i < order.request.outputs.length; ++i) {
            Output calldata requested = order.request.outputs[i];
            Output calldata output = order.outputs[i];
            if (
                output.token != requested.token || output.recipient != requested.recipient
                    || output.amount < requested.amount
            ) revert ReactorV2__InvalidOutput();
        }

        // Permit2 verifies the swapper's witness signature, deadline and nonce, then funds exactly one destination.
        PERMIT2.permitWitnessTransferFrom(
            ISignatureTransfer.PermitTransferFrom({
                permitted: ISignatureTransfer.TokenPermissions(order.request.tokenIn, order.request.amountIn),
                nonce: order.request.nonce,
                deadline: order.request.deadline
            }),
            ISignatureTransfer.SignatureTransferDetails({to: order.adapter, requestedAmount: order.request.amountIn}),
            order.swapper,
            requestHash,
            PERMIT2_WITNESS_TYPE_STRING,
            order.swapperSignature
        );

        IReactorV2Callback(msg.sender).reactorCallback(order, executorData);

        for (uint256 i; i < order.outputs.length; ++i) {
            Output calldata output = order.outputs[i];
            if (output.token == NATIVE) {
                payable(output.recipient).sendValue(output.amount);
            } else {
                IERC20(output.token).safeTransferFrom(msg.sender, output.recipient, output.amount);
            }
        }

        uint256 balance = address(this).balance;
        if (balance != 0) payable(msg.sender).sendValue(balance);

        emit Fill(order);
    }

    /// @inheritdoc IReactorV2
    function isUsedNonce(address swapper, uint256 nonce) external view returns (bool) {
        return PERMIT2.nonceBitmap(swapper, nonce >> 8) & (uint256(1) << uint8(nonce)) != 0;
    }

    function _hashOrder(Order calldata order, bytes32 requestHash) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                requestHash,
                keccak256(order.swapperSignature),
                order.swapper,
                order.filler,
                order.adapter,
                _hashOutputs(order.outputs)
            )
        );
    }

    function _hashRequest(Request calldata request) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                REQUEST_TYPEHASH,
                request.tokenIn,
                request.amountIn,
                _hashOutputs(request.outputs),
                request.deadline,
                request.nonce,
                request.protocol
            )
        );
    }

    function _hashOutputs(Output[] calldata outputs) internal pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](outputs.length);
        for (uint256 i; i < outputs.length; ++i) {
            hashes[i] = keccak256(abi.encode(OUTPUT_TYPEHASH, outputs[i]));
        }
        return keccak256(abi.encodePacked(hashes));
    }
}
