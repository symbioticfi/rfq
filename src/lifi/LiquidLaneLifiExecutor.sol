// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.28;

import {DISCOUNT_PRECISION, ILiquidLaneAdapter} from "../interfaces/ILiquidLaneAdapter.sol";
import {IInputSettler} from "./interfaces/IInputSettler.sol";
import {ILiquidLaneLifiExecutor} from "./interfaces/ILiquidLaneLifiExecutor.sol";
import {IOutputSettler, MandateOutput} from "./interfaces/IOutputSettler.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

interface ILiquidLaneRate {
    function getAmountOut(address tokenToRedeem, uint256 amountIn) external view returns (uint256 amountOut);
    function getMaxAssets(address tokenToRedeem) external returns (uint256 assets);
    function minDiscount(address tokenToRedeem) external view returns (uint256 ppm);
}

/// @title LiquidLaneLifiExecutor
/// @notice LI.FI same-chain solver that redeems released inputs and fills the order output atomically.
contract LiquidLaneLifiExecutor is Ownable, ReentrancyGuard, ILiquidLaneLifiExecutor {
    using Address for address payable;
    using Math for uint256;
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

    /* CONSTRUCTOR */

    constructor(address inputSettler, address outputSettler, address owner_) Ownable(owner_) {
        if (inputSettler == address(0) || outputSettler == address(0) || owner_ == address(0)) revert ZeroAddress();

        INPUT_SETTLER = inputSettler;
        OUTPUT_SETTLER = outputSettler;
    }

    /* FINALISE WRAPPER */

    /// @inheritdoc ILiquidLaneLifiExecutor
    function expectedOutput(ILiquidLaneLifiExecutor.FillCall calldata fillCall)
        external
        pure
        returns (uint256 expectedAmountOut)
    {
        for (uint256 i; i < fillCall.routes.length; ++i) {
            expectedAmountOut += fillCall.routes[i].expectedAmountOut;
        }
    }

    /// @inheritdoc ILiquidLaneLifiExecutor
    function finaliseWithCurrentTimestamp(IInputSettler.StandardOrder calldata order, bytes calldata call)
        external
        onlyOwner
    {
        ILiquidLaneLifiExecutor.FillCall memory fillCall = abi.decode(call, (ILiquidLaneLifiExecutor.FillCall));
        bytes32 orderId = _validateFinaliseCall(order, fillCall);

        uint8 orderState = IInputSettler(INPUT_SETTLER).orderStatus(orderId);
        if (orderState != ORDER_STATUS_DEPOSITED) revert InvalidOrderStatus(orderState);

        bytes32 executorId = _addressIdentifier(address(this));
        IInputSettler.SolveParams[] memory solveParams = new IInputSettler.SolveParams[](1);
        solveParams[0] = IInputSettler.SolveParams({timestamp: uint32(block.timestamp), solver: executorId});

        IInputSettler(INPUT_SETTLER).finalise(order, solveParams, executorId, call);
    }

    /* IINPUTCALLBACK */

    /// @notice Called by the LI.FI input settler during finalise, after inputs are transferred here.
    function orderFinalised(uint256[2][] calldata inputs, bytes calldata executionData) external nonReentrant {
        if (msg.sender != INPUT_SETTLER) revert NotInputSettler();
        if (inputs.length != 1) revert InvalidInputCount();

        ILiquidLaneLifiExecutor.FillCall memory fillCall = abi.decode(executionData, (ILiquidLaneLifiExecutor.FillCall));
        _validateFillAfter(fillCall.fillAfter, fillCall.output.context);

        bytes32 solver = _addressIdentifier(address(this));
        uint256 resolvedAmountOut = _resolveOutputAmount(fillCall.output, solver);
        _validateOutput(fillCall.output);
        address outputToken = _outputToken(fillCall.output);

        uint8 status = IInputSettler(INPUT_SETTLER).orderStatus(fillCall.orderId);
        if (status != ORDER_STATUS_CLAIMED) revert InvalidOrderStatus(status);

        address tokenIn = _inputToken(inputs[0][0]);
        uint256 amountIn = inputs[0][1];
        if (amountIn == 0) revert InvalidAmount();

        (uint256 minAmountOut, uint256[] memory executableAmountOuts) =
            _validateRoutes(fillCall.routes, tokenIn, amountIn);
        if (resolvedAmountOut > minAmountOut) {
            revert InsufficientMinimumOutput(minAmountOut, resolvedAmountOut);
        }

        uint256 outputGained = _redeemInputs(fillCall, tokenIn, outputToken, executableAmountOuts);
        uint256 surplus = outputGained - resolvedAmountOut;

        IERC20(outputToken).forceApprove(OUTPUT_SETTLER, resolvedAmountOut);
        IOutputSettler(OUTPUT_SETTLER)
            .fill(fillCall.orderId, fillCall.output, fillCall.fillDeadline, abi.encode(solver));
        IOutputSettler(OUTPUT_SETTLER)
            .setAttestation(fillCall.orderId, solver, uint32(block.timestamp), fillCall.output);

        emit OutputFilled(
            fillCall.orderId,
            solver,
            outputToken,
            _identifierAddress(fillCall.output.recipient),
            resolvedAmountOut,
            surplus
        );
    }

    /* OWNER */

    /// @inheritdoc ILiquidLaneLifiExecutor
    function sweepERC20(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (token == address(0) || to == address(0)) revert ZeroAddress();

        IERC20(token).safeTransfer(to, amount);
        emit SweepERC20(token, to, amount);
    }

    /// @inheritdoc ILiquidLaneLifiExecutor
    function sweepNative(address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();

        payable(to).sendValue(amount);
        emit SweepNative(to, amount);
    }

    /* EIP-1271 */

    /// @inheritdoc IERC1271
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        if (SignatureChecker.isValidSignatureNow(owner(), hash, signature)) {
            return IERC1271.isValidSignature.selector;
        }
        return 0xffffffff;
    }

    /* INTERNAL */

    function _validateFinaliseCall(
        IInputSettler.StandardOrder calldata order,
        ILiquidLaneLifiExecutor.FillCall memory fillCall
    ) internal view returns (bytes32 orderId) {
        _validateFillAfter(fillCall.fillAfter, fillCall.output.context);

        orderId = IInputSettler(INPUT_SETTLER).orderIdentifier(order);
        if (fillCall.orderId != orderId) revert InvalidOrderId();
        if (order.inputs.length != 1) revert InvalidInputCount();
        if (order.outputs.length != 1) revert InvalidOutputCount();
        if (
            fillCall.fillDeadline != order.fillDeadline || _outputHash(fillCall.output) != _outputHash(order.outputs[0])
        ) {
            revert InvalidOrderOutput();
        }

        _validateOutput(fillCall.output);
    }

    function _redeemInputs(
        ILiquidLaneLifiExecutor.FillCall memory fillCall,
        address tokenIn,
        address outputToken,
        uint256[] memory executableAmountOuts
    ) internal returns (uint256 outputGained) {
        for (uint256 i; i < fillCall.routes.length; ++i) {
            IERC20(tokenIn).safeTransfer(fillCall.routes[i].adapter, fillCall.routes[i].amountIn);
        }

        for (uint256 i; i < fillCall.routes.length; ++i) {
            ILiquidLaneLifiExecutor.FillRoute memory route = fillCall.routes[i];
            uint256 outputBefore = IERC20(outputToken).balanceOf(address(this));
            if (route.discount.discountId == bytes32(0)) {
                ILiquidLaneAdapter(route.adapter)
                    .swap(
                        ILiquidLaneAdapter.Swap({
                        recipient: address(this),
                        tokenIn: tokenIn,
                        amountIn: route.amountIn,
                        amountOut: executableAmountOuts[i]
                    })
                    );
            } else {
                ILiquidLaneAdapter(route.adapter)
                    .swap(route.discount.discountSwap, route.discount.protocolSignature, address(this), route.amountIn);
            }

            uint256 routeOutput = IERC20(outputToken).balanceOf(address(this)) - outputBefore;
            if (routeOutput < route.minAmountOut) {
                revert RouteOutputTooLow(route.adapter, route.minAmountOut, routeOutput);
            }
            outputGained += routeOutput;

            emit InputRedeemed(
                fillCall.orderId,
                route.adapter,
                tokenIn,
                outputToken,
                route.amountIn,
                routeOutput,
                route.discount.discountId
            );
        }
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

    function _validateRoutes(ILiquidLaneLifiExecutor.FillRoute[] memory routes, address tokenIn, uint256 orderAmountIn)
        internal
        returns (uint256 minAmountOut, uint256[] memory executableAmountOuts)
    {
        if (routes.length == 0) revert EmptyRoutes();

        executableAmountOuts = new uint256[](routes.length);
        uint256 routedAmountIn;
        for (uint256 i; i < routes.length; ++i) {
            ILiquidLaneLifiExecutor.FillRoute memory route = routes[i];
            if (route.amountIn == 0) revert InvalidAmount();
            if (route.minAmountOut == 0 || route.minAmountOut > route.expectedAmountOut) {
                revert InvalidRouteOutputBounds(route.expectedAmountOut, route.minAmountOut);
            }
            if (route.adapter == address(0)) revert ZeroAddress();

            (uint256 currentAmountOut, uint256 maxAssets) = _routeState(route, tokenIn);
            uint256 executableAmountOut = _executableAmountOut(route, currentAmountOut, maxAssets);
            if (executableAmountOut < route.minAmountOut) {
                revert RouteOutputTooLow(route.adapter, route.minAmountOut, executableAmountOut);
            }

            routedAmountIn += route.amountIn;
            minAmountOut += route.minAmountOut;
            executableAmountOuts[i] = executableAmountOut;
        }
        if (routedAmountIn != orderAmountIn) revert RouteInputMismatch(routedAmountIn, orderAmountIn);
    }

    function _executableAmountOut(
        ILiquidLaneLifiExecutor.FillRoute memory route,
        uint256 currentAmountOut,
        uint256 maxAssets
    ) internal pure returns (uint256) {
        if (route.discount.discountId == bytes32(0)) {
            return Math.min(route.expectedAmountOut, Math.min(currentAmountOut, maxAssets));
        }
        if (currentAmountOut > maxAssets) {
            revert PrivateRouteExceedsCapacity(route.adapter, currentAmountOut, maxAssets);
        }
        return currentAmountOut;
    }

    function _routeState(ILiquidLaneLifiExecutor.FillRoute memory route, address tokenIn)
        internal
        returns (uint256 amountOut, uint256 maxAssets)
    {
        uint256 minimumDiscount = ILiquidLaneRate(route.adapter).minDiscount(tokenIn);
        uint256 discount = minimumDiscount;
        if (route.discount.discountId != bytes32(0)) {
            ILiquidLaneAdapter.Discount memory terms = route.discount.discountSwap.discount;
            if (terms.tokenToRedeem != tokenIn) revert DiscountTokenMismatch(tokenIn, terms.tokenToRedeem);
            if (terms.deadline < block.timestamp || route.discount.discountSwap.protocolDeadline < block.timestamp) {
                revert DiscountExpired(terms.deadline, route.discount.discountSwap.protocolDeadline, block.timestamp);
            }
            discount = terms.discount;
            if (discount < minimumDiscount || discount > DISCOUNT_PRECISION) {
                revert InvalidDiscount(discount, minimumDiscount);
            }
        }

        amountOut = ILiquidLaneRate(route.adapter).getAmountOut(tokenIn, route.amountIn)
            .mulDiv(DISCOUNT_PRECISION - discount, DISCOUNT_PRECISION);
        maxAssets = ILiquidLaneRate(route.adapter).getMaxAssets(tokenIn);
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
        // High bits are rejected by the equality check below.
        // forge-lint: disable-next-line(unsafe-typecast)
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
