import type { mapReactorFillEvent } from "./reactor-event";

type ReactorFill = ReturnType<typeof mapReactorFillEvent>["fill"];
type ReactorFillOutput = ReturnType<typeof mapReactorFillEvent>["outputs"][number];

type InsertableTable = unknown;

type ReactorFillDb = {
  sql: {
    insert(table: InsertableTable): {
      values(value: ReactorFill | ReactorFillOutput): {
        onConflictDoNothing(): Promise<void>;
      };
    };
  };
};

/**
 * Persists a mapped Reactor fill and its output rows.
 *
 * Output rows are inserted one-by-one because the live Ponder runtime path for
 * the composite-key output table is not reliable with bulk inserts.
 */
export async function persistReactorFill(
  db: ReactorFillDb,
  reactorFillTable: InsertableTable,
  reactorFillOutputTable: InsertableTable,
  fill: ReactorFill,
  outputs: readonly ReactorFillOutput[],
) {
  await db.sql.insert(reactorFillTable).values(fill).onConflictDoNothing();

  for (const output of outputs) {
    await db.sql.insert(reactorFillOutputTable).values(output).onConflictDoNothing();
  }
}
