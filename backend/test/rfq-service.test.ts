import { describe, expect, it, vi } from "vitest";

import { createMetrics } from "../src/metrics";
import { RfqService } from "../src/services/rfq-service";
import type { OrderRecord, SolverQuoteResponse } from "../src/types/domain";
import {
  addresses,
  createDiscountRecord,
  createMemoryRepositories,
  createMockPublicClient,
  createMockWalletClient,
  createSolverConfig,
  createTestEnv,
  createTestService,
  delayedJsonResponse,
  signPermitQuote,
  swapperAccount,
} from "./support";

describe("RfqService", () => {
  it("returns Permit2 approval payload only when allowance is insufficient", async () => {
    const approvedService = createTestService({
      publicClientConfig: {
        allowance: 1_000n,
      },
    });

    await expect(
      approvedService.checkApproval({
        walletAddress: swapperAccount.address,
        chainId: 1,
        token: addresses.tokenIn,
        amount: "500",
      }),
    ).resolves.toEqual({
      requestId: expect.any(String),
      approval: null,
      cancel: null,
    });

    const service = createTestService({
      publicClientConfig: {
        allowance: 100n,
      },
    });

    const response = await service.checkApproval({
      walletAddress: swapperAccount.address,
      chainId: 1,
      token: addresses.tokenIn,
      amount: "500",
    });

    expect(response.approval).toMatchObject({
      to: addresses.tokenIn,
      value: "0",
    });
    expect(response.approval?.data.startsWith("0x")).toBe(true);
  });

  it("funds faucet assets in parallel with reserved nonces", async () => {
    const getTransactionCount = vi.fn(async () => 12);
    const waitForTransactionReceipt = vi.fn(async () => ({ status: "success" } as const));
    const sendTransaction = vi
      .fn()
      .mockResolvedValueOnce(`0x${"11".repeat(32)}` as `0x${string}`)
      .mockResolvedValueOnce(`0x${"22".repeat(32)}` as `0x${string}`)
      .mockResolvedValueOnce(`0x${"33".repeat(32)}` as `0x${string}`)
      .mockResolvedValueOnce(`0x${"44".repeat(32)}` as `0x${string}`)
      .mockResolvedValueOnce(`0x${"55".repeat(32)}` as `0x${string}`);

    const service = new RfqService({
      env: createTestEnv({
        deploymentEnv: "hoodi",
        deployment: {
          ...createTestEnv().deployment,
          chain: {
            ...createTestEnv().deployment.chain,
            id: 560048,
            name: "Hoodi",
            testnet: true,
          },
          tokens: {
            input: [
              { address: addresses.tokenIn, symbol: "ACRED", name: "Apollo Diversified Credit", decimals: 18 },
              { address: addresses.secondaryTokenOut, symbol: "mF-ONE", name: "Midas Fasanara ONE", decimals: 18 },
            ],
            output: [
              { address: addresses.tokenOut, symbol: "USDC", name: "USD Coin", decimals: 18 },
              { address: addresses.secondaryTokenOut, symbol: "aUSD", name: "Anchored USD", decimals: 18 },
              { address: "0x0000000000000000000000000000000000000000", symbol: "ETH", name: "Ether", decimals: 18 },
            ],
            defaultInput: addresses.tokenIn,
            defaultOutput: addresses.tokenOut,
          },
        },
      }),
      publicClient: {
        ...createMockPublicClient(),
        getTransactionCount,
        waitForTransactionReceipt,
      } as never,
      walletClient: {
        ...createMockWalletClient(),
        sendTransaction,
      } as never,
      repositories: createMemoryRepositories().repositories,
      metrics: createMetrics(),
      fetchImpl: fetch,
      now: () => new Date("2026-03-31T00:00:00.000Z"),
    });

    const response = await service.faucetLocalWallet({
      walletAddress: swapperAccount.address,
    });

    expect(response.fundedAssets).toHaveLength(4);
    expect(getTransactionCount).toHaveBeenCalledWith({
      address: expect.any(String),
      blockTag: "pending",
    });
    expect(sendTransaction).toHaveBeenCalledTimes(4);
    expect(sendTransaction.mock.calls.map(([input]) => input.nonce)).toEqual([12, 13, 14, 15]);
    expect(waitForTransactionReceipt).toHaveBeenCalledTimes(4);
  });

  it("selects the best soft quote within timeout and records solver quotes on the persisted quote request", async () => {
    const { repositories, state } = createMemoryRepositories({
      solvers: [
        createSolverConfig({
          id: "solver-a",
          name: "solver-a",
          endpointUrl: "https://solver-a.example",
        }),
        createSolverConfig({
          id: "solver-b",
          name: "solver-b",
          endpointUrl: "https://solver-b.example",
        }),
        createSolverConfig({
          id: "solver-c",
          name: "solver-c",
          endpointUrl: "https://solver-c.example",
          enabled: false,
        }),
      ],
    });

    const fetchImpl: typeof fetch = vi.fn(async (input, init) => {
      const url = String(input);
      const body = JSON.parse(String(init?.body)) as { requestId: string; quoteId: string };

      if (url.includes("solver-a")) {
        const payload: SolverQuoteResponse = {
          chainId: 1,
          amountIn: "100000000",
          amountOut: "1000",
          filler: addresses.solverA,
          requestId: body.requestId,
          swapper: "0x0000000000000000000000000000000000000000",
          tokenIn: addresses.tokenIn,
          tokenOut: addresses.tokenOut,
          quoteId: body.quoteId,
        };
        return delayedJsonResponse(payload as unknown as Record<string, unknown>, 20, init);
      }

      if (url.includes("solver-b")) {
        return new Promise<Response>((_, reject) => {
          const abort = () => {
            const error = new Error("Aborted");
            error.name = "AbortError";
            reject(error);
          };

          if (init?.signal?.aborted) {
            abort();
            return;
          }

          init?.signal?.addEventListener("abort", abort, { once: true });
        });
      }

      throw new Error(`Unexpected solver url ${url}`);
    }) as typeof fetch;

    const service = createTestService({
      env: {
        solverTimeoutMs: 30,
      },
      repositories,
      fetchImpl,
    });

    const response = await service.quote({
      tokenInChainId: 1,
      tokenOutChainId: 1,
      tokenIn: addresses.tokenIn,
      tokenOut: addresses.tokenOut,
      type: "EXACT_INPUT",
      amount: "100000000",
      swapper: swapperAccount.address,
      slippageTolerance: 0.5,
      routingPreference: "BEST_PRICE",
      outputs: [
        { token: addresses.tokenOut, recipient: swapperAccount.address },
        { token: addresses.tokenOut, recipient: addresses.referrer, portionBps: 100 },
      ],
    });

    expect(response).not.toBeNull();
    expect(response?.quote.aggregatedOutputs).toEqual([{ token: addresses.tokenOut, amount: "1000" }]);
    expect(response?.quote.orderInfo.outputs).toEqual([
      { token: addresses.tokenOut, recipient: swapperAccount.address, amount: "990" },
      { token: addresses.tokenOut, recipient: addresses.referrer, amount: "10", portionBps: 100 },
    ]);

    expect(fetchImpl).toHaveBeenCalledTimes(2);
    expect(state.quotes).toHaveLength(1);
    expect(state.solverQuotes).toHaveLength(2);
    expect(new Set(state.solverQuotes.map((quote) => quote.quoteRequestId))).toEqual(new Set([state.quotes[0]!.id]));
    expect(state.solverQuotes.map((quote) => quote.status).sort()).toEqual(["quoted", "timeout"]);
  });

  it("falls back to sequential reads when multicall is unavailable during inventory discovery", async () => {
    const { repositories, state } = createMemoryRepositories({
      solvers: [
        createSolverConfig({
          id: "solver-a",
          name: "solver-a",
          endpointUrl: "https://solver-a.example",
        }),
      ],
    });

    const fetchImpl: typeof fetch = vi.fn(async (input, init) => {
      const url = String(input);
      const body = JSON.parse(String(init?.body)) as { requestId: string; quoteId: string };
      expect(url).toContain("solver-a");

      const payload: SolverQuoteResponse = {
        chainId: 1,
        amountIn: "100000000",
        amountOut: "1000",
        filler: addresses.solverA,
        requestId: body.requestId,
        swapper: "0x0000000000000000000000000000000000000000",
        tokenIn: addresses.tokenIn,
        tokenOut: addresses.tokenOut,
        quoteId: body.quoteId,
      };
      return delayedJsonResponse(payload as unknown as Record<string, unknown>, 0, init);
    }) as typeof fetch;

    const service = createTestService({
      repositories,
      fetchImpl,
      publicClientConfig: {
        multicallFailureMode: "all-fail",
      },
    });

    const response = await service.quote({
      tokenInChainId: 1,
      tokenOutChainId: 1,
      tokenIn: addresses.tokenIn,
      tokenOut: addresses.tokenOut,
      type: "EXACT_INPUT",
      amount: "100000000",
      swapper: swapperAccount.address,
      slippageTolerance: 0.5,
      routingPreference: "BEST_PRICE",
      outputs: [{ token: addresses.tokenOut, recipient: swapperAccount.address }],
    });

    expect(response).not.toBeNull();
    expect(fetchImpl).toHaveBeenCalledTimes(1);
    expect(state.solverQuotes).toHaveLength(1);
    expect(state.solverQuotes[0]?.status).toBe("quoted");
  });

  it("lists live discounts and returns fresh protocol signatures", async () => {
    const { repositories, state } = createMemoryRepositories({
      discounts: [createDiscountRecord()],
    });
    const service = createTestService({
      repositories,
      publicClientConfig: {
        amountOutByCollateral: {
          [addresses.tokenOut]: 950000000000000000n,
        },
      },
    });

    const list = await service.listDiscounts();
    const resolved = await service.resolveDiscount({
      discountId: state.discounts[0]!.discountId,
    });

    expect(list.protocol).toBe(addresses.protocol);
    expect(list.discounts[0]).toMatchObject({
      discountId: state.discounts[0]!.discountId,
      vault: addresses.vault,
      tokenToRedeem: addresses.tokenIn,
    });
    expect(resolved.discountId).toBe(state.discounts[0]!.discountId);
    expect(resolved.protocolDeadline).toBeGreaterThan(Math.floor(new Date("2026-03-30T00:00:00.000Z").getTime() / 1000));
    expect(resolved.protocolSignature.startsWith("0x")).toBe(true);
  });

  it("replaces the live discount for a vault pair and uses it in quote inventory when direct permission is missing", async () => {
    const { repositories, state } = createMemoryRepositories({
      discounts: [
        createDiscountRecord({
          discountId: (`0x${"01".repeat(32)}`) as `0x${string}`,
          discountPpm: "30000",
        }),
      ],
      delegatedAuthorizedFillersByMarketMaker: new Map([[addresses.referrer, []]]),
      solvers: [
        createSolverConfig({
          id: "solver-a",
          name: "solver-a",
          endpointUrl: "https://solver-a.example",
          filler: addresses.solverA,
        }),
      ],
    });

    await repositories.discounts.upsertLive(
      createDiscountRecord({
        discountId: (`0x${"02".repeat(32)}`) as `0x${string}`,
        discountPpm: "40000",
      }),
    );

    let solverVaults: Array<Record<string, unknown>> = [];
    const fetchImpl: typeof fetch = vi.fn(async (_input, init) => {
      const body = JSON.parse(String(init?.body)) as { requestId: string; quoteId: string; vaults: Array<Record<string, unknown>> };
      solverVaults = body.vaults;

      return delayedJsonResponse(
        {
          chainId: 1,
          amountIn: "1000000000000000000",
          amountOut: "950000000000000000",
          filler: addresses.solverA,
          requestId: body.requestId,
          swapper: "0x0000000000000000000000000000000000000000",
          tokenIn: addresses.tokenIn,
          tokenOut: addresses.tokenOut,
          quoteId: body.quoteId,
        },
        1,
        init,
      );
    }) as typeof fetch;

    const service = createTestService({
      repositories,
      fetchImpl,
      publicClientConfig: {
        isFillerByMarketMaker: {
          [addresses.referrer]: false,
        },
        amountOutByCollateral: {
          [addresses.tokenOut]: 1_000_000_000_000_000_000n,
        },
      },
    });

    await service.quote({
      tokenInChainId: 1,
      tokenOutChainId: 1,
      tokenIn: addresses.tokenIn,
      tokenOut: addresses.tokenOut,
      type: "EXACT_INPUT",
      amount: "1000000000000000000",
      swapper: swapperAccount.address,
      slippageTolerance: 0.5,
      routingPreference: "BEST_PRICE",
      outputs: [{ token: addresses.tokenOut, recipient: swapperAccount.address }],
    });

    expect(state.discounts).toHaveLength(1);
    expect(state.discounts[0]?.discountId).toBe((`0x${"02".repeat(32)}`) as `0x${string}`);
    expect(solverVaults[0]).toMatchObject({
      discountId: (`0x${"02".repeat(32)}`) as `0x${string}`,
    });
  });

  it("filters live discounts and resolves many discounts at once", async () => {
    const firstDiscountId = (`0x${"01".repeat(32)}`) as `0x${string}`;
    const secondDiscountId = (`0x${"02".repeat(32)}`) as `0x${string}`;
    const { repositories } = createMemoryRepositories({
      discounts: [
        createDiscountRecord({
          discountId: firstDiscountId,
          vault: addresses.vault,
          tokenToRedeem: addresses.tokenIn,
        }),
        createDiscountRecord({
          discountId: secondDiscountId,
          vault: addresses.referrer,
          tokenToRedeem: addresses.tokenIn,
        }),
      ],
    });
    const service = createTestService({
      repositories,
      publicClientConfig: {
        amountOutByCollateral: {
          [addresses.tokenOut]: 950000000000000000n,
        },
        collateralByVault: {
          [addresses.referrer]: addresses.tokenOut,
        },
        maxAssetsByVault: {
          [addresses.vault]: 1_000_000_000_000_000_000n,
          [addresses.referrer]: 2_000_000_000_000_000_000n,
        },
      },
    });

    const filtered = await service.listDiscounts({ discountIds: [secondDiscountId] });
    const resolved = await service.resolveDiscount({ discountIds: [firstDiscountId, secondDiscountId] });

    expect(filtered.discounts).toHaveLength(1);
    expect(filtered.discounts[0]?.discountId).toBe(secondDiscountId);
    expect("discounts" in resolved && resolved.discounts).toHaveLength(2);
    if ("discounts" in resolved) {
      expect(resolved.discounts.map((discount) => discount.discountId)).toEqual([firstDiscountId, secondDiscountId]);
    }
  });

  it("reruns hard RFQ, creates an order, and dedupes repeated submissions", async () => {
    const { repositories, state } = createMemoryRepositories({
      solvers: [
        createSolverConfig({
          id: "solver-a",
          name: "solver-a",
          endpointUrl: "https://solver-a.example",
        }),
        createSolverConfig({
          id: "solver-b",
          name: "solver-b",
          endpointUrl: "https://solver-b.example",
        }),
      ],
    });

    let quoteRound = 0;
    const fetchImpl: typeof fetch = vi.fn(async (input, init) => {
      const url = String(input);
      const body = JSON.parse(String(init?.body)) as { requestId: string; quoteId: string };
      if (url.endsWith("/notify")) {
        return new Response(null, { status: 200 });
      }

      const rounds = quoteRound < 2 ? (["1000", "950"] as const) : (["1010", "1100"] as const);
      const amountOut = url.includes("solver-a") ? rounds[0] : rounds[1];
      quoteRound += 1;
      const filler = url.includes("solver-a") ? addresses.solverA : addresses.solverB;

      const payload: SolverQuoteResponse = {
        chainId: 1,
        amountIn: "100000000",
        amountOut,
        filler,
        requestId: body.requestId,
        swapper: "0x0000000000000000000000000000000000000000",
        tokenIn: addresses.tokenIn,
        tokenOut: addresses.tokenOut,
        quoteId: body.quoteId,
      };
      return delayedJsonResponse(payload as unknown as Record<string, unknown>, 5, init);
    }) as typeof fetch;

    const service = createTestService({
      repositories,
      fetchImpl,
    });

    const quote = await service.quote({
      tokenInChainId: 1,
      tokenOutChainId: 1,
      tokenIn: addresses.tokenIn,
      tokenOut: addresses.tokenOut,
      type: "EXACT_INPUT",
      amount: "100000000",
      swapper: swapperAccount.address,
      slippageTolerance: 0.5,
      routingPreference: "BEST_PRICE",
      outputs: [{ token: addresses.tokenOut, recipient: swapperAccount.address }],
    });

    expect(quote).not.toBeNull();
    const signature = await signPermitQuote(quote!);

    const first = await service.createOrder({
      quote: quote!.quote,
      signature,
    });
    const second = await service.createOrder({
      quote: quote!.quote,
      signature,
    });

    expect(first.orderId).toBe(second.orderId);
    expect(first.orderStatus).toBe("open");
    expect(state.orders).toHaveLength(1);
    expect(state.orders[0]?.filler).toBe(addresses.solverB);
    expect(state.orderStatusHistory).toHaveLength(1);
  });

  it("notifies the winning solver with a self-contained executable payload", async () => {
    const { repositories } = createMemoryRepositories({
      solvers: [
        createSolverConfig({
          id: "solver-a",
          name: "solver-a",
          endpointUrl: "https://solver-a.example",
          notifyUrl: "https://solver-a.example/notify",
        }),
      ],
    });

    const notifyBodies: Array<Record<string, unknown>> = [];
    const fetchImpl: typeof fetch = vi.fn(async (input, init) => {
      const url = String(input);
      const body = JSON.parse(String(init?.body)) as { requestId: string; quoteId: string };

      if (url.endsWith("/notify")) {
        notifyBodies.push(JSON.parse(String(init?.body)) as Record<string, unknown>);
        return new Response(null, { status: 200 });
      }

      const payload: SolverQuoteResponse = {
        chainId: 1,
        amountIn: "100000000",
        amountOut: "1000",
        filler: addresses.solverA,
        requestId: body.requestId,
        swapper: "0x0000000000000000000000000000000000000000",
        tokenIn: addresses.tokenIn,
        tokenOut: addresses.tokenOut,
        quoteId: body.quoteId,
      };

      return delayedJsonResponse(payload as unknown as Record<string, unknown>, 5, init);
    }) as typeof fetch;

    const now = new Date("2026-03-31T00:00:00.000Z");
    const service = createTestService({
      repositories,
      fetchImpl,
      now: () => now,
    });

    const quote = await service.quote({
      tokenInChainId: 1,
      tokenOutChainId: 1,
      tokenIn: addresses.tokenIn,
      tokenOut: addresses.tokenOut,
      type: "EXACT_INPUT",
      amount: "100000000",
      swapper: swapperAccount.address,
      slippageTolerance: 0.5,
      routingPreference: "BEST_PRICE",
      outputs: [{ token: addresses.tokenOut, recipient: swapperAccount.address }],
    });

    expect(quote).not.toBeNull();
    const signature = await signPermitQuote(quote!);

    await service.createOrder({
      quote: quote!.quote,
      signature,
    });

    expect(notifyBodies).toHaveLength(1);
    expect(notifyBodies[0]).toMatchObject({
      orderHash: expect.stringMatching(/^0x[a-f0-9]{64}$/),
      createdAt: Math.floor(now.getTime() / 1000),
      notifiedAt: expect.any(Number),
      signature: expect.stringMatching(/^0x[a-f0-9]+$/),
      orderStatus: "open",
      encodedOrder: expect.stringMatching(/^0x[a-f0-9]+$/),
      chainId: 1,
      filler: addresses.solverA,
      quoteId: quote!.quote.quoteId,
      offerer: swapperAccount.address,
      type: "Priority",
    });
  });

  it("returns null when every solver is disabled or cooling down", async () => {
    const { repositories } = createMemoryRepositories({
      solvers: [
        createSolverConfig({
          id: "solver-a",
          name: "solver-a",
          endpointUrl: "https://solver-a.example",
          enabled: false,
        }),
        createSolverConfig({
          id: "solver-b",
          name: "solver-b",
          endpointUrl: "https://solver-b.example",
          cooldownUntil: new Date("2026-03-31T00:00:00.000Z"),
        }),
      ],
    });
    const fetchImpl = vi.fn(fetch) as typeof fetch;
    const service = createTestService({
      repositories,
      fetchImpl,
    });

    await expect(
      service.quote({
        tokenInChainId: 1,
        tokenOutChainId: 1,
        tokenIn: addresses.tokenIn,
        tokenOut: addresses.tokenOut,
        type: "EXACT_INPUT",
        amount: "100000000",
        swapper: swapperAccount.address,
        slippageTolerance: 0.5,
        routingPreference: "BEST_PRICE",
        outputs: [{ token: addresses.tokenOut, recipient: swapperAccount.address }],
      }),
    ).resolves.toBeNull();

    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it("reconciles indexed fills before expiry and merges settled amounts", async () => {
    const now = new Date("2026-03-30T00:00:00.000Z");
    const order: OrderRecord = {
      orderId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      quoteId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      requestId: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
      swapper: swapperAccount.address,
      filler: addresses.solverA,
      tokenIn: addresses.tokenIn,
      amountIn: "100000000",
      outputs: [{ token: addresses.tokenOut, recipient: swapperAccount.address, amount: "1000" }],
      deadline: Math.floor(now.getTime() / 1000) - 5,
      nonce: "0x01",
      orderHash: "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
      encodedOrder: "0xdeadbeef",
      protocolSignature: "0xbeef",
      swapperSignature: "0xcafe",
      publicStatus: "open",
      internalStatus: "winner_selected",
      txHash: null,
      createdAt: now,
      updatedAt: now,
    };
    const { repositories, state } = createMemoryRepositories({
      orders: [order],
      settledAmountsByOrderHash: new Map([
        [
          order.orderHash,
          [
            {
              token: addresses.tokenOut,
              amount: "1000",
              recipient: swapperAccount.address,
              txHash: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            },
          ],
        ],
      ]),
    });
    const service = createTestService({
      repositories,
      now: () => now,
    });

    const response = await service.listOrders({ orderId: order.orderId });

    expect(response.orders).toHaveLength(1);
    expect(response.orders[0]).toMatchObject({
      orderId: order.orderId,
      orderStatus: "filled",
      txHash: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      settledAmounts: [
        {
          token: addresses.tokenOut,
          amount: "1000",
          recipient: swapperAccount.address,
        },
      ],
    });
    expect(state.orderStatusHistory).toHaveLength(1);
    expect(state.orderStatusHistory[0]).toMatchObject({
      publicStatus: "filled",
      internalStatus: "filled",
      reason: "indexed_fill",
    });
    expect(state.orders[0]?.publicStatus).toBe("filled");
  });
});
