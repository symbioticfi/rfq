import { normalizeAddress } from "../../lib/ponder";

export type AddEntityEvent = {
  readonly transaction: {
    readonly hash: `0x${string}`;
  };
  readonly block: {
    readonly number: bigint;
  };
  readonly args: {
    readonly entity: `0x${string}`;
  };
};

export function mapAddEntityEvent(chainId: number, event: AddEntityEvent) {
  const vault = normalizeAddress(event.args.entity);

  return {
    id: `${chainId}:${vault}`,
    chainId,
    vault,
    blockNumber: event.block.number,
    txHash: event.transaction.hash,
  };
}
