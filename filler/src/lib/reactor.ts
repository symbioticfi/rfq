import { decodeAbiParameters, encodeAbiParameters, getAddress } from "viem";

import { executorCallEncodingParameters, reactorOrderEncodingParameters } from "./contracts";
import type { ExecutorCall, ReactorOrder } from "../types/domain";

export const NATIVE = "0x0000000000000000000000000000000000000000";

function normalizeAddress(value: `0x${string}`): `0x${string}` {
  return getAddress(value).toLowerCase() as `0x${string}`;
}

/**
 * @dev Decodes a backend-provided ABI-encoded Reactor order.
 * @param encodedOrder The ABI-encoded order bytes.
 * @returns The decoded Reactor order.
 */
export function decodeOrder(encodedOrder: `0x${string}`): ReactorOrder {
  const [decoded] = decodeAbiParameters(reactorOrderEncodingParameters, encodedOrder);

  return {
    request: {
      tokenIn: normalizeAddress(decoded.request.tokenIn),
      amountIn: decoded.request.amountIn,
      outputs: decoded.request.outputs.map((output) => ({
        token: normalizeAddress(output.token),
        amount: output.amount,
        recipient: normalizeAddress(output.recipient),
      })),
      deadline: decoded.request.deadline,
      nonce: decoded.request.nonce,
      protocol: normalizeAddress(decoded.request.protocol),
    },
    swapperSignature: decoded.swapperSignature,
    swapper: normalizeAddress(decoded.swapper),
    filler: normalizeAddress(decoded.filler),
  };
}

/**
 * @dev Encodes a Reactor order for local tests and executor submission helpers.
 * @param order The Reactor order.
 * @returns The ABI-encoded order bytes.
 */
export function encodeOrder(order: ReactorOrder): `0x${string}` {
  return encodeAbiParameters(reactorOrderEncodingParameters, [order]);
}

/**
 * @dev Encodes executor callback calls into the tuple-array payload expected by `Executor.execute`.
 * @param calls The executor calls.
 * @returns ABI-encoded executor data.
 */
export function encodeExecutorData(calls: readonly ExecutorCall[]): `0x${string}` {
  return encodeAbiParameters(executorCallEncodingParameters, [[...calls]]);
}
