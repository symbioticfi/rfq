// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.0;

import {IInputCallback} from "./IInputCallback.sol";
import {IInputSettler} from "./IInputSettler.sol";
import {MandateOutput} from "./IOutputSettler.sol";
import {ILiquidLaneAdapter} from "../../interfaces/ILiquidLaneAdapter.sol";

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

/**
 * @title ILiquidLaneLifiExecutor
 * @notice LI.FI same-chain solver and executor callback for on-chain orders.
 */
interface ILiquidLaneLifiExecutor is IInputCallback, IERC1271 {
    /* ERRORS */

    error NotCaller();
    error NotInputSettler();

    /* EVENTS */

    event SetCallers(address[] newCallers);

    /* STRUCTS */

    /**
     * @notice One atomic direct-swap LiquidLane redemption leg.
     * @param adapter LiquidLane adapter selected by the solver.
     * @param amountIn Order-input amount routed to the adapter.
     * @param amountOut Output amount requested from the adapter.
     */
    struct FillRoute {
        address adapter;
        uint256 amountIn;
        uint256 amountOut;
    }

    /**
     * @notice One atomic discount-backed LiquidLane redemption leg.
     * @param adapter LiquidLane adapter selected by the solver.
     * @param amountIn Order-input amount routed to the adapter.
     * @param discountSwap Reusable signer policy plus the fresh protocol deadline.
     * @param protocolSignature Fresh protocol cosign verified by the LiquidLane adapter.
     */
    struct DiscountRoute {
        address adapter;
        uint256 amountIn;
        ILiquidLaneAdapter.DiscountSwap discountSwap;
        bytes protocolSignature;
    }

    /**
     * @notice Callback payload constructed by `finaliseWithCurrentTimestamp` from the order itself.
     * @param orderId OIF order id.
     * @param output Single output to fill and attest.
     * @param fillDeadline Fill deadline carried by the order.
     * @param routes Direct-swap LiquidLane legs selected by the solver.
     * @param discountRoutes Discount-backed LiquidLane legs selected by the solver.
     */
    struct FillCall {
        bytes32 orderId;
        MandateOutput output;
        uint32 fillDeadline;
        FillRoute[] routes;
        DiscountRoute[] discountRoutes;
    }

    /* FUNCTIONS */

    function INPUT_SETTLER() external view returns (address inputSettler);
    function OUTPUT_SETTLER() external view returns (address outputSettler);
    function callers(uint256 index) external view returns (address caller);
    function initialize(address owner, address[] calldata initCallers) external;
    function finaliseWithCurrentTimestamp(
        IInputSettler.StandardOrder calldata order,
        FillRoute[] calldata routes,
        DiscountRoute[] calldata discountRoutes
    ) external;
    function isCaller(address caller) external view returns (bool allowed);
    function lifiRegistrationDigest(bytes32 messageHash) external view returns (bytes32 digest);
    function setCallers(address[] calldata newCallers) external;
}
