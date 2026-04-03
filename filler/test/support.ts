import type { Abi } from "viem";
import { privateKeyToAccount } from "viem/accounts";

import type { FillerEnv } from "../src/config/env";
import { createApp } from "../src/app";
import { BackendClient } from "../src/lib/backend";
import { encodeOrder } from "../src/lib/reactor";
import type {
  BackendOrderItem,
  DiscountsResponse,
  ExecutionAttemptRecord,
  LocalOrderRecord,
  NotifyRequest,
  ResolveDiscountResponse,
  ReactorOrder,
  StrategyRecord,
  SolverQuoteRequest,
} from "../src/types/domain";
import type { FillerRepositories } from "../src/types/repositories";
import { ExecutionService } from "../src/services/execution-service";
import { QuoteService } from "../src/services/quote-service";

export const callerAccount = privateKeyToAccount(`0x${"11".repeat(32)}` as `0x${string}`);

export const addresses = {
  executor: "0x1111111111111111111111111111111111111111",
  adapter: "0x2222222222222222222222222222222222222222",
  tokenIn: "0x3333333333333333333333333333333333333333",
  usdc: "0x4444444444444444444444444444444444444444",
  weth: "0x5555555555555555555555555555555555555555",
  vaultA: "0x6666666666666666666666666666666666666666",
  vaultB: "0x7777777777777777777777777777777777777777",
  router: "0x8888888888888888888888888888888888888888",
  swapper: "0x9999999999999999999999999999999999999999",
} as const satisfies Record<string, `0x${string}`>;

export function createTestEnv(overrides: Partial<FillerEnv> = {}): FillerEnv {
  return {
    deploymentEnv: "local",
    deployment: {
      version: 1,
      environment: "local",
      deployed: true,
      chain: {
        id: 1,
        name: "Ethereum",
        rpcUrl: "https://rpc.example",
        testnet: false,
        startBlock: 0,
        explorerUrl: "",
      },
      contracts: {
        permit2: addresses.executor,
        curatorRegistry: addresses.router,
        instantRedemptionAdapter: addresses.adapter,
        reactor: addresses.executor,
        executor: addresses.executor,
        mockSwapRouter: addresses.router,
      },
      participants: {
        protocolSigner: addresses.executor,
        executorCaller: callerAccount.address,
        marketMaker: addresses.executor,
      },
      tokens: {
        input: [],
        output: [],
        defaultInput: null,
        defaultOutput: null,
      },
      vaults: [
        {
          address: addresses.vaultA,
          collateral: addresses.usdc,
          name: "Vault A",
        },
      ],
    },
    chainId: 1,
    backendUrl: "https://backend.example",
    backendSharedSecret: "test-backend-secret",
    executorAddress: addresses.executor,
    callerAccount,
    curatorRegistryAddress: addresses.router,
    instantRedemptionAdapterAddress: addresses.adapter,
    quoteDiscountPercent: 10,
    quoteDiscountBps: 1_000,
    rpcUrl: undefined,
    host: "127.0.0.1",
    port: 42073,
    logLevel: "silent",
    pollIntervalMs: 1_000,
    orderLimit: 20,
    ...overrides,
  };
}

export function createSolverQuoteRequest(overrides: Partial<SolverQuoteRequest> = {}): SolverQuoteRequest {
  return {
    requestId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    tokenInChainId: 1,
    tokenOutChainId: 1,
    swapper: "0x0000000000000000000000000000000000000000",
    tokenIn: addresses.tokenIn,
    tokenOut: addresses.usdc,
    amount: "100000000000000000000",
    type: "EXACT_INPUT",
    protocol: "v1",
    numOutputs: 1,
    quoteId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
    vaults: [
      {
        vault: addresses.vaultA,
        collateral: addresses.usdc,
        collateralDecimals: 6,
        maxCollateralOut: "150000000",
        maxRate: "1200000000000000000",
        discountId: null,
      },
    ],
    ...overrides,
  };
}

export function createStrategyRecord(overrides: Partial<StrategyRecord> = {}): StrategyRecord {
  return {
    quoteId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
    requestId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    tokenIn: addresses.tokenIn,
    tokenOut: addresses.usdc,
    amountIn: "100000000000000000000",
    collateral: addresses.usdc,
    collateralDecimals: 6,
    collateralAmountOut: "120000000",
    quotedAmountOut: "108000000",
    legs: [
      {
        vault: addresses.vaultA,
        amountIn: "100000000000000000000",
        amountOut: "120000000",
        maxRate: "1200000000000000000",
        discountId: null,
      },
    ],
    createdAt: new Date("2026-03-30T00:00:00.000Z"),
    updatedAt: new Date("2026-03-30T00:00:00.000Z"),
    ...overrides,
  };
}

export function createBackendOrder(overrides: Partial<BackendOrderItem> = {}): BackendOrderItem {
  const order = createReactorOrder();

  return {
    type: "Priority",
    orderId: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
    orderStatus: "open",
    quoteId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
    swapper: addresses.swapper,
    txHash: null,
    nonce: `0x${"01".padStart(64, "0")}`,
    input: {
      token: addresses.tokenIn,
      amount: "100000000000000000000",
    },
    outputs: [{ token: addresses.usdc, amount: "108000000", recipient: addresses.swapper }],
    settledAmounts: [],
    encodedOrder: encodeOrder(order),
    signature: `0x${"12".repeat(65)}`,
    deadline: Number(order.request.deadline),
    filler: addresses.executor,
    ...overrides,
  };
}

export function createNotifyRequest(overrides: Partial<NotifyRequest> = {}): NotifyRequest {
  const order = createReactorOrder();
  return {
    orderHash: `0x${"cd".repeat(32)}`,
    createdAt: 1_775_190_400,
    notifiedAt: 1_775_190_400_123,
    signature: `0x${"12".repeat(65)}`,
    orderStatus: "open",
    encodedOrder: encodeOrder(order),
    chainId: 1,
    filler: addresses.executor,
    quoteId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
    offerer: order.swapper,
    type: "Priority",
    ...overrides,
  };
}

export function createReactorOrder(overrides: Partial<ReactorOrder> = {}): ReactorOrder {
  return {
    request: {
      tokenIn: addresses.tokenIn,
      amountIn: 100000000000000000000n,
      outputs: [{ token: addresses.usdc, amount: 108000000n, recipient: addresses.swapper }],
      deadline: 1_775_191_000n,
      nonce: 1n,
      protocol: addresses.executor,
    },
    swapperSignature: `0x${"ab".repeat(65)}`,
    swapper: addresses.swapper,
    filler: addresses.executor,
    ...overrides,
  };
}

type MemoryState = {
  strategies: StrategyRecord[];
  orders: LocalOrderRecord[];
  attempts: ExecutionAttemptRecord[];
};

export function createMemoryRepositories(initial?: Partial<MemoryState>) {
  const state: MemoryState = {
    strategies: [...(initial?.strategies ?? [])],
    orders: [...(initial?.orders ?? [])],
    attempts: [...(initial?.attempts ?? [])],
  };

  const repositories: FillerRepositories = {
    strategies: {
      async upsert(strategy) {
        const existing = state.strategies.find((candidate) => candidate.quoteId === strategy.quoteId);
        if (!existing) {
          state.strategies.push(strategy);
          return;
        }

        const index = state.strategies.indexOf(existing);
        state.strategies[index] = strategy;
      },
      async findByQuoteId(quoteId) {
        return state.strategies.find((candidate) => candidate.quoteId === quoteId) ?? null;
      },
    },
    orders: {
      async upsertQueued(input) {
        const existing = state.orders.find((candidate) => candidate.orderId === input.orderId);
        if (!existing) {
          state.orders.push({
            orderId: input.orderId,
            orderHash: input.orderHash ?? null,
            quoteId: input.quoteId,
            source: input.source,
            status: "queued",
            filler: input.filler,
            encodedOrder: input.encodedOrder ?? null,
            protocolSignature: input.protocolSignature ?? null,
            deadline: input.deadline ?? null,
            txHash: null,
            lastError: null,
            createdAt: new Date("2026-03-30T00:00:00.000Z"),
            updatedAt: new Date("2026-03-30T00:00:00.000Z"),
          });
          return;
        }
        const index = state.orders.indexOf(existing);
        state.orders[index] = {
          ...existing,
          orderHash: input.orderHash ?? existing.orderHash ?? null,
          quoteId: input.quoteId ?? existing.quoteId,
          source: input.source,
          status: existing.status === "failed" ? "queued" : existing.status,
          filler: input.filler ?? existing.filler,
          encodedOrder: input.encodedOrder ?? existing.encodedOrder,
          protocolSignature: input.protocolSignature ?? existing.protocolSignature,
          deadline: input.deadline ?? existing.deadline,
          lastError: existing.status === "failed" ? null : existing.lastError,
        };
      },
      async hydrateExecutable(input) {
        const order = state.orders.find((candidate) => candidate.orderId === input.orderId);
        if (!order) {
          throw new Error(`Unknown order ${input.orderId}`);
        }
        const index = state.orders.indexOf(order);
        const next = {
          ...order,
          quoteId: input.quoteId,
          filler: input.filler,
          encodedOrder: input.encodedOrder,
          protocolSignature: input.protocolSignature,
          deadline: input.deadline,
        };
        state.orders[index] = next;
        return next;
      },
      async findByOrderId(orderId) {
        return state.orders.find((candidate) => candidate.orderId === orderId) ?? null;
      },
      async findByOrderHash(orderHash) {
        return state.orders.find((candidate) => candidate.orderHash === orderHash) ?? null;
      },
      async listActive() {
        return state.orders.filter((order) => ["queued", "submitting", "submitted"].includes(order.status));
      },
      async markStatus(orderId, status, input) {
        const order = state.orders.find((candidate) => candidate.orderId === orderId);
        if (!order) {
          throw new Error(`Unknown order ${orderId}`);
        }
        const index = state.orders.indexOf(order);
        state.orders[index] = {
          ...order,
          status,
          txHash: input?.txHash !== undefined ? input.txHash : order.txHash,
          lastError: input?.lastError !== undefined ? input.lastError : order.lastError,
          updatedAt: new Date("2026-03-30T00:00:00.000Z"),
        };
      },
    },
    attempts: {
      async append(record) {
        state.attempts.push(record);
      },
      async countByOrderId(orderId) {
        return state.attempts.filter((attempt) => attempt.orderId === orderId).length;
      },
    },
  };

  return { state, repositories };
}

type PublicClientConfig = {
  readonly tokenDecimals?: Record<`0x${string}`, number>;
  readonly pausedVaults?: readonly `0x${string}`[];
  readonly maxAssetsByVault?: Record<`0x${string}`, bigint>;
  readonly maxRatesByVault?: Record<`0x${string}`, bigint>;
  readonly collateralByVault?: Record<`0x${string}`, `0x${string}`>;
  readonly marketMakerByVault?: Record<`0x${string}`, `0x${string}`>;
  readonly curatorByVault?: Record<`0x${string}`, `0x${string}`>;
  readonly fillerAuthorizations?: Record<string, boolean>;
  readonly amountOutByPair?: Record<string, bigint>;
  readonly allowances?: Record<string, bigint>;
  readonly receiptsByHash?: Record<`0x${string}`, { readonly status: "success" | "reverted" }>;
  readonly multicallFailureMode?: "all-fail";
};

export function createMockPublicClient(config: PublicClientConfig = {}) {
  const pausedVaults = new Set(config.pausedVaults ?? []);
  const readContract = async ({
    address,
    abi: _abi,
    functionName,
    args,
  }: {
    readonly address: `0x${string}`;
    readonly abi?: Abi;
    readonly functionName: string;
    readonly args?: readonly unknown[];
  }) => {
    switch (functionName) {
      case "decimals":
        return config.tokenDecimals?.[address] ?? (address === addresses.usdc ? 6 : 18);
      case "collateral":
        return config.collateralByVault?.[address] ?? addresses.usdc;
      case "isPaused":
        return pausedVaults.has(args?.[0] as `0x${string}`);
      case "getMaxAssets":
        return config.maxAssetsByVault?.[args?.[0] as `0x${string}`] ?? 1_000_000_000n;
      case "getMaxRate":
        return config.maxRatesByVault?.[args?.[0] as `0x${string}`] ?? 1_200_000_000_000_000_000n;
      case "marketMaker":
        return config.marketMakerByVault?.[args?.[0] as `0x${string}`] ?? addresses.executor;
      case "getCurator":
        return config.curatorByVault?.[args?.[0] as `0x${string}`] ?? addresses.executor;
      case "isFiller":
        return config.fillerAuthorizations?.[`${String(args?.[0])}:${String(args?.[1])}`] ?? false;
      case "getAmountOut":
        return (
          config.amountOutByPair?.[`${String(args?.[0])}:${String(args?.[1])}:${String(args?.[2])}`] ?? 120_000_000n
        );
      case "allowance":
        return config.allowances?.[`${address}:${String(args?.[0])}:${String(args?.[1])}`] ?? 0n;
      default:
        throw new Error(`Unsupported readContract: ${functionName}`);
    }
  };

  return {
    readContract,
    async multicall({
      allowFailure: _allowFailure,
      contracts,
    }: {
      readonly allowFailure?: boolean;
      readonly contracts: readonly {
        readonly address: `0x${string}`;
        readonly abi?: Abi;
        readonly functionName: string;
        readonly args?: readonly unknown[];
      }[];
    }) {
      if (config.multicallFailureMode === "all-fail") {
        return contracts.map(() => ({
          status: "failure" as const,
        }));
      }

      return Promise.all(
        contracts.map(async (contract) => {
          try {
            return {
              status: "success" as const,
              result: await readContract(contract),
            };
          } catch {
            return {
              status: "failure" as const,
            };
          }
        }),
      );
    },
    async waitForTransactionReceipt({ hash }: { readonly hash: `0x${string}` }) {
      return config.receiptsByHash?.[hash] ?? { status: "success" as const };
    },
  };
}

export function createMockWalletClient(txHash: `0x${string}` = `0x${"34".repeat(32)}`) {
  return {
    sendTransaction: async (_input: {
      readonly account: `0x${string}`;
      readonly to: `0x${string}`;
      readonly data: `0x${string}`;
    }) => txHash,
  };
}

export function createMockBackendClient(input?: {
  readonly openOrders?: readonly BackendOrderItem[];
  readonly executableOrder?: BackendOrderItem | null;
  readonly order?: BackendOrderItem | null;
  readonly discounts?: DiscountsResponse;
  readonly resolvedDiscountsById?: Record<`0x${string}`, ResolveDiscountResponse>;
  readonly resolvedDiscountsByPair?: Record<string, ResolveDiscountResponse>;
}) {
  return {
    listOpenOrders: async () => input?.openOrders ?? [],
    getExecutableOrder: async () => input?.executableOrder ?? null,
    getOrder: async () => input?.order ?? input?.executableOrder ?? null,
    listDiscounts: async () =>
      input?.discounts ?? {
        requestId: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
        protocol: addresses.executor,
        discounts: [],
      },
    resolveDiscount: async (
      request:
        | {
            readonly discountId: `0x${string}`;
            readonly vault?: undefined;
            readonly tokenToRedeem?: undefined;
          }
        | {
            readonly discountId?: undefined;
            readonly vault: `0x${string}`;
            readonly tokenToRedeem: `0x${string}`;
          },
    ) => {
      const resolved = request.discountId
        ? input?.resolvedDiscountsById?.[request.discountId]
        : input?.resolvedDiscountsByPair?.[`${request.vault}:${request.tokenToRedeem}`];
      if (!resolved) {
        throw new Error("Unknown discount");
      }
      return resolved;
    },
  } as unknown as BackendClient;
}

export function createDiscountListItem(
  overrides: Partial<DiscountsResponse["discounts"][number]> = {},
): DiscountsResponse["discounts"][number] {
  return {
    discountId: `0x${"de".repeat(32)}`,
    vault: addresses.vaultA,
    tokenToRedeem: addresses.tokenIn,
    collateral: addresses.usdc,
    collateralDecimals: 6,
    discount: "50000",
    signer: addresses.executor,
    deadline: 1_775_191_000,
    maxRate: "1200000000000000000",
    maxAssets: "150000000",
    ...overrides,
  };
}

export function createResolvedDiscount(
  overrides: Partial<ResolveDiscountResponse> = {},
): ResolveDiscountResponse {
  return {
    requestId: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
    discountId: `0x${"de".repeat(32)}`,
    discount: {
      vault: addresses.vaultA,
      tokenToRedeem: addresses.tokenIn,
      discount: "50000",
      signer: addresses.executor,
      protocol: addresses.executor,
      nonce: `0x${"01".padStart(64, "0")}`,
      deadline: 1_775_191_000,
    },
    signerSignature: `0x${"23".repeat(65)}`,
    protocolDeadline: 1_775_190_490,
    protocolSignature: `0x${"45".repeat(65)}`,
    ...overrides,
  };
}

export function createQuoteService(input?: {
  readonly env?: Partial<FillerEnv>;
  readonly publicClientConfig?: PublicClientConfig;
  readonly repositories?: FillerRepositories;
}) {
  return new QuoteService({
    env: createTestEnv(input?.env),
    publicClient: createMockPublicClient(input?.publicClientConfig),
    repositories: input?.repositories ?? createMemoryRepositories().repositories,
    now: () => new Date("2026-03-30T00:00:00.000Z"),
  });
}

export function createExecutionService(input?: {
  readonly env?: Partial<FillerEnv>;
  readonly publicClientConfig?: PublicClientConfig;
  readonly repositories?: FillerRepositories;
  readonly backendClient?: BackendClient;
  readonly walletClient?: ReturnType<typeof createMockWalletClient>;
}) {
  return new ExecutionService({
    env: createTestEnv(input?.env),
    publicClient: createMockPublicClient(input?.publicClientConfig),
    walletClient: input?.walletClient ?? createMockWalletClient(),
    repositories: input?.repositories ?? createMemoryRepositories().repositories,
    backendClient: input?.backendClient ?? createMockBackendClient(),
    now: () => new Date("2026-03-30T00:00:00.000Z"),
  });
}

export function createTestApp(input?: {
  readonly quoteService?: QuoteService;
  readonly executionService?: ExecutionService;
}) {
  return createApp({
    quoteService: input?.quoteService ?? createQuoteService(),
    executionService: input?.executionService ?? createExecutionService(),
    backendSharedSecret: "test-backend-secret",
  });
}
