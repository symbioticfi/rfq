// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.28;

import {IExecutor} from "./interfaces/IExecutor.sol";
import {IInstantRedemptionAdapter} from "./interfaces/IInstantRedemptionAdapter.sol";
import {IPermit2} from "./interfaces/IPermit2.sol";
import {
    IReactor,
    NATIVE,
    ORDER_TYPEHASH,
    OUTPUT_TYPEHASH,
    REQUEST_TYPEHASH,
    REQUEST_WITNESS_TYPE_STRING
} from "./interfaces/IReactor.sol";

import {EIP712} from "@solady/src/utils/EIP712.sol";
import {SafeTransferLib as SafeERC20} from "@solady/src/utils/SafeTransferLib.sol";
import {SignatureCheckerLib as SignatureChecker} from "@solady/src/utils/SignatureCheckerLib.sol";

/// @title Reactor
/// @notice Contract for Permit2-based RWA intake, redemption-account routing, and executor invocation.
contract Reactor is EIP712, IReactor {
    using SafeERC20 for address;

    /* IMMUTABLES */

    /// @dev Instant redemption adapter that executes vault swap legs.
    address internal immutable ADAPTER;
    /// @dev Permit2 contract that transfers the swapper input into the Reactor.
    address internal immutable PERMIT2;

    /* CONSTRUCTOR */

    constructor(address adapter, address permit2) {
        ADAPTER = adapter;
        PERMIT2 = permit2;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IReactor
    function fill(
        Order memory order,
        bytes memory protocolSignature,
        IInstantRedemptionAdapter.Swap memory swap,
        bytes memory executorData
    ) public {
        IInstantRedemptionAdapter.Swap[] memory swapInputs = new IInstantRedemptionAdapter.Swap[](1);
        swapInputs[0] = swap;

        _fill(order, protocolSignature, swapInputs, new DiscountSwapInput[](0), executorData);
    }

    /// @inheritdoc IReactor
    function fill(
        Order memory order,
        bytes memory protocolSignature,
        IInstantRedemptionAdapter.Swap[] memory swapInputs,
        bytes memory executorData
    ) public {
        _fill(order, protocolSignature, swapInputs, new DiscountSwapInput[](0), executorData);
    }

    /// @inheritdoc IReactor
    function fill(
        Order memory order,
        bytes memory protocolSignature,
        IInstantRedemptionAdapter.Swap[] memory swapInputs,
        DiscountSwapInput[] memory discountSwapInputs,
        bytes memory executorData
    ) public {
        _fill(order, protocolSignature, swapInputs, discountSwapInputs, executorData);
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Validates and executes a fill across one or more adapter swap legs.
    /// @param order The signed protocol order.
    /// @param protocolSignature The protocol signature over `order`.
    /// @param swapInputs The direct adapter swaps that consume the input.
    /// @param discountSwapInputs The discount-backed adapter swaps that consume the input.
    /// @param executorData The opaque executor payload forwarded to the executor.
    function _fill(
        Order memory order,
        bytes memory protocolSignature,
        IInstantRedemptionAdapter.Swap[] memory swapInputs,
        DiscountSwapInput[] memory discountSwapInputs,
        bytes memory executorData
    ) internal {
        if (!SignatureChecker.isValidSignatureNow(
                order.request.protocol, _hashTypedData(_hashOrder(order)), protocolSignature
            )) {
            revert InvalidProtocolSignature();
        }
        if (order.filler != msg.sender) {
            revert InvalidFiller();
        }

        uint256 totalAmountIn;
        for (uint256 i; i < swapInputs.length; ++i) {
            if (swapInputs[i].tokenIn != order.request.tokenIn) {
                revert InvalidTokenIn();
            }
            totalAmountIn += swapInputs[i].amountIn;
        }
        for (uint256 i; i < discountSwapInputs.length; ++i) {
            if (discountSwapInputs[i].discountSwap.discount.tokenToRedeem != order.request.tokenIn) {
                revert InvalidTokenIn();
            }
            totalAmountIn += discountSwapInputs[i].amountIn;
        }
        if (totalAmountIn != order.request.amountIn) {
            revert InvalidAmountIn();
        }

        IPermit2(PERMIT2)
            .permitWitnessTransferFrom(
                IPermit2.PermitTransferFrom({
                    permitted: IPermit2.TokenPermissions({
                        token: order.request.tokenIn, amount: order.request.amountIn
                    }),
                    nonce: order.request.nonce,
                    deadline: order.request.deadline
                }),
                IPermit2.SignatureTransferDetails({to: address(this), requestedAmount: order.request.amountIn}),
                order.swapper,
                _hashRequest(order.request),
                REQUEST_WITNESS_TYPE_STRING,
                order.swapperSignature
            );

        for (uint256 i; i < swapInputs.length; ++i) {
            order.request.tokenIn.safeTransfer(ADAPTER, swapInputs[i].amountIn);
        }
        for (uint256 i; i < discountSwapInputs.length; ++i) {
            order.request.tokenIn.safeTransfer(ADAPTER, discountSwapInputs[i].amountIn);
        }

        IExecutor(msg.sender).execute(order, swapInputs, discountSwapInputs, executorData);

        for (uint256 i; i < order.request.outputs.length; ++i) {
            if (order.request.outputs[i].token == NATIVE) {
                order.request.outputs[i].recipient.safeTransferETH(order.request.outputs[i].amount);
            } else {
                order.request.outputs[i].token
                    .safeTransferFrom(msg.sender, order.request.outputs[i].recipient, order.request.outputs[i].amount);
            }
        }

        emit Fill(order);
    }

    /// @dev Hashes an order according to the Reactor EIP-712 schema.
    /// @param order The order to hash.
    /// @return orderHash The EIP-712 struct hash for the order.
    function _hashOrder(Order memory order) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                _hashRequest(order.request),
                keccak256(order.swapperSignature),
                order.swapper,
                order.filler
            )
        );
    }

    /// @dev Hashes a request according to the Reactor EIP-712 schema.
    /// @param request The request to hash.
    /// @return requestHash The EIP-712 struct hash for the request.
    function _hashRequest(Request memory request) internal pure returns (bytes32) {
        bytes32[] memory outputHashes = new bytes32[](request.outputs.length);
        for (uint256 i; i < request.outputs.length; ++i) {
            outputHashes[i] = keccak256(abi.encode(OUTPUT_TYPEHASH, request.outputs[i]));
        }
        return keccak256(
            abi.encode(
                REQUEST_TYPEHASH,
                request.tokenIn,
                request.amountIn,
                keccak256(abi.encodePacked(outputHashes)),
                request.deadline,
                request.nonce,
                request.protocol
            )
        );
    }

    /// @dev Returns the Reactor EIP-712 domain metadata.
    /// @return name The EIP-712 domain name.
    /// @return version The EIP-712 domain version.
    function _domainNameAndVersion() internal pure override returns (string memory name, string memory version) {
        name = "Reactor";
        version = "1";
    }

    /* RECEIVE FUNCTION */

    /// @dev Accepts native asset refunds from the executor.
    receive() external payable {}
}
