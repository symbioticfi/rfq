// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.38;

import {Executor} from "src/Executor.sol";
import {IExecutor} from "src/interfaces/IExecutor.sol";
import {IReactor} from "src/interfaces/IReactor.sol";

/// @dev Models a filler's calldata construction; Executor itself only runs the supplied calls.
library ExecutorCalls {
    function fill(
        Executor executor,
        IReactor.Order memory order,
        bytes memory signature,
        IReactor.SwapInput memory input,
        bytes memory extraCalls
    ) internal {
        IReactor.SwapInput[] memory inputs = new IReactor.SwapInput[](1);
        inputs[0] = input;
        fill(executor, order, signature, inputs, extraCalls);
    }

    function fill(
        Executor executor,
        IReactor.Order memory order,
        bytes memory signature,
        IReactor.SwapInput[] memory inputs,
        bytes memory extraCalls
    ) internal {
        fill(executor, order, signature, inputs, new IReactor.DiscountSwapInput[](0), extraCalls);
    }

    function fill(
        Executor executor,
        IReactor.Order memory order,
        bytes memory signature,
        IReactor.SwapInput[] memory inputs,
        IReactor.DiscountSwapInput[] memory discounts,
        bytes memory extraCalls
    ) internal {
        executor.fill(
            order, signature, inputs, discounts, encode(inputs, discounts, abi.decode(extraCalls, (IExecutor.Call[])))
        );
    }

    function encode(
        IReactor.SwapInput[] memory inputs,
        IReactor.DiscountSwapInput[] memory discounts,
        IExecutor.Call[] memory extraCalls
    ) internal pure returns (bytes memory) {
        IExecutor.Call[] memory calls = new IExecutor.Call[](inputs.length + discounts.length + extraCalls.length);
        uint256 next;
        for (uint256 i; i < inputs.length; ++i) {
            calls[next++] = IExecutor.Call({
                target: inputs[i].adapter,
                value: 0,
                data: abi.encodeWithSignature("swap((address,address,uint256,uint256))", inputs[i].swap)
            });
        }
        for (uint256 i; i < discounts.length; ++i) {
            calls[next++] = IExecutor.Call({
                target: discounts[i].adapter,
                value: 0,
                data: abi.encodeWithSignature(
                    "swap(((address,uint256,address,address,uint256,uint48),bytes,uint48),bytes,address,uint256)",
                    discounts[i].discountSwap,
                    discounts[i].protocolSignature,
                    discounts[i].recipient,
                    discounts[i].amountIn
                )
            });
        }
        for (uint256 i; i < extraCalls.length; ++i) {
            calls[next++] = extraCalls[i];
        }
        return abi.encode(calls);
    }
}
