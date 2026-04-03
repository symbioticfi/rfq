import { normalizeAddress } from "../../lib/ponder";
import { hashOrder } from "../../lib/reactor";

type ReactorFillEvent = {
  readonly transaction: {
    readonly hash: `0x${string}`;
  };
  readonly log: {
    readonly logIndex: number;
  };
  readonly block: {
    readonly number: bigint;
    readonly timestamp: bigint;
  };
  readonly args: {
    readonly order: {
      readonly swapperSignature: `0x${string}`;
      readonly swapper: `0x${string}`;
      readonly filler: `0x${string}`;
      readonly request: {
        readonly tokenIn: `0x${string}`;
        readonly amountIn: bigint;
        readonly deadline: bigint;
        readonly nonce: bigint;
        readonly protocol: `0x${string}`;
        readonly outputs: readonly {
          readonly token: `0x${string}`;
          readonly amount: bigint;
          readonly recipient: `0x${string}`;
        }[];
      };
    };
  };
};

/**
 * @dev Maps a Reactor `Fill(Order)` event into indexer table rows.
 * @param chainId The indexed chain id.
 * @param event The decoded Reactor fill event.
 * @returns The normalized fill row and output rows.
 */
export function mapReactorFillEvent(chainId: number, event: ReactorFillEvent) {
  const fillId = `${chainId}:${event.transaction.hash}:${event.log.logIndex}`;
  const order = event.args.order;
  const orderHash = hashOrder({
    request: {
      tokenIn: normalizeAddress(order.request.tokenIn),
      amountIn: order.request.amountIn,
      outputs: order.request.outputs.map((output) => ({
        token: normalizeAddress(output.token),
        amount: output.amount,
        recipient: normalizeAddress(output.recipient),
      })),
      deadline: order.request.deadline,
      nonce: order.request.nonce,
      protocol: normalizeAddress(order.request.protocol),
    },
    swapperSignature: order.swapperSignature,
    swapper: normalizeAddress(order.swapper),
    filler: normalizeAddress(order.filler),
  });

  return {
    fill: {
      id: fillId,
      chainId,
      blockNumber: event.block.number,
      blockTimestamp: event.block.timestamp,
      txHash: event.transaction.hash,
      logIndex: Number(event.log.logIndex),
      orderHash,
      swapper: normalizeAddress(order.swapper),
      filler: normalizeAddress(order.filler),
      tokenIn: normalizeAddress(order.request.tokenIn),
      amountIn: order.request.amountIn,
      deadline: order.request.deadline,
      nonce: order.request.nonce,
      protocol: normalizeAddress(order.request.protocol),
      swapperSignature: order.swapperSignature,
    },
    outputs: order.request.outputs.map((output, outputIndex) => ({
      fillId,
      outputIndex,
      token: normalizeAddress(output.token),
      recipient: normalizeAddress(output.recipient),
      amount: output.amount,
    })),
  };
}
