import { normalizeAddress } from "../../lib/ponder";

export type SetFillerEvent = {
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
    readonly marketMaker: `0x${string}`;
    readonly filler: `0x${string}`;
    readonly isAuthorized: boolean;
  };
};

export function mapSetFillerEvent(chainId: number, event: SetFillerEvent) {
  const marketMaker = normalizeAddress(event.args.marketMaker);
  const filler = normalizeAddress(event.args.filler);

  return {
    id: `${chainId}:${marketMaker}:${filler}`,
    chainId,
    marketMaker,
    filler,
    status: event.args.isAuthorized,
    txHash: event.transaction.hash,
    blockNumber: Number(event.block.number),
    logIndex: Number(event.log.logIndex),
  };
}
