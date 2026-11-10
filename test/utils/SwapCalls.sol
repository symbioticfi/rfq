// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IExecutor} from "src/interfaces/IExecutor.sol";
import {ILiquidLaneAdapter} from "src/interfaces/ILiquidLaneAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Caller-side test fixtures for explicit funding and swap calls.
library SwapCalls {
    struct Direct {
        address adapter;
        uint256 amountIn;
        uint256 amountOut;
    }

    struct Discounted {
        address adapter;
        uint256 amountIn;
        ILiquidLaneAdapter.DiscountSwap discountSwap;
        bytes protocolSignature;
    }

    struct Plan {
        Direct[] routes;
        Discounted[] discountRoutes;
    }

    function transfer(address token, address recipient, uint256 amount) internal pure returns (IExecutor.Call memory) {
        return IExecutor.Call(token, 0, abi.encodeCall(IERC20.transfer, (recipient, amount)));
    }

    function build(address token, address recipient, Plan memory plan, IExecutor.Call[] memory extra)
        internal
        pure
        returns (IExecutor.Call[] memory calls)
    {
        calls = new IExecutor.Call[](2 * (plan.routes.length + plan.discountRoutes.length) + extra.length);
        uint256 next;
        for (uint256 i; i < plan.routes.length; ++i) {
            Direct memory route = plan.routes[i];
            calls[next++] = transfer(token, route.adapter, route.amountIn);
            calls[next++] = IExecutor.Call(
                route.adapter,
                0,
                abi.encodeWithSignature(
                    "swap((address,address,uint256,uint256))",
                    ILiquidLaneAdapter.Swap(recipient, token, route.amountIn, route.amountOut)
                )
            );
        }
        for (uint256 i; i < plan.discountRoutes.length; ++i) {
            Discounted memory route = plan.discountRoutes[i];
            calls[next++] = transfer(token, route.adapter, route.amountIn);
            calls[next++] = IExecutor.Call(
                route.adapter,
                0,
                abi.encodeWithSignature(
                    "swap(((address,uint256,address,address,uint256,uint48),bytes,uint48),bytes,address,uint256)",
                    route.discountSwap,
                    route.protocolSignature,
                    recipient,
                    route.amountIn
                )
            );
        }
        for (uint256 i; i < extra.length; ++i) {
            calls[next++] = extra[i];
        }
    }
}
