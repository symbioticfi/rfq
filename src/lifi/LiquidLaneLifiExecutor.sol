// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.28;

import {ILiquidLaneAdapter} from "../interfaces/ILiquidLaneAdapter.sol";
import {IInputSettler} from "./interfaces/IInputSettler.sol";
import {ILiquidLaneLifiExecutor} from "./interfaces/ILiquidLaneLifiExecutor.sol";
import {IOutputSettler, MandateOutput} from "./interfaces/IOutputSettler.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title LiquidLaneLifiExecutor
/// @notice LI.FI same-chain callback that redeems released inputs and fills the order output atomically.
contract LiquidLaneLifiExecutor is Ownable, ReentrancyGuard, ILiquidLaneLifiExecutor {
    using Address for address payable;
    using SafeERC20 for IERC20;

    uint8 internal constant ORDER_STATUS_DEPOSITED = 1;
    uint8 internal constant ORDER_STATUS_CLAIMED = 2;
    uint8 internal constant OUTPUT_CONTEXT_SIMPLE = 0x00;
    uint8 internal constant OUTPUT_CONTEXT_DUTCH = 0x01;
    uint8 internal constant OUTPUT_CONTEXT_EXCLUSIVE = 0xe0;
    uint8 internal constant OUTPUT_CONTEXT_EXCLUSIVE_DUTCH = 0xe1;

    /* IMMUTABLES */

    /// @inheritdoc ILiquidLaneLifiExecutor
    address public immutable INPUT_SETTLER;
    /// @inheritdoc ILiquidLaneLifiExecutor
    address public immutable OUTPUT_SETTLER;

    /* STATE */

    /// @dev LiquidLane adapters allowed for LI.FI input redemptions.
    address[] public adapters;
    /// @inheritdoc ILiquidLaneLifiExecutor
    mapping(address adapter => bool allowed) public isAdapterAllowed;

    /* CONSTRUCTOR */

    constructor(address inputSettler, address outputSettler, address owner_, address[] memory initAdapters)
        Ownable(owner_)
    {
        if (inputSettler == address(0) || outputSettler == address(0) || owner_ == address(0)) revert ZeroAddress();

        INPUT_SETTLER = inputSettler;
        OUTPUT_SETTLER = outputSettler;
        _setAdapters(initAdapters);
    }

    /* FINALISE WRAPPER */

    /// @inheritdoc ILiquidLaneLifiExecutor
    function finaliseWithCurrentTimestamp(
        address inputSettler,
        IInputSettler.StandardOrder calldata order,
        address solver,
        address destination,
        bytes calldata call,
        bytes calldata orderOwnerSignature
    ) external {
        if (inputSettler != INPUT_SETTLER) revert InvalidInputSettler();
        if (destination != address(this)) revert InvalidDestination();

        bytes32 solverId = _addressIdentifier(solver);
        ILiquidLaneLifiExecutor.FillCall memory fillCall = abi.decode(call, (ILiquidLaneLifiExecutor.FillCall));
        _validateFillAfter(fillCall.fillAfter, fillCall.output.context);
        if (_cleanIdentifier(fillCall.solver) != solverId) revert SolverMismatch();

        bytes32 orderId = IInputSettler(INPUT_SETTLER).orderIdentifier(order);
        if (fillCall.orderId != orderId) revert InvalidOrderId();
        if (order.outputs.length != 1) revert InvalidOutputCount();
        if (
            fillCall.fillDeadline != order.fillDeadline || _outputHash(fillCall.output) != _outputHash(order.outputs[0])
        ) {
            revert InvalidOrderOutput();
        }

        uint8 status = IInputSettler(INPUT_SETTLER).orderStatus(orderId);
        if (status != ORDER_STATUS_DEPOSITED) revert InvalidOrderStatus(status);

        IInputSettler.SolveParams[] memory solveParams = new IInputSettler.SolveParams[](1);
        solveParams[0] = IInputSettler.SolveParams({timestamp: uint32(block.timestamp), solver: solverId});

        IInputSettler(INPUT_SETTLER)
            .finaliseWithSignature(order, solveParams, _addressIdentifier(destination), call, orderOwnerSignature);
    }

    /* IINPUTCALLBACK */

    /// @notice Called by the LI.FI input settler during finalise, after inputs are transferred here.
    function orderFinalised(uint256[2][] calldata inputs, bytes calldata executionData) external nonReentrant {
        if (msg.sender != INPUT_SETTLER) revert NotInputSettler();
        if (inputs.length != 1) revert InvalidInputCount();

        ILiquidLaneLifiExecutor.FillCall memory fillCall = abi.decode(executionData, (ILiquidLaneLifiExecutor.FillCall));
        _validateFillAfter(fillCall.fillAfter, fillCall.output.context);
        if (!isAdapterAllowed[fillCall.adapter]) revert AdapterNotAllowed();

        bytes32 solver = _cleanIdentifier(fillCall.solver);
        uint256 resolvedAmount = _resolveOutputAmount(fillCall.output, solver);
        _validateOutput(fillCall.output);
        address outputToken = _outputToken(fillCall.output);

        uint8 status = IInputSettler(INPUT_SETTLER).orderStatus(fillCall.orderId);
        if (status != ORDER_STATUS_CLAIMED) revert InvalidOrderStatus(status);

        address tokenIn = _inputToken(inputs[0][0]);
        uint256 amountIn = inputs[0][1];
        if (amountIn == 0) revert InvalidAmount();

        IERC20(tokenIn).safeTransfer(fillCall.adapter, amountIn);
        uint256 outputBefore = IERC20(outputToken).balanceOf(address(this));

        ILiquidLaneAdapter(fillCall.adapter)
            .swap(
                ILiquidLaneAdapter.Swap({
                    recipient: address(this), tokenIn: tokenIn, amountIn: amountIn, amountOut: resolvedAmount
                })
            );

        uint256 outputGained = IERC20(outputToken).balanceOf(address(this)) - outputBefore;
        if (outputGained < resolvedAmount) revert InsufficientOutput();

        IERC20(outputToken).forceApprove(OUTPUT_SETTLER, resolvedAmount);
        IOutputSettler(OUTPUT_SETTLER)
            .fill(fillCall.orderId, fillCall.output, fillCall.fillDeadline, abi.encode(solver));
        IOutputSettler(OUTPUT_SETTLER)
            .setAttestation(fillCall.orderId, solver, uint32(block.timestamp), fillCall.output);

        emit InputRedeemed(fillCall.orderId, fillCall.adapter, tokenIn, outputToken, amountIn, outputGained);
        emit OutputFilled(
            fillCall.orderId, solver, outputToken, _identifierAddress(fillCall.output.recipient), resolvedAmount
        );
    }

    /* OWNER */

    /// @inheritdoc ILiquidLaneLifiExecutor
    function setAdapters(address[] calldata newAdapters) external onlyOwner {
        _setAdapters(newAdapters);
    }

    /// @inheritdoc ILiquidLaneLifiExecutor
    function sweepERC20(address token, address to, uint256 amount) external onlyOwner {
        if (token == address(0) || to == address(0)) revert ZeroAddress();

        IERC20(token).safeTransfer(to, amount);
        emit SweepERC20(token, to, amount);
    }

    /// @inheritdoc ILiquidLaneLifiExecutor
    function sweepNative(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();

        payable(to).sendValue(amount);
        emit SweepNative(to, amount);
    }

    /* INTERNAL */

    function _setAdapters(address[] memory newAdapters) internal {
        for (uint256 i; i < adapters.length; ++i) {
            isAdapterAllowed[adapters[i]] = false;
        }
        delete adapters;

        for (uint256 i; i < newAdapters.length; ++i) {
            address adapter = newAdapters[i];
            if (adapter == address(0)) revert ZeroAddress();
            if (isAdapterAllowed[adapter]) revert DuplicateAdapter();

            isAdapterAllowed[adapter] = true;
            adapters.push(adapter);
        }

        emit SetAdapters(newAdapters);
    }

    function _validateOutput(MandateOutput memory output) internal view {
        if (output.chainId != block.chainid) revert InvalidOutputChain();
        if (output.amount == 0) revert InvalidAmount();

        bytes32 outputSettlerId = _addressIdentifier(OUTPUT_SETTLER);
        if (output.settler != outputSettlerId) revert InvalidOutputSettler();
        if (output.oracle != outputSettlerId) revert InvalidOutputOracle();

        _outputToken(output);
        _identifierAddress(output.recipient);
    }

    function _validateFillAfter(uint32 fillAfter, bytes memory context) internal view {
        if (fillAfter == 0) return;

        uint8 contextType = _outputContextType(context);
        if (contextType != OUTPUT_CONTEXT_DUTCH && contextType != OUTPUT_CONTEXT_EXCLUSIVE_DUTCH) {
            revert FillAfterWithoutAuction();
        }

        if (block.timestamp < fillAfter) {
            revert FillTooEarly(fillAfter, uint32(block.timestamp));
        }
    }

    function _resolveOutputAmount(MandateOutput memory output, bytes32 solver) internal view returns (uint256) {
        bytes memory context = output.context;
        uint8 contextType = _outputContextType(context);
        if (contextType == OUTPUT_CONTEXT_SIMPLE) {
            return output.amount;
        }
        if (contextType == OUTPUT_CONTEXT_DUTCH) {
            return _dutchOutputAmount(output.amount, context, 1);
        }
        if (contextType == OUTPUT_CONTEXT_EXCLUSIVE) {
            _validateExclusiveSolver(context, solver, 1, 33);
            return output.amount;
        }

        _validateExclusiveSolver(context, solver, 1, 33);
        return _dutchOutputAmount(output.amount, context, 33);
    }

    function _outputContextType(bytes memory context) internal pure returns (uint8 contextType) {
        uint256 length = context.length;
        if (length == 0) return OUTPUT_CONTEXT_SIMPLE;

        contextType = uint8(context[0]);
        if (contextType == OUTPUT_CONTEXT_SIMPLE) {
            if (length != 1) revert InvalidOutputContextLength(contextType, length);
        } else if (contextType == OUTPUT_CONTEXT_DUTCH) {
            if (length != 41) revert InvalidOutputContextLength(contextType, length);
        } else if (contextType == OUTPUT_CONTEXT_EXCLUSIVE) {
            if (length != 37) revert InvalidOutputContextLength(contextType, length);
        } else if (contextType == OUTPUT_CONTEXT_EXCLUSIVE_DUTCH) {
            if (length != 73) revert InvalidOutputContextLength(contextType, length);
        } else {
            revert UnknownOutputContext(context[0]);
        }
    }

    function _dutchOutputAmount(uint256 amount, bytes memory context, uint256 startTimeOffset)
        internal
        view
        returns (uint256)
    {
        uint256 startTime = _readUint32(context, startTimeOffset);
        uint256 stopTime = _readUint32(context, startTimeOffset + 4);
        uint256 currentTime = block.timestamp > startTime ? block.timestamp : startTime;
        if (stopTime < currentTime) return amount;

        return amount + _readUint256(context, startTimeOffset + 8) * (stopTime - currentTime);
    }

    function _validateExclusiveSolver(
        bytes memory context,
        bytes32 solver,
        uint256 exclusiveForOffset,
        uint256 startTimeOffset
    ) internal view {
        bytes32 exclusiveFor = _readBytes32(context, exclusiveForOffset);
        if (block.timestamp < _readUint32(context, startTimeOffset) && exclusiveFor != solver) {
            revert ExclusiveForMismatch(exclusiveFor, solver);
        }
    }

    function _outputToken(MandateOutput memory output) internal pure returns (address) {
        if (output.token == bytes32(0)) revert NativeOutputUnsupported();
        return _identifierAddress(output.token);
    }

    function _outputHash(MandateOutput memory output) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                output.oracle,
                output.settler,
                output.chainId,
                output.token,
                output.amount,
                output.recipient,
                keccak256(output.callbackData),
                keccak256(output.context)
            )
        );
    }

    function _inputToken(uint256 tokenId) internal pure returns (address token) {
        token = address(uint160(tokenId));
        if (token == address(0) || tokenId != uint256(uint160(token))) revert InvalidIdentifier();
    }

    function _readUint32(bytes memory data, uint256 offset) internal pure returns (uint32 value) {
        bytes32 word = _readBytes32(data, offset);
        value = uint32(uint256(word >> 224));
    }

    function _readUint256(bytes memory data, uint256 offset) internal pure returns (uint256 value) {
        value = uint256(_readBytes32(data, offset));
    }

    function _readBytes32(bytes memory data, uint256 offset) internal pure returns (bytes32 value) {
        assembly ("memory-safe") {
            value := mload(add(add(data, 0x20), offset))
        }
    }

    function _cleanIdentifier(bytes32 identifier) internal pure returns (bytes32 clean) {
        clean = _addressIdentifier(_identifierAddress(identifier));
    }

    function _addressIdentifier(address addr) internal pure returns (bytes32 identifier) {
        if (addr == address(0)) revert InvalidIdentifier();
        return bytes32(uint256(uint160(addr)));
    }

    function _identifierAddress(bytes32 identifier) internal pure returns (address addr) {
        addr = address(uint160(uint256(identifier)));
        if (addr == address(0) || identifier != bytes32(uint256(uint160(addr)))) revert InvalidIdentifier();
    }

    /* RECEIVE */

    receive() external payable {}
}
