import { normalizeAddress } from "../../lib/ponder";

export type InvalidateNonceEvent = {
  readonly transaction: {
    readonly hash: `0x${string}`;
  };
  readonly log: {
    readonly logIndex: number;
  };
  readonly block: {
    readonly number: bigint;
  };
  readonly args: {
    readonly vault: `0x${string}`;
    readonly tokenToRedeem: `0x${string}`;
    readonly nonce: bigint;
  };
};

export function mapInvalidateNonceEvent(chainId: number, event: InvalidateNonceEvent) {
  const vault = normalizeAddress(event.args.vault);
  const tokenToRedeem = normalizeAddress(event.args.tokenToRedeem);

  return {
    id: `${chainId}:${vault}:${tokenToRedeem}:${event.args.nonce.toString()}`,
    chainId,
    vault,
    tokenToRedeem,
    nonce: event.args.nonce,
    txHash: event.transaction.hash,
    blockNumber: Number(event.block.number),
    logIndex: Number(event.log.logIndex),
  };
}
