import schema from "ponder:schema";
import { ponder as ponderRegistry } from "ponder:registry";
import type { IndexingFunctionArgs } from "ponder:registry";

import { indexerLogger } from "../../lib/logger";
import { mapReactorFillEvent } from "./reactor-event";
import { persistReactorFill } from "./reactor-store";

/**
 * @dev Registers Reactor fill indexing handlers.
 * @param ponder The Ponder registry.
 */
export function registerEvents(ponder: typeof ponderRegistry) {
  ponder.on("Reactor:Fill", async ({ event, context }: IndexingFunctionArgs<"Reactor:Fill">) => {
    const chainId = Number(context.chain.id);
    const { fill, outputs } = mapReactorFillEvent(chainId, event);

    await persistReactorFill(context.db as never, schema.reactorFill, schema.reactorFillOutput, fill, outputs);

    indexerLogger.debug(
      {
        chainId,
        fillId: fill.id,
        orderHash: fill.orderHash,
        txHash: fill.txHash,
        outputs: outputs.length,
      },
      "Indexed reactor fill",
    );
  });
}
