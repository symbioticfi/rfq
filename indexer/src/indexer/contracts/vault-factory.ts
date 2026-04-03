import schema from "ponder:schema";
import { ponder as ponderRegistry } from "ponder:registry";

import { indexerLogger } from "../../lib/logger";
import { mapAddEntityEvent, type AddEntityEvent } from "./vault-factory-event";

type AddEntityIndexingArgs = {
  readonly event: AddEntityEvent;
  readonly context: {
    readonly chain: {
      readonly id: number | bigint | string;
    };
    readonly db: {
      insert(table: typeof schema.vaultFactoryVault): {
        values(value: ReturnType<typeof mapAddEntityEvent>): {
          onConflictDoNothing(): Promise<void>;
        };
      };
    };
  };
};

export function registerEvents(ponder: typeof ponderRegistry) {
  (ponder as any).on(
    "VaultFactory:AddEntity",
    async ({ event, context }: AddEntityIndexingArgs) => {
      const vault = mapAddEntityEvent(Number(context.chain.id), event);

      await context.db
        .insert(schema.vaultFactoryVault)
        .values(vault)
        .onConflictDoNothing();

      indexerLogger.debug(
        {
          chainId: Number(context.chain.id),
          vault: vault.vault,
          txHash: vault.txHash,
        },
        "Indexed vault factory entity",
      );
    },
  );
}
