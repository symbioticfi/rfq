// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.28;

import {IExecutor} from "./interfaces/IExecutor.sol";
import {IReactor, NATIVE, ORDER_TYPEHASH, OUTPUT_TYPEHASH, REQUEST_TYPEHASH} from "./interfaces/IReactor.sol";
import {IRegistry} from "./interfaces/IRegistry.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {BitMaps} from "@openzeppelin/contracts/utils/structs/BitMaps.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/// @title Reactor
/// @notice Contract for approved RWA intake, redemption-account routing, and executor invocation.
contract Reactor is EIP712, IReactor {
    using Address for address payable;
    using BitMaps for BitMaps.BitMap;
    using SafeERC20 for IERC20;

    /* IMMUTABLES */

    /// @inheritdoc IReactor
    address public immutable LIQUID_LANE_ADAPTER_FACTORY;

    /* STORAGE */

    /// @dev Tracks consumed request nonces by swapper.
    mapping(address swapper => BitMaps.BitMap nonces) internal _isUsedNonce;

    /* CONSTRUCTOR */

    constructor(address liquidLaneAdapterFactory) EIP712("Reactor", "1") {
        LIQUID_LANE_ADAPTER_FACTORY = liquidLaneAdapterFactory;
    }

    /* PUBLIC FUNCTIONS */

    /// @notice Returns whether a swapper request nonce has been consumed.
    /// @param swapper Address that owns the nonce.
    /// @param nonce Request nonce to check.
    /// @return used Whether the nonce has already been consumed.
    function isUsedNonce(address swapper, uint256 nonce) public view returns (bool used) {
        return _isUsedNonce[swapper].get(nonce);
    }

    /// @inheritdoc IReactor
    function invalidateNonce(uint256 nonce) public {
        _isUsedNonce[msg.sender].set(nonce);

        emit InvalidateNonce(msg.sender, nonce);
    }

    /// @inheritdoc IReactor
    function fill(
        Order memory order,
        bytes memory protocolSignature,
        SwapInput memory swapInput,
        bytes memory executorData
    ) public {
        SwapInput[] memory swapInputs = new SwapInput[](1);
        swapInputs[0] = swapInput;

        _fill(order, protocolSignature, swapInputs, new DiscountSwapInput[](0), executorData);
    }

    /// @inheritdoc IReactor
    function fill(
        Order memory order,
        bytes memory protocolSignature,
        SwapInput[] memory swapInputs,
        bytes memory executorData
    ) public {
        _fill(order, protocolSignature, swapInputs, new DiscountSwapInput[](0), executorData);
    }

    /// @inheritdoc IReactor
    function fill(
        Order memory order,
        bytes memory protocolSignature,
        SwapInput[] memory swapInputs,
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
        SwapInput[] memory swapInputs,
        DiscountSwapInput[] memory discountSwapInputs,
        bytes memory executorData
    ) internal {
        if (order.filler != msg.sender) {
            revert InvalidFiller();
        }
        if (block.timestamp > order.request.deadline) {
            revert ExpiredRequest();
        }
        if (isUsedNonce(order.swapper, order.request.nonce)) {
            revert NonceUsed();
        }
        if (!SignatureChecker.isValidSignatureNow(
                order.request.protocol, _hashTypedDataV4(_hashOrder(order)), protocolSignature
            )) {
            revert InvalidProtocolSignature();
        }
        if (!SignatureChecker.isValidSignatureNow(
                order.swapper, _hashTypedDataV4(_hashRequest(order.request)), order.swapperSignature
            )) {
            revert InvalidProtocolSignature();
        }

        uint256 totalAmountIn;
        for (uint256 i; i < swapInputs.length; ++i) {
            if (!IRegistry(LIQUID_LANE_ADAPTER_FACTORY).isEntity(swapInputs[i].adapter)) {
                revert InvalidAdapter();
            }
            if (swapInputs[i].swap.tokenIn != order.request.tokenIn) {
                revert InvalidTokenIn();
            }

            totalAmountIn += swapInputs[i].swap.amountIn;
        }
        for (uint256 i; i < discountSwapInputs.length; ++i) {
            if (!IRegistry(LIQUID_LANE_ADAPTER_FACTORY).isEntity(discountSwapInputs[i].adapter)) {
                revert InvalidAdapter();
            }
            if (discountSwapInputs[i].discountSwap.discount.tokenToRedeem != order.request.tokenIn) {
                revert InvalidTokenIn();
            }
            totalAmountIn += discountSwapInputs[i].amountIn;
        }
        if (totalAmountIn != order.request.amountIn) {
            revert InvalidAmountIn();
        }

        _isUsedNonce[order.swapper].set(order.request.nonce);
        for (uint256 i; i < swapInputs.length; ++i) {
            IERC20(order.request.tokenIn)
                .safeTransferFrom(order.swapper, swapInputs[i].adapter, swapInputs[i].swap.amountIn);
        }
        for (uint256 i; i < discountSwapInputs.length; ++i) {
            IERC20(order.request.tokenIn)
                .safeTransferFrom(order.swapper, discountSwapInputs[i].adapter, discountSwapInputs[i].amountIn);
        }

        IExecutor(msg.sender).execute(order, swapInputs, discountSwapInputs, executorData);

        for (uint256 i; i < order.request.outputs.length; ++i) {
            if (order.request.outputs[i].token == NATIVE) {
                payable(order.request.outputs[i].recipient).sendValue(order.request.outputs[i].amount);
            } else {
                IERC20(order.request.outputs[i].token)
                    .safeTransferFrom(msg.sender, order.request.outputs[i].recipient, order.request.outputs[i].amount);
            }
        }

        uint256 balance = address(this).balance;
        if (balance != 0) {
            payable(msg.sender).sendValue(balance);
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

    /* RECEIVE FUNCTION */

    /// @dev Accepts native asset refunds from the executor.
    receive() external payable {}
}
