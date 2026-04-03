import { describe, expect, it, vi } from "vitest";

import {
  addresses,
  createBackendOrder,
  createDiscountListItem,
  createExecutionService,
  createMemoryRepositories,
  createMockBackendClient,
  createNotifyRequest,
  createMockWalletClient,
  createResolvedDiscount,
  createStrategyRecord,
} from "./support";

const mixedCaseExecutor = "0x4aB1f495aE7649903Ef1C6C1C4AE1308d1A315cF" as const;
const lowercasedExecutor = mixedCaseExecutor.toLowerCase() as `0x${string}`;

async function waitFor(predicate: () => boolean, attempts = 20) {
  for (let index = 0; index < attempts; index += 1) {
    if (predicate()) {
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
}

describe("ExecutionService", () => {
  it("queues notify payloads and submits direct collateral fills", async () => {
    const { state, repositories } = createMemoryRepositories({
      strategies: [createStrategyRecord()],
    });
    const service = createExecutionService({
      repositories,
      backendClient: createMockBackendClient({
        openOrders: [],
        executableOrder: null,
        order: null,
      }),
    });

    await service.enqueueFromNotify(createNotifyRequest());
    await waitFor(() => state.orders[0]?.status === "filled");

    expect(state.orders[0]?.status).toBe("filled");
    expect(state.attempts).toHaveLength(1);
    expect(state.orders[0]?.orderId).not.toBe(`0x${"cd".repeat(32)}`);
    expect(state.orders[0]?.orderHash).toBe(`0x${"cd".repeat(32)}`);
    expect(state.orders[0]?.txHash).toBe(`0x${"34".repeat(32)}`);
    expect(state.orders[0]?.encodedOrder).not.toBeNull();
    expect(state.orders[0]?.protocolSignature).toBe(`0x${"12".repeat(65)}`);
  });

  it("accepts notify payloads when filler address casing differs", async () => {
    const { state, repositories } = createMemoryRepositories({
      strategies: [createStrategyRecord()],
    });
    const service = createExecutionService({
      env: {
        executorAddress: mixedCaseExecutor,
      },
      repositories,
      backendClient: createMockBackendClient({
        openOrders: [],
        executableOrder: null,
        order: null,
      }),
    });

    await service.enqueueFromNotify(createNotifyRequest({ filler: lowercasedExecutor }));
    await waitFor(() => state.orders[0]?.status === "filled");

    expect(state.orders[0]?.status).toBe("filled");
    expect(state.attempts).toHaveLength(1);
  });

  it("accepts polled orders when backend filler casing differs", async () => {
    const { state, repositories } = createMemoryRepositories({
      strategies: [createStrategyRecord()],
    });
    const service = createExecutionService({
      env: {
        executorAddress: mixedCaseExecutor,
      },
      repositories,
      backendClient: createMockBackendClient({
        openOrders: [createBackendOrder({ filler: lowercasedExecutor })],
        executableOrder: createBackendOrder({ filler: lowercasedExecutor }),
        order: createBackendOrder({
          filler: lowercasedExecutor,
          orderStatus: "filled",
          txHash: `0x${"56".repeat(32)}`,
        }),
      }),
    });

    await service.syncOnce();

    expect(state.orders[0]?.status).toBe("filled");
    expect(state.orders[0]?.lastError).toBeNull();
    expect(state.attempts).toHaveLength(1);
  });

  it("marks orders failed when strategy collateral differs from output token", async () => {
    const { state, repositories } = createMemoryRepositories({
      strategies: [
        createStrategyRecord({
          collateral: addresses.weth,
          collateralDecimals: 18,
          collateralAmountOut: "1000000000000000000",
          quotedAmountOut: "108000000",
          legs: [
            {
              vault: addresses.vaultA,
              amountIn: "100000000000000000000",
              amountOut: "1000000000000000000",
              maxRate: "10000000000000000",
              discountId: null,
            },
          ],
        }),
      ],
    });
    const service = createExecutionService({
      repositories,
      backendClient: createMockBackendClient({
        openOrders: [createBackendOrder({ quoteId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb" })],
        executableOrder: createBackendOrder({
          quoteId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
          outputs: [{ token: addresses.usdc, amount: "108000000", recipient: addresses.swapper }],
        }),
        order: createBackendOrder({
          quoteId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
          orderStatus: "filled",
          txHash: `0x${"78".repeat(32)}`,
        }),
      }),
      publicClientConfig: {
        maxAssetsByVault: {
          [addresses.vaultA]: 1000000000000000000n,
        },
      },
    });

    await service.syncOnce();

    expect(state.orders[0]?.status).toBe("failed");
    expect(state.orders[0]?.lastError).toContain("Strategy collateral must match order output token");
  });

  it("marks orders failed when strategy is missing or stale", async () => {
    const { state, repositories } = createMemoryRepositories();
    const service = createExecutionService({
      repositories,
      backendClient: createMockBackendClient({
        openOrders: [createBackendOrder()],
        executableOrder: createBackendOrder(),
      }),
      publicClientConfig: {
        pausedVaults: [addresses.vaultA],
      },
      walletClient: createMockWalletClient(),
    });

    await service.syncOnce();

    expect(state.orders[0]?.status).toBe("failed");
    expect(state.orders[0]?.lastError).toContain("Missing strategy");
  });

  it("surfaces wallet submission failures even when adapter state changed after quoting", async () => {
    const walletClient = {
      sendTransaction: vi.fn(async () => {
        throw new Error("simulation failed");
      }),
    };
    const { state, repositories } = createMemoryRepositories({
      strategies: [createStrategyRecord()],
    });
    const service = createExecutionService({
      repositories,
      backendClient: createMockBackendClient({
        openOrders: [createBackendOrder()],
        executableOrder: createBackendOrder(),
      }),
      publicClientConfig: {
        pausedVaults: [addresses.vaultA],
      },
      walletClient: walletClient as never,
    });

    await service.syncOnce();

    expect(walletClient.sendTransaction).toHaveBeenCalledTimes(1);
    expect(state.orders[0]?.status).toBe("failed");
    expect(state.orders[0]?.lastError).toContain("simulation failed");
  });

  it("resolves discount-backed legs before submission", async () => {
    const walletClient = {
      sendTransaction: vi.fn(async () => `0x${"34".repeat(32)}` as `0x${string}`),
    };
    const resolveDiscount = vi.fn(async () => createResolvedDiscount());
    const { state, repositories } = createMemoryRepositories({
      strategies: [
        createStrategyRecord({
          legs: [
            {
              vault: addresses.vaultA,
              amountIn: "100000000000000000000",
              amountOut: "120000000",
              maxRate: "1200000000000000000",
              discountId: `0x${"de".repeat(32)}`,
            },
          ],
        }),
      ],
    });
    const service = createExecutionService({
      repositories,
      backendClient: {
        ...createMockBackendClient({
          openOrders: [createBackendOrder()],
          executableOrder: createBackendOrder(),
          order: createBackendOrder({ orderStatus: "filled", txHash: `0x${"56".repeat(32)}` }),
        }),
        resolveDiscount,
      } as never,
      walletClient: walletClient as never,
    });

    await service.syncOnce();

    expect(resolveDiscount).toHaveBeenCalledWith({ discountId: `0x${"de".repeat(32)}` });
    expect(walletClient.sendTransaction).toHaveBeenCalledTimes(1);
    expect(state.orders[0]?.status).toBe("filled");
  });

  it("requeues a failed local order when backend polling still reports it open", async () => {
    const failedOrder = {
      orderId: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
      quoteId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      source: "poll" as const,
      status: "failed" as const,
      filler: addresses.executor,
      encodedOrder: null,
      protocolSignature: null,
      deadline: null,
      txHash: null,
      lastError: "temporary rpc error",
      createdAt: new Date("2026-03-30T00:00:00.000Z"),
      updatedAt: new Date("2026-03-30T00:00:00.000Z"),
    };
    const { state, repositories } = createMemoryRepositories({
      orders: [failedOrder],
      strategies: [createStrategyRecord()],
    });
    const service = createExecutionService({
      repositories,
      backendClient: createMockBackendClient({
        openOrders: [createBackendOrder()],
        executableOrder: createBackendOrder(),
        order: createBackendOrder({ orderStatus: "filled", txHash: `0x${"ab".repeat(32)}` }),
      }),
    });

    await service.syncOnce();

    expect(state.orders[0]?.status).toBe("filled");
    expect(state.orders[0]?.lastError).toBeNull();
    expect(state.attempts).toHaveLength(1);
  });

  it("rebuilds a strategy from deployed vaults after a restart", async () => {
    const { state, repositories } = createMemoryRepositories();
    const service = createExecutionService({
      repositories,
      backendClient: createMockBackendClient({
        openOrders: [createBackendOrder()],
        executableOrder: createBackendOrder(),
        order: createBackendOrder({ orderStatus: "filled", txHash: `0x${"90".repeat(32)}` }),
      }),
      publicClientConfig: {
        tokenDecimals: {
          [addresses.tokenIn]: 18,
          [addresses.usdc]: 6,
        },
        maxAssetsByVault: {
          [addresses.vaultA]: 120000000n,
        },
        maxRatesByVault: {
          [addresses.vaultA]: 1200000000000000000n,
        },
      },
    });

    await service.syncOnce();

    expect(state.strategies).toHaveLength(1);
    expect(state.strategies[0]?.quoteId).toBe("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb");
    expect(state.orders[0]?.status).toBe("filled");
  });

  it("rebuilds a discount-backed strategy from live backend discounts after a restart", async () => {
    const resolveDiscount = vi.fn(async () => createResolvedDiscount());
    const { state, repositories } = createMemoryRepositories();
    const service = createExecutionService({
      env: {
        executorAddress: lowercasedExecutor,
      },
      repositories,
      backendClient: {
        ...createMockBackendClient({
          openOrders: [createBackendOrder({ filler: lowercasedExecutor })],
          executableOrder: createBackendOrder({ filler: lowercasedExecutor }),
          order: createBackendOrder({ filler: lowercasedExecutor, orderStatus: "filled", txHash: `0x${"90".repeat(32)}` }),
          discounts: {
            requestId: "ffffffff-ffff-4fff-8fff-ffffffffffff",
            protocol: addresses.executor,
            discounts: [createDiscountListItem()],
          },
        }),
        resolveDiscount,
      } as never,
      publicClientConfig: {
        tokenDecimals: {
          [addresses.tokenIn]: 18,
          [addresses.usdc]: 6,
        },
        marketMakerByVault: {
          [addresses.vaultA]: addresses.router,
        },
        curatorByVault: {
          [addresses.vaultA]: addresses.swapper,
        },
      },
    });

    await service.syncOnce();

    expect(resolveDiscount).toHaveBeenCalledWith({ discountId: `0x${"de".repeat(32)}` });
    expect(state.strategies).toHaveLength(1);
    expect(state.strategies[0]?.legs[0]).toMatchObject({
      discountId: `0x${"de".repeat(32)}`,
    });
    expect(state.orders[0]?.status).toBe("filled");
  });

  it("rebuilds the best mixed strategy from private and public inventory after a restart", async () => {
    const discountId = `0x${"ef".repeat(32)}` as const;
    const resolveDiscount = vi.fn(async () =>
      createResolvedDiscount({
        discountId,
        discount: {
          vault: addresses.vaultB,
          tokenToRedeem: addresses.tokenIn,
          discount: "50000",
          signer: addresses.executor,
          protocol: addresses.executor,
          nonce: `0x${"01".padStart(64, "0")}`,
          deadline: 1_775_191_000,
        },
      }),
    );
    const { state, repositories } = createMemoryRepositories();
    const service = createExecutionService({
      repositories,
      backendClient: {
        ...createMockBackendClient({
          openOrders: [createBackendOrder()],
          executableOrder: createBackendOrder(),
          order: createBackendOrder({ orderStatus: "filled", txHash: `0x${"91".repeat(32)}` }),
          discounts: {
            requestId: "ffffffff-ffff-4fff-8fff-ffffffffffff",
            protocol: addresses.executor,
            discounts: [
              createDiscountListItem({
                discountId,
                vault: addresses.vaultB,
                maxRate: "1140000000000000000",
                maxAssets: "57000000",
              }),
            ],
          },
        }),
        resolveDiscount,
      } as never,
      publicClientConfig: {
        tokenDecimals: {
          [addresses.tokenIn]: 18,
          [addresses.usdc]: 6,
        },
        maxAssetsByVault: {
          [addresses.vaultA]: 150000000n,
        },
        maxRatesByVault: {
          [addresses.vaultA]: 1200000000000000000n,
        },
      },
    });

    await service.syncOnce();

    expect(resolveDiscount).toHaveBeenCalledWith({ discountId });
    expect(state.strategies).toHaveLength(1);
    expect(state.strategies[0]?.quotedAmountOut).toBe("111000000");
    expect(state.strategies[0]?.legs).toEqual([
      expect.objectContaining({
        vault: addresses.vaultB,
        amountIn: "50000000000000000000",
        amountOut: "57000000",
        discountId,
      }),
      expect.objectContaining({
        vault: addresses.vaultA,
        amountIn: "50000000000000000000",
        amountOut: "54000000",
        discountId: null,
      }),
    ]);
    expect(state.orders[0]?.status).toBe("filled");
  });

  it("keeps running when backend polling fails transiently", async () => {
    const backendClient = {
      listOpenOrders: vi.fn(async () => {
        throw new Error("connect ECONNREFUSED 127.0.0.1:42072");
      }),
      getExecutableOrder: vi.fn(async () => null),
      getOrder: vi.fn(async () => null),
    };
    const service = createExecutionService({
      repositories: createMemoryRepositories().repositories,
      backendClient: backendClient as never,
    });

    await expect(service.syncOnce()).resolves.toBeUndefined();
    expect(backendClient.listOpenOrders).toHaveBeenCalledTimes(1);
  });
});
