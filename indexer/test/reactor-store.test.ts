import { describe, expect, it, vi } from "vitest";

import type { mapReactorFillEvent } from "../src/indexer/contracts/reactor-event";
import { persistReactorFill } from "../src/indexer/contracts/reactor-store";

type ReactorFill = ReturnType<typeof mapReactorFillEvent>["fill"];
type ReactorFillOutput = ReturnType<typeof mapReactorFillEvent>["outputs"][number];

describe("persistReactorFill", () => {
  it("stores output rows individually instead of as a bulk insert", async () => {
    const insertedFillRows: ReactorFill[] = [];
    const insertedOutputRows: ReactorFillOutput[] = [];

    const db = {
      sql: {
        insert(table: string) {
          return {
            values(value: ReactorFill | ReactorFillOutput[]) {
              return {
                async onConflictDoNothing() {
                  if (table === "reactorFill") {
                    insertedFillRows.push(value as ReactorFill);
                    return;
                  }

                  if (Array.isArray(value)) {
                    throw new Error("bulk output insert is not supported");
                  }

                  insertedOutputRows.push(value as ReactorFillOutput);
                },
              };
            },
          };
        },
      },
    };

    const fill: ReactorFill = {
      id: "1:0xtx:7",
      chainId: 1,
      blockNumber: 123n,
      blockTimestamp: 456n,
      txHash: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      logIndex: 7,
      orderHash: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      swapper: "0x1111111111111111111111111111111111111111",
      filler: "0x2222222222222222222222222222222222222222",
      tokenIn: "0x3333333333333333333333333333333333333333",
      amountIn: 100n,
      deadline: 789n,
      nonce: 1n,
      protocol: "0x4444444444444444444444444444444444444444",
      swapperSignature: "0x1234",
    };

    const outputs: ReactorFillOutput[] = [
      {
        fillId: fill.id,
        outputIndex: 0,
        token: "0x5555555555555555555555555555555555555555",
        recipient: "0x6666666666666666666666666666666666666666",
        amount: 90n,
      },
      {
        fillId: fill.id,
        outputIndex: 1,
        token: "0x7777777777777777777777777777777777777777",
        recipient: "0x8888888888888888888888888888888888888888",
        amount: 10n,
      },
    ];

    await expect(
      persistReactorFill(db as never, "reactorFill" as never, "reactorFillOutput" as never, fill, outputs),
    ).resolves.toBeUndefined();

    expect(insertedFillRows).toEqual([fill]);
    expect(insertedOutputRows).toEqual(outputs);
  });
});
