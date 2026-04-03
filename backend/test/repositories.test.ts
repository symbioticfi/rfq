import { describe, expect, it } from "vitest";
import { getAddress } from "viem";

import { createBackendRepositories } from "../src/db/repositories";

function lowerAddress(value: `0x${string}`): `0x${string}` {
  return getAddress(value).toLowerCase() as `0x${string}`;
}

function createDbWithRows(rows: Array<Record<string, unknown>>) {
  const query = {
    from() {
      return query;
    },
    innerJoin() {
      return query;
    },
    where() {
      return Promise.resolve(rows);
    },
  };

  return {
    select: () => query,
    insert: () => {
      throw new Error("not used");
    },
    update: () => {
      throw new Error("not used");
    },
    execute: async () => ({ rows }),
  };
}

function createDbWithError(error: Error & { code?: string }) {
  const query = {
    from() {
      return query;
    },
    innerJoin() {
      return query;
    },
    where() {
      throw error;
    },
  };

  return {
    select: () => query,
    insert: () => {
      throw new Error("not used");
    },
    update: () => {
      throw new Error("not used");
    },
    execute: async () => {
      throw error;
    },
  };
}

function createDbCapture() {
  const inserts: unknown[] = [];
  const updates: unknown[] = [];

  return {
    db: {
      select: () => ({
        from() {
          return this;
        },
        where() {
          return Promise.resolve([]);
        },
        limit() {
          return Promise.resolve([]);
        },
      }),
      insert: () => ({
        values(value: unknown) {
          inserts.push(value);
          return Promise.resolve();
        },
      }),
      update: () => ({
        set(value: unknown) {
          updates.push(value);
          return {
            where() {
              return Promise.resolve();
            },
          };
        },
      }),
      execute: async () => ({ rows: [] }),
    },
    inserts,
    updates,
  };
}

describe("backend fill read repository", () => {
  it("lowercases addresses before persisting solver, quote, and order records", async () => {
    const capture = createDbCapture();
    const repositories = createBackendRepositories(capture.db as never);

    await repositories.solvers.create({
      id: "solver-1",
      chainId: 1,
      name: "Solver",
      endpointUrl: "https://solver.test/quote",
      notifyUrl: "https://solver.test/notify",
      filler: "0xAbCdEf0000000000000000000000000000000001",
      enabled: true,
      cooldownUntil: null,
      metadata: {},
      createdAt: new Date("2026-01-01T00:00:00.000Z"),
      updatedAt: new Date("2026-01-01T00:00:00.000Z"),
    });

    await repositories.quotes.create({
      id: "quote-row-1",
      requestId: "request-1",
      quoteId: "quote-1",
      phase: "executable",
      request: {
        tokenInChainId: 1,
        tokenOutChainId: 1,
        tokenIn: "0xAbCdEf0000000000000000000000000000000002",
        tokenOut: "0xAbCdEf0000000000000000000000000000000003",
        type: "EXACT_INPUT",
        amount: "100",
        swapper: "0xAbCdEf0000000000000000000000000000000004",
        slippageTolerance: 0.5,
        routingPreference: "BEST_PRICE",
        outputs: [
          {
            token: "0xAbCdEf0000000000000000000000000000000005",
            recipient: "0xAbCdEf0000000000000000000000000000000006",
          },
        ],
      },
      permitData: { domain: {}, types: {}, value: {} },
      outputs: [
        {
          token: "0xAbCdEf0000000000000000000000000000000005",
          recipient: "0xAbCdEf0000000000000000000000000000000006",
          amount: "100",
        },
      ],
      bestAmountOut: "100",
      bestFiller: "0xAbCdEf0000000000000000000000000000000001",
      selectedSolverId: "solver-1",
      expiresAt: new Date("2026-01-01T00:05:00.000Z"),
      createdAt: new Date("2026-01-01T00:00:00.000Z"),
    });

    await repositories.orders.create({
      orderId: "order-1",
      quoteId: "quote-1",
      requestId: "request-1",
      swapper: "0xAbCdEf0000000000000000000000000000000004",
      filler: "0xAbCdEf0000000000000000000000000000000001",
      tokenIn: "0xAbCdEf0000000000000000000000000000000002",
      amountIn: "100",
      outputs: [
        {
          token: "0xAbCdEf0000000000000000000000000000000005",
          recipient: "0xAbCdEf0000000000000000000000000000000006",
          amount: "100",
        },
      ],
      deadline: 1_800_000_000,
      nonce: "0x01",
      orderHash: "0x1111111111111111111111111111111111111111111111111111111111111111",
      encodedOrder: "0x1234",
      protocolSignature: "0x5678",
      swapperSignature: "0x9abc",
      publicStatus: "open",
      internalStatus: "hard_auction",
      txHash: null,
      createdAt: new Date("2026-01-01T00:00:00.000Z"),
      updatedAt: new Date("2026-01-01T00:00:00.000Z"),
    });

    expect(capture.inserts).toContainEqual(
      expect.objectContaining({
        filler: lowerAddress("0xAbCdEf0000000000000000000000000000000001"),
        endpointUrl: "https://solver.test/quote",
      }),
    );
    expect(capture.inserts).toContainEqual(
      expect.objectContaining({
        requestPayload: expect.objectContaining({
          tokenIn: lowerAddress("0xAbCdEf0000000000000000000000000000000002"),
          tokenOut: lowerAddress("0xAbCdEf0000000000000000000000000000000003"),
          swapper: lowerAddress("0xAbCdEf0000000000000000000000000000000004"),
          outputs: [
            expect.objectContaining({
              token: lowerAddress("0xAbCdEf0000000000000000000000000000000005"),
              recipient: lowerAddress("0xAbCdEf0000000000000000000000000000000006"),
            }),
          ],
        }),
        bestFiller: lowerAddress("0xAbCdEf0000000000000000000000000000000001"),
      }),
    );
    expect(capture.inserts).toContainEqual(
      expect.objectContaining({
        swapper: lowerAddress("0xAbCdEf0000000000000000000000000000000004"),
        filler: lowerAddress("0xAbCdEf0000000000000000000000000000000001"),
        tokenIn: lowerAddress("0xAbCdEf0000000000000000000000000000000002"),
      }),
    );
    expect(capture.inserts).toContainEqual([
      expect.objectContaining({
        token: lowerAddress("0xAbCdEf0000000000000000000000000000000005"),
        recipient: lowerAddress("0xAbCdEf0000000000000000000000000000000006"),
      }),
    ]);
  });

  it("lowercases addresses before persisting a live discount row", async () => {
    const capture = createDbCapture();
    const repositories = createBackendRepositories(capture.db as never);

    await repositories.discounts.upsertLive({
      discountId: "0x1111111111111111111111111111111111111111111111111111111111111111",
      chainId: 1,
      vault: "0xAbCdEf0000000000000000000000000000000001",
      tokenToRedeem: "0xAbCdEf0000000000000000000000000000000002",
      discountPpm: "50000",
      signer: "0xAbCdEf0000000000000000000000000000000003",
      protocol: "0xAbCdEf0000000000000000000000000000000004",
      nonce: "0x01",
      deadline: 1_800_000_000,
      signerSignature: "0x1234",
      createdAt: new Date("2026-01-01T00:00:00.000Z"),
      updatedAt: new Date("2026-01-01T00:00:00.000Z"),
    });

    expect(capture.inserts).toContainEqual(
      expect.objectContaining({
        discountId: "0x1111111111111111111111111111111111111111111111111111111111111111",
        vault: lowerAddress("0xAbCdEf0000000000000000000000000000000001"),
        tokenToRedeem: lowerAddress("0xAbCdEf0000000000000000000000000000000002"),
        signer: lowerAddress("0xAbCdEf0000000000000000000000000000000003"),
        protocol: lowerAddress("0xAbCdEf0000000000000000000000000000000004"),
      }),
    );
  });

  it("maps settled amounts by order hash", async () => {
    const rows = [
      {
        orderHash: "0x1111111111111111111111111111111111111111111111111111111111111111",
        token: "0x5555555555555555555555555555555555555555",
        amount: "1000",
        recipient: "0x2222222222222222222222222222222222222222",
        txHash: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      },
    ];

    const repositories = createBackendRepositories(createDbWithRows(rows) as never);
    const settled = await repositories.fills.listSettledAmounts([
      "0x1111111111111111111111111111111111111111111111111111111111111111",
    ]);

    expect(settled.get("0x1111111111111111111111111111111111111111111111111111111111111111")).toEqual([
      {
        token: "0x5555555555555555555555555555555555555555",
        amount: "1000",
        recipient: "0x2222222222222222222222222222222222222222",
        txHash: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      },
    ]);
  });

  it("treats a missing indexer schema as empty settled amounts", async () => {
    const error = Object.assign(new Error('relation "rfq_indexer.reactor_fill" does not exist'), {
      code: "42P01",
    });
    const repositories = createBackendRepositories(createDbWithError(error) as never);

    await expect(
      repositories.fills.listSettledAmounts(["0x1111111111111111111111111111111111111111111111111111111111111111"]),
    ).resolves.toEqual(new Map());
  });

  it("treats a wrapped drizzle indexer query failure as empty settled amounts", async () => {
    const error = new Error(
      'Failed query: select "rfq_indexer"."reactor_fill"."order_hash" from "rfq_indexer"."reactor_fill" inner join "rfq_indexer"."reactor_fill_output" on "rfq_indexer"."reactor_fill_output"."fill_id" = "rfq_indexer"."reactor_fill"."id" where "rfq_indexer"."reactor_fill"."order_hash" in ($1)',
    );
    const repositories = createBackendRepositories(createDbWithError(error) as never);

    await expect(
      repositories.fills.listSettledAmounts(["0x1111111111111111111111111111111111111111111111111111111111111111"]),
    ).resolves.toEqual(new Map());
  });
});
