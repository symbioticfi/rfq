import { describe, expect, it } from "vitest";

import type { mapInvalidateNonceEvent } from "../src/indexer/contracts/invalidated-nonce-event";
import type { mapSetFillerEvent } from "../src/indexer/contracts/filler-authorization-event";
import { persistFillerAuthorization, persistInvalidatedNonce } from "../src/indexer/contracts/instant-redemption-adapter-store";

type FillerAuthorization = ReturnType<typeof mapSetFillerEvent>;
type InvalidatedNonce = ReturnType<typeof mapInvalidateNonceEvent>;

describe("persistFillerAuthorization", () => {
  it("updates an existing authorization row instead of using conflict-upsert helpers", async () => {
    const upsertedRows: Array<{ target: string; set: FillerAuthorization; row: FillerAuthorization }> = [];

    const row: FillerAuthorization = {
      id: "1:0x1111111111111111111111111111111111111111:0x2222222222222222222222222222222222222222",
      chainId: 1,
      marketMaker: "0x1111111111111111111111111111111111111111",
      filler: "0x2222222222222222222222222222222222222222",
      status: false,
      txHash: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      blockNumber: 123,
      logIndex: 4,
    };

    const db = {
      sql: {
        insert(_table: unknown) {
          return {
            values(value: FillerAuthorization) {
              return {
                async onConflictDoUpdate({ target, set }: { target: string; set: FillerAuthorization }) {
                  upsertedRows.push({ target, set, row: value });
                },
              };
            },
          };
        },
      },
    };

    await persistFillerAuthorization(db as never, { id: "id" } as never, row);

    expect(upsertedRows).toEqual([{ target: "id", set: row, row }]);
  });

  it("inserts a new authorization row when none exists yet", async () => {
    const upsertedRows: Array<{ target: string; set: FillerAuthorization; row: FillerAuthorization }> = [];

    const row: FillerAuthorization = {
      id: "1:0x3333333333333333333333333333333333333333:0x4444444444444444444444444444444444444444",
      chainId: 1,
      marketMaker: "0x3333333333333333333333333333333333333333",
      filler: "0x4444444444444444444444444444444444444444",
      status: true,
      txHash: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      blockNumber: 456,
      logIndex: 7,
    };

    const db = {
      sql: {
        insert(_table: unknown) {
          return {
            values(value: FillerAuthorization) {
              return {
                async onConflictDoUpdate({ target, set }: { target: string; set: FillerAuthorization }) {
                  upsertedRows.push({ target, set, row: value });
                },
              };
            },
          };
        },
      },
    };

    await persistFillerAuthorization(db as never, { id: "id" } as never, row);

    expect(upsertedRows).toEqual([{ target: "id", set: row, row }]);
  });
});

describe("persistInvalidatedNonce", () => {
  it("inserts invalidated nonce rows with conflict-ignore semantics", async () => {
    const insertedRows: InvalidatedNonce[] = [];

    const row: InvalidatedNonce = {
      id: "1:0x1111111111111111111111111111111111111111:0x2222222222222222222222222222222222222222:9",
      chainId: 1,
      vault: "0x1111111111111111111111111111111111111111",
      tokenToRedeem: "0x2222222222222222222222222222222222222222",
      nonce: 9n,
      txHash: "0xcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
      blockNumber: 789,
      logIndex: 3,
    };

    const db = {
      sql: {
        insert(_table: unknown) {
          return {
            values(value: InvalidatedNonce) {
              return {
                async onConflictDoNothing() {
                  insertedRows.push(value);
                },
              };
            },
          };
        },
      },
    };

    await persistInvalidatedNonce(db as never, { id: "id" } as never, row);

    expect(insertedRows).toEqual([row]);
  });
});
