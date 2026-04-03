import { concatHex, encodeAbiParameters, encodeFunctionData, toFunctionSelector } from "viem";

import { erc20Abi, executorFillMixedParameters } from "./contracts";
import type { ExecutorCall, ReactorDiscountSwapInput, ReactorOrder, ReactorSwap } from "../types/domain";

/**
 * @dev Encodes an ERC20 approval call used inside executor callback payloads.
 * @param token The ERC20 token to approve.
 * @param spender The spender/router address.
 * @param amount The approval amount.
 * @returns The executor call.
 */
export function buildApproveCall(token: `0x${string}`, spender: `0x${string}`, amount: bigint): ExecutorCall {
  return {
    target: token,
    value: 0n,
    data: encodeFunctionData({
      abi: erc20Abi,
      functionName: "approve",
      args: [spender, amount],
    }),
  };
}

/**
 * @dev Encodes an arbitrary downstream router call for executor execution.
 * @param target The call target.
 * @param data The call data.
 * @param value The native value.
 * @returns The executor call.
 */
export function buildTargetCall(target: `0x${string}`, data: `0x${string}`, value: bigint): ExecutorCall {
  return {
    target,
    value,
    data,
  };
}

/**
 * @dev Encodes the mixed-leg `Executor.fill(...)` overload.
 * @param order The Reactor order.
 * @param protocolSignature The protocol signature.
 * @param swapInputs Direct adapter swap legs.
 * @param discountSwapInputs Discount-backed adapter swap legs.
 * @param executorData The encoded executor callback payload.
 * @returns ABI calldata for the executor fill.
 */
export function encodeExecutorFill(
  order: ReactorOrder,
  protocolSignature: `0x${string}`,
  swapInputs: readonly ReactorSwap[],
  discountSwapInputs: readonly ReactorDiscountSwapInput[],
  executorData: `0x${string}`,
) {
  return concatHex([
    toFunctionSelector(
      "fill(((address,uint256,(address,uint256,address)[],uint256,uint256,address),bytes,address,address),bytes,(address,address,address,uint256,uint256)[],(((address,address,uint256,address,address,uint256,uint48),bytes,uint48),bytes,address,uint256,uint256)[],bytes)",
    ),
    encodeAbiParameters(executorFillMixedParameters, [
      order,
      protocolSignature,
      [...swapInputs],
      [...discountSwapInputs],
      executorData,
    ]),
  ]);
}
