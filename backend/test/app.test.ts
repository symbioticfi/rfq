import { describe, expect, it, vi } from "vitest";

import { createApp } from "../src/app";
import { createMetrics } from "../src/metrics";
import { RfqService } from "../src/services/rfq-service";
import {
  addresses,
  createMemoryRepositories,
  createMockPublicClient,
  createMockWalletClient,
  createSolverConfig,
  delayedJsonResponse,
  swapperAccount,
} from "./support";
import { createTestEnv } from "./support";

describe("RFQ backend app", () => {
  it("serves OpenAPI and docs routes", async () => {
    const app = createApp({
      service: {
        checkApproval: vi.fn(),
        describeLocalFaucet: vi.fn(),
        faucetLocalWallet: vi.fn(),
        fundLocalWallet: vi.fn(),
        quote: vi.fn(),
        listDiscounts: vi.fn(),
        publishDiscount: vi.fn(),
        resolveDiscount: vi.fn(),
        createOrder: vi.fn(),
        listOrders: vi.fn(),
      } as never,
      metrics: createMetrics(),
    });

    const [specResponse, docsResponse] = await Promise.all([app.request("/openapi.json"), app.request("/docs")]);
    const spec = (await specResponse.json()) as {
      readonly openapi: string;
      readonly info: { readonly title: string };
      readonly paths: Record<string, unknown>;
    };
    const docsHtml = await docsResponse.text();

    expect(specResponse.status).toBe(200);
    expect(spec.openapi).toBe("3.1.0");
    expect(spec.info.title).toBe("Symbiotic RFQ Backend API");
    expect(spec.paths).toMatchObject({
      "/health": expect.any(Object),
      "/check_approval": expect.any(Object),
      "/dev/faucet": expect.any(Object),
      "/quote": expect.any(Object),
      "/discounts": expect.any(Object),
      "/discount": expect.any(Object),
      "/order": expect.any(Object),
      "/orders": expect.any(Object),
    });

    expect(docsResponse.status).toBe(200);
    expect(docsHtml).toContain("/openapi.json");
  });

  it("validates every public route", async () => {
    const app = createApp({
      service: {
        checkApproval: vi.fn(),
        describeLocalFaucet: vi.fn(),
        faucetLocalWallet: vi.fn(),
        quote: vi.fn(),
        listDiscounts: vi.fn(),
        publishDiscount: vi.fn(),
        resolveDiscount: vi.fn(),
        createOrder: vi.fn(),
        listOrders: vi.fn(),
      } as never,
      metrics: createMetrics(),
    });

    const invalidCases = [
      app.request("/check_approval", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ walletAddress: "bad", chainId: 1, token: addresses.tokenIn, amount: "1" }),
      }),
      app.request("/dev/fund", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ walletAddress: "bad" }),
      }),
      app.request("/quote", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          tokenInChainId: 1,
          tokenOutChainId: 1,
          tokenIn: addresses.tokenIn,
          tokenOut: addresses.tokenOut,
          type: "EXACT_INPUT",
          amount: "10",
          swapper: swapperAccount.address,
          slippageTolerance: 0.5,
          outputs: [],
        }),
      }),
      app.request("/discount", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ discount: { vault: "bad" }, signature: "0x1234" }),
      }),
      app.request("/discounts", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({}),
      }),
      app.request("/order", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ quote: { quoteId: "bad" }, signature: "0x1234" }),
      }),
      app.request("/orders"),
    ];

    const responses = await Promise.all(invalidCases);
    for (const response of responses) {
      expect(response.status).toBe(400);
    }
  });

  it("funds a local wallet through the dev route", async () => {
    const fundLocalWallet = vi.fn(async () => ({
      requestId: "request-0",
      walletAddress: swapperAccount.address,
      fundedEth: "1000000000000000000",
      fundedToken: "1000000000000000000000",
      token: addresses.tokenIn,
    }));

    const app = createApp({
      service: {
        fundLocalWallet,
        describeLocalFaucet: vi.fn(),
        faucetLocalWallet: vi.fn(),
      } as never,
      metrics: createMetrics(),
    });

    const response = await app.request("/dev/fund", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ walletAddress: swapperAccount.address }),
    });

    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({
      walletAddress: swapperAccount.address,
      token: addresses.tokenIn,
    });
    expect(fundLocalWallet).toHaveBeenCalledWith({
      walletAddress: swapperAccount.address.toLowerCase(),
    });
  });

  it("describes and funds the local faucet bundle", async () => {
    const describeLocalFaucet = vi.fn(async () => ({
      requestId: "request-1",
      assets: [
        {
          token: addresses.tokenIn,
          symbol: "RWA",
          name: "RWA",
          decimals: 18,
          amount: "1000000000000000000000000",
          kind: "erc20",
        },
      ],
    }));
    const faucetLocalWallet = vi.fn(async () => ({
      requestId: "request-2",
      walletAddress: swapperAccount.address,
      fundedAssets: [
        {
          token: addresses.tokenIn,
          symbol: "RWA",
          name: "RWA",
          decimals: 18,
          amount: "1000000000000000000000000",
          kind: "erc20",
        },
      ],
    }));

    const app = createApp({
      service: {
        describeLocalFaucet,
        faucetLocalWallet,
      } as never,
      metrics: createMetrics(),
    });

    const [describeResponse, fundResponse] = await Promise.all([
      app.request("/dev/faucet"),
      app.request("/dev/faucet", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ walletAddress: swapperAccount.address }),
      }),
    ]);

    expect(describeResponse.status).toBe(200);
    expect(await describeResponse.json()).toMatchObject({
      assets: [{ token: addresses.tokenIn, symbol: "RWA" }],
    });
    expect(describeLocalFaucet).toHaveBeenCalledTimes(1);

    expect(fundResponse.status).toBe(200);
    expect(await fundResponse.json()).toMatchObject({
      walletAddress: swapperAccount.address,
      fundedAssets: [{ token: addresses.tokenIn, symbol: "RWA" }],
    });
    expect(faucetLocalWallet).toHaveBeenCalledWith({
      walletAddress: swapperAccount.address.toLowerCase(),
    });
  });

  it("serves the canonical quote, order, and orders routes", async () => {
    const service = {
      checkApproval: vi.fn(),
      quote: vi.fn(async () => ({
        requestId: "request-1",
        routing: "Priority",
        quote: {
          quoteId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
          slippageTolerance: 0.5,
          aggregatedOutputs: [{ token: addresses.tokenOut, amount: "1000" }],
          orderInfo: {
            tokenIn: addresses.tokenIn,
            amountIn: "100",
            outputs: [{ token: addresses.tokenOut, amount: "1000", recipient: swapperAccount.address }],
            deadline: 123,
            nonce: "0x01",
          },
        },
        permitData: { domain: {}, types: {}, value: {} },
      })),
      createOrder: vi.fn(async () => ({
        requestId: "request-2",
        orderId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        orderStatus: "open",
      })),
      listDiscounts: vi.fn(async () => ({
        requestId: "request-4",
        protocol: addresses.protocol,
        discounts: [
          {
            discountId: (`0x${"11".repeat(32)}`) as `0x${string}`,
            vault: addresses.vault,
            tokenToRedeem: addresses.tokenIn,
            collateral: addresses.tokenOut,
            collateralDecimals: 18,
            discount: "50000",
            signer: addresses.solverC,
            deadline: 1_800_000_000,
            maxRate: "950000000000000000",
            maxAssets: "1000000000000000000",
          },
        ],
      })),
      publishDiscount: vi.fn(async () => ({
        requestId: "request-5",
        discountId: (`0x${"11".repeat(32)}`) as `0x${string}`,
      })),
      resolveDiscount: vi.fn(async () => ({
        requestId: "request-6",
        discountId: (`0x${"11".repeat(32)}`) as `0x${string}`,
        discount: {
          vault: addresses.vault,
          tokenToRedeem: addresses.tokenIn,
          discount: "50000",
          signer: addresses.solverC,
          protocol: addresses.protocol,
          nonce: "0x01",
          deadline: 1_800_000_000,
        },
        signerSignature: (`0x${"12".repeat(65)}`) as `0x${string}`,
        protocolDeadline: 1_800_000_090,
        protocolSignature: (`0x${"34".repeat(65)}`) as `0x${string}`,
      })),
      listOrders: vi.fn(
        async (filters?: {
          orderId?: string;
          orderHash?: `0x${string}`;
          orderHashes?: readonly `0x${string}`[];
          swapper?: `0x${string}`;
        }) => ({
          requestId: "request-3",
          orders: [
            {
              type: "Priority",
              orderId: filters?.orderId ?? "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
              orderStatus: "open",
              quoteId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
              swapper: filters?.swapper ?? swapperAccount.address,
              txHash: null,
              nonce: "0x01",
              input: { token: addresses.tokenIn, amount: "100" },
              outputs: [{ token: addresses.tokenOut, amount: "1000", recipient: swapperAccount.address }],
              settledAmounts: [],
              encodedOrder: "0xdeadbeef",
              signature: "0xbeef",
              deadline: 123,
              filler: addresses.solverA,
            },
          ],
          cursor: null,
        }),
      ),
    } as never;

    const app = createApp({
      service,
      metrics: createMetrics(),
    });

    const quoteBody = {
      tokenInChainId: 1,
      tokenOutChainId: 1,
      tokenIn: addresses.tokenIn,
      tokenOut: addresses.tokenOut,
      type: "EXACT_INPUT",
      amount: "100",
      swapper: swapperAccount.address,
      slippageTolerance: 0.5,
      outputs: [{ token: addresses.tokenOut, recipient: swapperAccount.address }],
    };

    const canonicalQuote = await app.request("/quote", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(quoteBody),
    });
    expect((await canonicalQuote.json()) as { readonly requestId: string }).toMatchObject({
      requestId: "request-1",
    });

    const orderBody = {
      quote: {
        quoteId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        slippageTolerance: 0.5,
        aggregatedOutputs: [{ token: addresses.tokenOut, amount: "1000" }],
        orderInfo: {
          tokenIn: addresses.tokenIn,
          amountIn: "100",
          outputs: [{ token: addresses.tokenOut, amount: "1000", recipient: swapperAccount.address }],
          deadline: 123,
          nonce: "0x01",
        },
      },
      signature: "0x1234",
    };
    const canonicalOrder = await app.request("/order", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(orderBody),
    });
    expect((await canonicalOrder.json()) as { readonly requestId: string }).toMatchObject({
      requestId: "request-2",
    });

    const discountList = await app.request("/discounts");
    expect((await discountList.json()) as { readonly requestId: string }).toMatchObject({
      requestId: "request-4",
    });

    const discountPublish = await app.request("/discount", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        discount: {
          vault: addresses.vault,
          tokenToRedeem: addresses.tokenIn,
          discount: "50000",
          signer: addresses.solverC,
          protocol: addresses.protocol,
          nonce: "0x01",
          deadline: 1_800_000_000,
        },
        signature: `0x${"12".repeat(65)}`,
      }),
    });
    expect((await discountPublish.json()) as { readonly requestId: string }).toMatchObject({
      requestId: "request-5",
    });

    const discountResolve = await app.request("/discounts", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        discountId: `0x${"11".repeat(32)}`,
      }),
    });
    expect((await discountResolve.json()) as { readonly requestId: string }).toMatchObject({
      requestId: "request-6",
    });

    const canonicalList = await app.request(`/orders?orderId=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb`);
    const canonicalOrders = (await canonicalList.json()) as {
      readonly orders: readonly unknown[];
    };
    expect(canonicalOrders.orders[0]).toMatchObject({
      orderId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
    });

    const canonicalHashList = await app.request(
      `/orders?orderHash=0x1111111111111111111111111111111111111111111111111111111111111111`,
    );
    expect((await canonicalHashList.json()) as { readonly requestId: string }).toMatchObject({
      requestId: "request-3",
    });

    const canonicalBatchHashList = await app.request(
      `/orders?orderHashes=0x1111111111111111111111111111111111111111111111111111111111111111,0x2222222222222222222222222222222222222222222222222222222222222222`,
    );
    expect((await canonicalBatchHashList.json()) as { readonly requestId: string }).toMatchObject({
      requestId: "request-3",
    });

    const canonicalAccountOrders = await app.request(`/orders?swapper=${swapperAccount.address}`);
    expect((await canonicalAccountOrders.json()) as { readonly requestId: string }).toMatchObject({
      requestId: "request-3",
    });
  });

  it("rejects /quote requests without amount", async () => {
    const service = {
      quote: vi.fn(async () => null),
    } as unknown as RfqService;

    const app = createApp({
      service,
      metrics: createMetrics(),
    });

    const response = await app.request("/quote", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        tokenInChainId: 1,
        tokenOutChainId: 1,
        tokenIn: addresses.tokenIn,
        tokenOut: addresses.tokenOut,
        type: "EXACT_INPUT",
        swapper: swapperAccount.address,
        slippageTolerance: 0.5,
        outputs: [{ token: addresses.tokenOut, recipient: swapperAccount.address }],
      }),
    });

    expect(response.status).toBe(400);
    expect(service.quote).not.toHaveBeenCalled();
  });

  it("parses comma-separated many discount inputs", async () => {
    const discountIds = [
      (`0x${"11".repeat(32)}`) as `0x${string}`,
      (`0x${"22".repeat(32)}`) as `0x${string}`,
    ];
    const service = {
      listDiscounts: vi.fn(async () => ({
        requestId: "request-4",
        protocol: addresses.protocol,
        discounts: [],
      })),
      resolveDiscount: vi.fn(async () => ({
        requestId: "request-6",
        discounts: discountIds.map((discountId) => ({
          discountId,
          discount: {
            vault: addresses.vault,
            tokenToRedeem: addresses.tokenIn,
            discount: "50000",
            signer: addresses.solverC,
            protocol: addresses.protocol,
            nonce: "0x01",
            deadline: 1_800_000_000,
          },
          signerSignature: (`0x${"12".repeat(65)}`) as `0x${string}`,
          protocolDeadline: 1_800_000_090,
          protocolSignature: (`0x${"34".repeat(65)}`) as `0x${string}`,
        })),
      })),
    } as unknown as RfqService;

    const app = createApp({
      service,
      metrics: createMetrics(),
    });

    const [discountList, discountResolve] = await Promise.all([
      app.request(`/discounts?discountIds=${discountIds.join(",")}`),
      app.request("/discounts", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          discountIds: discountIds.join(","),
        }),
      }),
    ]);

    expect(discountList.status).toBe(200);
    expect(discountResolve.status).toBe(200);
    expect((service.listDiscounts as unknown as ReturnType<typeof vi.fn>)).toHaveBeenCalledWith({
      discountIds,
    });
    expect((service.resolveDiscount as unknown as ReturnType<typeof vi.fn>)).toHaveBeenCalledWith({
      discountIds,
    });
  });

  it("exposes Prometheus metrics after quote activity", async () => {
    const { repositories } = createMemoryRepositories({
      solvers: [
        createSolverConfig({
          id: "solver-a",
          name: "solver-a",
          endpointUrl: "https://solver-a.example",
        }),
      ],
    });
    const fetchImpl: typeof fetch = vi.fn(async (_input, init) => {
      const body = JSON.parse(String(init?.body)) as { requestId: string; quoteId: string };
      return delayedJsonResponse(
        {
          chainId: 1,
          amountIn: "100",
          amountOut: "1000",
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

    const metrics = createMetrics();
    const service = new RfqService({
      env: createTestEnv(),
      publicClient: createMockPublicClient(),
      walletClient: createMockWalletClient(),
      repositories,
      metrics,
      fetchImpl,
      now: () => new Date("2026-03-30T00:00:00.000Z"),
    });
    const app = createApp({ service, metrics });

    await app.request("/quote", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        tokenInChainId: 1,
        tokenOutChainId: 1,
        tokenIn: addresses.tokenIn,
        tokenOut: addresses.tokenOut,
        type: "EXACT_INPUT",
        amount: "100",
        swapper: swapperAccount.address,
        slippageTolerance: 0.5,
        outputs: [{ token: addresses.tokenOut, recipient: swapperAccount.address }],
      }),
    });

    const response = await app.request("/metrics");
    const body = await response.text();

    expect(response.status).toBe(200);
    expect(body).toContain("rfq_quote_requests_total");
    expect(body).toContain('route="/quote",result="quoted"');
  });
});
