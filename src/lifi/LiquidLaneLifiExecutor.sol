// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.28;

import {ILiquidLaneAdapter} from "../interfaces/ILiquidLaneAdapter.sol";
import {IInputSettler} from "./interfaces/IInputSettler.sol";
import {ILiquidLaneLifiExecutor} from "./interfaces/ILiquidLaneLifiExecutor.sol";
import {IOutputSettler} from "./interfaces/IOutputSettler.sol";

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @title LiquidLaneLifiExecutor
/// @notice LI.FI same-chain solver that redeems released inputs and fills the order output atomically.
/// @dev Order lifecycle, fill deadlines, auction pricing, exclusivity, and discount terms are delegated
/// to the input settler, the output settler, and the LiquidLane adapters, which enforce them
/// authoritatively; the executor only routes the received inputs and settles the generated output.
/// @dev Deployed behind a transparent proxy; the settler addresses are immutable in the implementation
/// while ownership lives in proxy storage set by {initialize}.
contract LiquidLaneLifiExecutor is Initializable, OwnableUpgradeable, ILiquidLaneLifiExecutor {
    using SafeERC20 for IERC20;

    /* IMMUTABLES */

    /// @inheritdoc ILiquidLaneLifiExecutor
    address public immutable INPUT_SETTLER;
    /// @inheritdoc ILiquidLaneLifiExecutor
    address public immutable OUTPUT_SETTLER;

    /* CONSTRUCTOR */

    constructor(address inputSettler, address outputSettler) {
        INPUT_SETTLER = inputSettler;
        OUTPUT_SETTLER = outputSettler;
        _disableInitializers();
    }

    /// @inheritdoc ILiquidLaneLifiExecutor
    function initialize(address owner_) external initializer {
        __Ownable_init(owner_);
    }

    /* FINALISE WRAPPER */

    /// @inheritdoc ILiquidLaneLifiExecutor
    function finaliseWithCurrentTimestamp(IInputSettler.StandardOrder calldata order, FillRoute[] calldata routes)
        external
        onlyOwner
    {
        bytes32 executorId = bytes32(uint256(uint160(address(this))));
        IInputSettler.SolveParams[] memory solveParams = new IInputSettler.SolveParams[](1);
        solveParams[0] = IInputSettler.SolveParams({timestamp: uint32(block.timestamp), solver: executorId});
        IInputSettler(INPUT_SETTLER)
            .finalise(
                order,
                solveParams,
                executorId,
                abi.encode(
                    FillCall({
                    orderId: IInputSettler(INPUT_SETTLER).orderIdentifier(order),
                    output: order.outputs[0],
                    fillDeadline: order.fillDeadline,
                    routes: routes
                })
                )
            );
    }

    /* IINPUTCALLBACK */

    /// @notice Called by the LI.FI input settler during finalise, after inputs are transferred here.
    function orderFinalised(uint256[2][] calldata inputs, bytes calldata executionData) external {
        if (INPUT_SETTLER != msg.sender) revert NotInputSettler();

        FillCall memory fillCall = abi.decode(executionData, (FillCall));

        // Adapters assume their input has already been transferred to them before the swap call.
        // forge-lint: disable-next-line(unsafe-typecast)
        address tokenIn = address(uint160(inputs[0][0]));
        uint256 routesLength = fillCall.routes.length;
        for (uint256 i; i < routesLength; ++i) {
            IERC20(tokenIn).safeTransfer(fillCall.routes[i].adapter, fillCall.routes[i].amountIn);
        }

        for (uint256 i; i < routesLength; ++i) {
            FillRoute memory route = fillCall.routes[i];
            if (route.discount.discountId == bytes32(0)) {
                ILiquidLaneAdapter(route.adapter)
                    .swap(
                        ILiquidLaneAdapter.Swap({
                        recipient: address(this), tokenIn: tokenIn, amountIn: route.amountIn, amountOut: route.amountOut
                    })
                    );
            } else {
                ILiquidLaneAdapter(route.adapter)
                    .swap(route.discount.discountSwap, route.discount.protocolSignature, address(this), route.amountIn);
            }
        }

        // The output settler resolves the context-dependent amount it is owed and pulls it,
        // reverting on shortfall.
        address outputToken = address(uint160(uint256(fillCall.output.token)));
        if (IERC20(outputToken).allowance(address(this), OUTPUT_SETTLER) < type(uint256).max) {
            IERC20(outputToken).forceApprove(OUTPUT_SETTLER, type(uint256).max);
        }
        bytes32 solver = bytes32(uint256(uint160(address(this))));
        IOutputSettler(OUTPUT_SETTLER)
            .fill(fillCall.orderId, fillCall.output, fillCall.fillDeadline, abi.encode(solver));
        IOutputSettler(OUTPUT_SETTLER)
            .setAttestation(fillCall.orderId, solver, uint32(block.timestamp), fillCall.output);
    }

    /* EIP-1271 */

    /// @inheritdoc IERC1271
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        if (SignatureChecker.isValidSignatureNow(owner(), hash, signature)) {
            return IERC1271.isValidSignature.selector;
        }
        return 0xffffffff;
    }
}
