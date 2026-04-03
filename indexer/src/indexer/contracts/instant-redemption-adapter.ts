import schema from "ponder:schema";
import { ponder as ponderRegistry } from "ponder:registry";

import { indexerLogger } from "../../lib/logger";
import { mapSetFillerEvent, type SetFillerEvent } from "./filler-authorization-event";
import { mapInvalidateNonceEvent, type InvalidateNonceEvent } from "./invalidated-nonce-event";
import { persistFillerAuthorization, persistInvalidatedNonce } from "./instant-redemption-adapter-store";

type SetFillerIndexingArgs = {
  readonly event: SetFillerEvent;
  readonly context: {
    readonly chain: {
      readonly id: number | bigint | string;
    };
    readonly db: unknown;
  };
};

type InvalidateNonceIndexingArgs = {
  readonly event: InvalidateNonceEvent;
  readonly context: {
    readonly chain: {
      readonly id: number | bigint | string;
    };
    readonly db: unknown;
  };
};

export function registerEvents(ponder: typeof ponderRegistry) {
  (ponder as any).on(
    "InstantRedemptionAdapter:SetFiller",
    async ({ event, context }: SetFillerIndexingArgs) => {
      const authorization = mapSetFillerEvent(Number(context.chain.id), event);

      await persistFillerAuthorization(
        context.db as never,
        schema.instantRedemptionAdapterFillerAuthorization,
        authorization,
      );

      indexerLogger.debug(
        {
          chainId: Number(context.chain.id),
          marketMaker: authorization.marketMaker,
          filler: authorization.filler,
          status: authorization.status,
          txHash: authorization.txHash,
        },
        "Indexed filler authorization state",
      );
    },
  );

  (ponder as any).on(
    "InstantRedemptionAdapter:InvalidateNonce",
    async ({ event, context }: InvalidateNonceIndexingArgs) => {
      const invalidatedNonce = mapInvalidateNonceEvent(Number(context.chain.id), event);

      await persistInvalidatedNonce(
        context.db as never,
        schema.instantRedemptionAdapterInvalidatedNonce,
        invalidatedNonce,
      );

      indexerLogger.debug(
        {
          chainId: Number(context.chain.id),
          vault: invalidatedNonce.vault,
          tokenToRedeem: invalidatedNonce.tokenToRedeem,
          nonce: invalidatedNonce.nonce,
          txHash: invalidatedNonce.txHash,
        },
        "Indexed invalidated adapter nonce",
      );
    },
  );
}
