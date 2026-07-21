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

    error NotInputSettler();

    /* STRUCTS */

    /**
     * @notice Optional private-discount authorization for one route.
     * @param discountId Backend discount identifier; zero selects the direct swap path.
     * @param discountSwap Reusable signer policy plus the fresh protocol deadline.
     * @param protocolSignature Fresh protocol cosign verified by the LiquidLane adapter.
     */
    struct FillDiscount {
        bytes32 discountId;
        ILiquidLaneAdapter.DiscountSwap discountSwap;
        bytes protocolSignature;
    }

    /**
     * @notice One atomic LiquidLane redemption leg.
     * @param adapter LiquidLane adapter selected by the solver.
     * @param amountIn Order-input amount routed to the adapter.
     * @param amountOut Output amount requested from the adapter on the direct swap path;
     * unused for discount routes, where the signed discount terms set the output.
     * @param discount Optional private-discount authorization; zero id means direct swap.
     */
    struct FillRoute {
        address adapter;
        uint256 amountIn;
        uint256 amountOut;
        FillDiscount discount;
    }

    /**
     * @notice Callback payload constructed by `finaliseWithCurrentTimestamp` from the order itself.
     * @param orderId OIF order id.
     * @param output Single output to fill and attest.
     * @param fillDeadline Fill deadline carried by the order.
     * @param routes LiquidLane legs selected by the solver.
     */
    struct FillCall {
        bytes32 orderId;
        MandateOutput output;
        uint32 fillDeadline;
        FillRoute[] routes;
    }

    /* FUNCTIONS */

    function INPUT_SETTLER() external view returns (address inputSettler);
    function OUTPUT_SETTLER() external view returns (address outputSettler);
    function initialize(address owner) external;
    function finaliseWithCurrentTimestamp(IInputSettler.StandardOrder calldata order, FillRoute[] calldata routes)
        external;
}
