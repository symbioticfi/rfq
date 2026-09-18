// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.34;

import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

address constant NATIVE = address(0);

bytes32 constant OUTPUT_TYPEHASH = keccak256("Output(address token,uint256 amount,address recipient)");
bytes32 constant REQUEST_TYPEHASH = keccak256(
    "Request(address tokenIn,uint256 amountIn,Output[] outputs,uint256 deadline,uint256 nonce,address protocol)"
    "Output(address token,uint256 amount,address recipient)"
);
bytes32 constant ORDER_TYPEHASH = keccak256(
    "Order(Request request,bytes swapperSignature,address swapper,address filler,address adapter,Output[] outputs)"
    "Output(address token,uint256 amount,address recipient)"
    "Request(address tokenIn,uint256 amountIn,Output[] outputs,uint256 deadline,uint256 nonce,address protocol)"
);

/// @dev Appended to Permit2's PermitWitnessTransferFrom type prefix. Dependencies are alphabetically ordered.
string constant PERMIT2_WITNESS_TYPE_STRING = "Request witness)"
    "Output(address token,uint256 amount,address recipient)"
    "Request(address tokenIn,uint256 amountIn,Output[] outputs,uint256 deadline,uint256 nonce,address protocol)"
    "TokenPermissions(address token,uint256 amount)";

/// @title IReactorV2
/// @notice Exact-input settlement through Permit2 into one registered Liquid Lane adapter or connector.
interface IReactorV2 {
    error ReactorV2__InvalidConfiguration();
    error ReactorV2__InvalidAdapter();
    error ReactorV2__InvalidFiller();
    error ReactorV2__InvalidOutput();
    error ReactorV2__InvalidProtocolSignature();

    /// @notice An output obligation; address(0) denotes native currency.
    struct Output {
        address token;
        uint256 amount;
        address recipient;
    }

    /// @notice Swapper's exact-input request, signed as the Permit2 witness.
    /// @dev nonce is a Permit2 unordered nonce. Cancel directly through Permit2.invalidateUnorderedNonces.
    /// The Permit2 token, amount, nonce and deadline are derived from these fields; spender is this ReactorV2.
    struct Request {
        address tokenIn;
        uint256 amountIn;
        Output[] outputs;
        uint256 deadline;
        uint256 nonce;
        address protocol;
    }

    /// @notice Protocol-authorized fill, signed under EIP-712 domain name "Reactor", version "2".
    /// @dev adapter is the single input recipient, registered in either factory. It is bound by the protocol signature.
    /// swapperSignature is the Permit2 witness signature, not a standalone Reactor request signature.
    /// outputs must match the request's tokens/recipients and meet or exceed every requested amount.
    struct Order {
        Request request;
        bytes swapperSignature;
        address swapper;
        address filler;
        address adapter;
        Output[] outputs;
    }

    event Fill(Order order);

    function PERMIT2() external view returns (ISignatureTransfer);
    function LL_ADAPTER_FACTORY() external view returns (address);
    function LL_CONNECTOR_FACTORY() external view returns (address);

    /// @notice Whether Permit2 has consumed or invalidated this swapper nonce.
    function isUsedNonce(address swapper, uint256 nonce) external view returns (bool);

    /// @notice Transfer the full input to one registered destination, invoke the filler, then settle outputs.
    /// @dev The filler must implement IReactorV2Callback, approve ERC20 outputs, and send native outputs here.
    /// A callback or output-transfer failure reverts the input transfer and Permit2 nonce consumption atomically.
    /// Tokens must use standard transfer accounting; fee-on-transfer and rebasing during settlement are unsupported.
    function fill(Order calldata order, bytes calldata protocolSignature, bytes calldata executorData) external;
}
