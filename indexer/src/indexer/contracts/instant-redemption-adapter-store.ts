import type { mapInvalidateNonceEvent } from "./invalidated-nonce-event";
import type { mapSetFillerEvent } from "./filler-authorization-event";

type FillerAuthorization = ReturnType<typeof mapSetFillerEvent>;
type InvalidatedNonce = ReturnType<typeof mapInvalidateNonceEvent>;
type ConflictTable = {
  id: unknown;
};

type AuthorizationDb = {
  sql: {
    insert(table: ConflictTable): {
      values(value: FillerAuthorization): {
        onConflictDoUpdate(args: { target: unknown; set: FillerAuthorization }): Promise<void>;
      };
    };
  };
};

type InvalidatedNonceDb = {
  sql: {
    insert(table: ConflictTable): {
      values(value: InvalidatedNonce): {
        onConflictDoNothing(): Promise<void>;
      };
    };
  };
};

export async function persistFillerAuthorization(
  db: AuthorizationDb,
  table: ConflictTable,
  row: FillerAuthorization,
) {
  await db.sql.insert(table).values(row).onConflictDoUpdate({
    target: table.id,
    set: row,
  });
}

export async function persistInvalidatedNonce(
  db: InvalidatedNonceDb,
  table: ConflictTable,
  row: InvalidatedNonce,
) {
  await db.sql.insert(table).values(row).onConflictDoNothing();
}
