import { existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { decodeAbiParameters } from "viem";

const integrationDir = resolve(dirname(fileURLToPath(import.meta.url)), "..");

function resolveRepoDir(label: string, envName: string, candidates: string[]) {
  const explicitDir = process.env[envName]?.trim();
  if (explicitDir) {
    const resolvedDir = resolve(explicitDir);
    if (!existsSync(resolvedDir)) {
      throw new Error(`${envName} points to a missing ${label} directory: ${resolvedDir}`);
    }
    return resolvedDir;
  }

  const matchedDir = candidates.find((candidate) => existsSync(candidate));
  if (!matchedDir) {
    throw new Error(`Could not locate the ${label} directory. Set ${envName} explicitly for ${integrationDir}.`);
  }

  return matchedDir;
}

const backendDir = resolveRepoDir("rfq backend", "RFQ_BACKEND_DIR", [
  resolve(integrationDir, "submodules", "rfq-backend"),
  resolve(integrationDir, "submodules", "rfq", "backend"),
  resolve(integrationDir, "..", "backend"),
]);
const fillerDir = resolveRepoDir("rfq filler", "RFQ_FILLER_DIR", [
  resolve(integrationDir, "submodules", "rfq-filler"),
  resolve(integrationDir, "submodules", "rfq", "filler"),
  resolve(integrationDir, "..", "filler"),
]);

const { createApp: createBackendApp } = await import(pathToFileURL(resolve(backendDir, "src/app.ts")).href);
const { createMetrics } = await import(pathToFileURL(resolve(backendDir, "src/metrics/index.ts")).href);
const {
  addresses: backendAddresses,
  createDiscountRecord,
  createMemoryRepositories: createBackendMemoryRepositories,
  createSolverConfig,
  createTestService: createBackendService,
  signPermitQuote,
  swapperAccount,
} = await import(pathToFileURL(resolve(backendDir, "test/support.ts")).href);
const { createApp: createFillerApp } = await import(pathToFileURL(resolve(fillerDir, "src/app.ts")).href);
const { BackendClient } = await import(pathToFileURL(resolve(fillerDir, "src/lib/backend.ts")).href);
const { executorFillMixedParameters } = await import(pathToFileURL(resolve(fillerDir, "src/lib/contracts.ts")).href);
const { ExecutionService } = await import(pathToFileURL(resolve(fillerDir, "src/services/execution-service.ts")).href);
const { QuoteService } = await import(pathToFileURL(resolve(fillerDir, "src/services/quote-service.ts")).href);
const {
  addresses: fillerAddresses,
  createMemoryRepositories: createFillerMemoryRepositories,
  createMockPublicClient: createFillerMockPublicClient,
  createTestEnv: createFillerTestEnv,
} = await import(pathToFileURL(resolve(fillerDir, "test/support.ts")).href);

function createAppFetch(input: {
  readonly backendOrigin: string;
  readonly solverOrigin: string;
  readonly getBackendApp: () => ReturnType<typeof createBackendApp>;
  readonly getSolverApp: () => ReturnType<typeof createFillerApp>;
  readonly onRequest?: (request: Request, url: URL, body: string | undefined) => void;
}) {
  return vi.fn(async (requestInfo: RequestInfo | URL, init?: RequestInit) => {
    const request =
      requestInfo instanceof Request
        ? requestInfo
        : new Request(requestInfo instanceof URL ? requestInfo : String(requestInfo), init);
    const url = new URL(request.url);
    const body =
      request.method === "GET" || request.method === "HEAD"
        ? undefined
        : ((await request.text()) || undefined);

    input.onRequest?.(request, url, body);

    const app =
      url.origin === input.backendOrigin
        ? input.getBackendApp()
        : url.origin === input.solverOrigin
          ? input.getSolverApp()
          : null;
    if (!app) {
      return new Response("Unknown test route", { status: 404 });
    }

    return app.request(`${url.pathname}${url.search}`, {
      method: request.method,
      headers: request.headers,
      body,
    });
  }) as typeof fetch;
}

describe("discount-backed flow", () => {
  it("fills through live backend discounts end to end", async () => {
    const sharedSecret = "test-backend-secret";
    const backendOrigin = "https://backend.example";
    const solverOrigin = "https://solver.example";
    const liveDiscount = createDiscountRecord({
      discountId: (`0x${"de".repeat(32)}`) as `0x${string}`,
      discountPpm: "50000",
    });
    const { state: backendState, repositories: backendRepositories } = createBackendMemoryRepositories({
      discounts: [liveDiscount],
      delegatedAuthorizedFillersByMarketMaker: new Map([[backendAddresses.referrer, []]]),
      solvers: [
        createSolverConfig({
          id: "solver-a",
          name: "solver-a",
          endpointUrl: solverOrigin,
          filler: fillerAddresses.executor,
        }),
      ],
    });
    const { state: fillerState, repositories: fillerRepositories } = createFillerMemoryRepositories();

    let backendApp!: ReturnType<typeof createBackendApp>;
    let fillerApp!: ReturnType<typeof createFillerApp>;
    const discountRequests: Array<Record<string, unknown>> = [];

    const appFetch = createAppFetch({
      backendOrigin,
      solverOrigin,
      getBackendApp: () => backendApp,
      getSolverApp: () => fillerApp,
      onRequest(request, url, body) {
        if (url.origin === backendOrigin && url.pathname === "/discounts") {
          if (request.method === "GET") {
            discountRequests.push({ method: "GET" });
          }
          if (request.method === "POST") {
            discountRequests.push({
              method: "POST",
              body: body ? (JSON.parse(body) as Record<string, unknown>) : {},
            });
          }
        }
      },
    });

    const backendService = createBackendService({
      env: {
        solverSharedSecret: sharedSecret,
        solverTimeoutMs: 200,
      },
      repositories: backendRepositories,
      fetchImpl: appFetch,
      publicClientConfig: {
        isFillerByMarketMaker: {
          [backendAddresses.referrer]: false,
        },
        maxAssetsByVault: {
          [backendAddresses.vault]: 2_000_000_000_000_000_000n,
        },
        amountOutByCollateral: {
          [backendAddresses.tokenOut]: 1_200_000_000_000_000_000n,
        },
      },
    });
    backendApp = createBackendApp({
      service: backendService,
      metrics: createMetrics(),
    });

    const fillerEnv = createFillerTestEnv({
      backendUrl: backendOrigin,
      backendSharedSecret: sharedSecret,
    });

    let createdOrderId = "";
    let submittedTxData: `0x${string}` | null = null;
    const walletClient = {
      sendTransaction: vi.fn(async ({ data }: { readonly data: `0x${string}` }) => {
        submittedTxData = data;
        return `0x${"34".repeat(32)}` as `0x${string}`;
      }),
    };
    const fillerPublicClient = {
      ...createFillerMockPublicClient({
        // This integration test intentionally mixes backend and filler fixture
        // address sets, so pin decimals explicitly instead of inheriting the
        // filler helper's fake-token defaults.
        tokenDecimals: {
          [backendAddresses.tokenIn]: 18,
          [backendAddresses.tokenOut]: 18,
        },
        collateralByVault: {
          [backendAddresses.vault]: backendAddresses.tokenOut,
        },
        marketMakerByVault: {
          [backendAddresses.vault]: backendAddresses.referrer,
        },
        curatorByVault: {
          [backendAddresses.vault]: backendAddresses.solverC,
        },
        fillerAuthorizations: {
          [`${backendAddresses.referrer}:${fillerEnv.executorAddress}`]: false,
        },
        maxAssetsByVault: {
          [backendAddresses.vault]: 2_000_000_000_000_000_000n,
        },
        maxRatesByVault: {
          [backendAddresses.vault]: 1_140_000_000_000_000_000n,
        },
        amountOutByPair: {
          [`${backendAddresses.tokenIn}:${backendAddresses.tokenOut}:1000000000000000000`]:
            1_200_000_000_000_000_000n,
        },
      }),
      async waitForTransactionReceipt({ hash }: { readonly hash: `0x${string}` }) {
        await backendRepositories.orders.updateStatus(createdOrderId, "filled", "filled", hash);
        return { status: "success" as const };
      },
    };

    const quoteService = new QuoteService({
      env: fillerEnv,
      publicClient: fillerPublicClient,
      repositories: fillerRepositories,
      now: () => new Date("2026-03-30T00:00:00.000Z"),
    });
    const executionService = new ExecutionService({
      env: fillerEnv,
      publicClient: fillerPublicClient,
      walletClient: walletClient as never,
      repositories: fillerRepositories,
      backendClient: new BackendClient({
        baseUrl: backendOrigin,
        fetchImpl: appFetch,
      }),
      now: () => new Date("2026-03-30T00:00:00.000Z"),
    });
    fillerApp = createFillerApp({
      quoteService,
      executionService,
      backendSharedSecret: sharedSecret,
    });

    const quoteResponse = await backendApp.request("/quote", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        tokenInChainId: 1,
        tokenOutChainId: 1,
        tokenIn: backendAddresses.tokenIn,
        tokenOut: backendAddresses.tokenOut,
        type: "EXACT_INPUT",
        amount: "1000000000000000000",
        swapper: swapperAccount.address,
        slippageTolerance: 0.5,
        routingPreference: "BEST_PRICE",
        outputs: [{ token: backendAddresses.tokenOut, recipient: swapperAccount.address }],
      }),
    });
    expect(quoteResponse.status).toBe(200);

    const quotePayload = (await quoteResponse.json()) as { quote: unknown } & Record<string, unknown>;
    const swapperSignature = await signPermitQuote(quotePayload);

    const orderResponse = await backendApp.request("/order", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        quote: quotePayload.quote,
        signature: swapperSignature,
      }),
    });
    expect(orderResponse.status).toBe(200);

    const orderPayload = (await orderResponse.json()) as {
      readonly orderId: string;
      readonly orderStatus: string;
    };
    createdOrderId = orderPayload.orderId;

    fillerState.strategies = [];

    await executionService.syncOnce();

    expect(walletClient.sendTransaction).toHaveBeenCalledTimes(1);
    expect(submittedTxData).not.toBeNull();
    expect(fillerState.orders[0]?.status).toBe("filled");
    expect(backendState.orders[0]?.publicStatus).toBe("filled");
    expect(discountRequests).toEqual(
      expect.arrayContaining([
        { method: "GET" },
        {
          method: "POST",
          body: {
            discountId: liveDiscount.discountId,
          },
        },
      ]),
    );

    const [, , swapInputs, discountSwapInputs] = decodeAbiParameters(
      executorFillMixedParameters,
      `0x${submittedTxData!.slice(10)}` as `0x${string}`,
    );

    expect(swapInputs).toHaveLength(0);
    expect(discountSwapInputs).toHaveLength(1);
    expect(discountSwapInputs[0]?.discountSwap.discount.vault.toLowerCase()).toBe(backendAddresses.vault);
    expect(discountSwapInputs[0]?.discountSwap.discount.tokenToRedeem.toLowerCase()).toBe(backendAddresses.tokenIn);
    expect(discountSwapInputs[0]?.discountSwap.discount.signer.toLowerCase()).toBe(backendAddresses.solverC);
    expect(discountSwapInputs[0]?.amountIn).toBe(1_000_000_000_000_000_000n);
    expect(discountSwapInputs[0]?.amountOut).toBe(1_140_000_000_000_000_000n);
  });
});
