import { privateKeyToAccount } from "viem/accounts";

import type { BackendEnv } from "../src/config/env";
import { createMetrics } from "../src/metrics";
import { RfqService, type RfqServiceDependencies } from "../src/services/rfq-service";
import type {
  DiscountRecord,
  OrderInternalStatus,
  OrderPublicStatus,
  OrderRecord,
  QuoteRequestRecord,
  SettledAmount,
  SolverConfig,
  SolverQuoteRecord,
} from "../src/types/domain";
import type { BackendRepositories, FillReadRepository, OrderListFilters } from "../src/types/repositories";

const protocolSigner = privateKeyToAccount(`0x${"11".repeat(32)}` as `0x${string}`);
const localFunder = privateKeyToAccount(`0x${"33".repeat(32)}` as `0x${string}`);
export const swapperAccount = privateKeyToAccount(`0x${"22".repeat(32)}` as `0x${string}`);

export const addresses = {
  reactor: "0x1111111111111111111111111111111111111111",
  adapter: "0x2222222222222222222222222222222222222222",
  curatorRegistry: "0x2121212121212121212121212121212121212121",
  vaultFactory: "0x2323232323232323232323232323232323232323",
  permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
  vault: "0x3333333333333333333333333333333333333333",
  secondVault: "0x3434343434343434343434343434343434343434",
  tokenIn: "0x4444444444444444444444444444444444444444",
  tokenOut: "0x5555555555555555555555555555555555555555",
  secondaryTokenOut: "0x6666666666666666666666666666666666666666",
  referrer: "0x7777777777777777777777777777777777777777",
  solverA: "0x8888888888888888888888888888888888888888",
  solverB: "0x9999999999999999999999999999999999999999",
  solverC: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  protocol: protocolSigner.address.toLowerCase() as `0x${string}`,
} as const satisfies Record<string, `0x${string}`>;

export function createTestEnv(overrides: Partial<BackendEnv> = {}): BackendEnv {
  return {
    deploymentEnv: "local",
    chainId: 1,
    reactorAddress: addresses.reactor,
    instantRedemptionAdapterAddress: addresses.adapter,
    curatorRegistryAddress: addresses.curatorRegistry,
    permit2Address: addresses.permit2,
    protocolSigner,
    protocolSignerAddress: protocolSigner.address.toLowerCase() as `0x${string}`,
    localFunder,
    databaseUrl: "postgres://backend",
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
        permit2: addresses.permit2,
        curatorRegistry: addresses.curatorRegistry,
        instantRedemptionAdapter: addresses.adapter,
        reactor: addresses.reactor,
        executor: addresses.solverA,
        mockSwapRouter: addresses.solverB,
        vaultFactory: addresses.vaultFactory,
      },
      participants: {
        protocolSigner: protocolSigner.address,
        executorCaller: addresses.solverA,
        marketMaker: addresses.solverB,
      },
      tokens: {
        input: [{ address: addresses.tokenIn, symbol: "TIN", name: "Token In", decimals: 18 }],
        output: [
          { address: addresses.tokenOut, symbol: "TOUT", name: "Token Out", decimals: 18 },
          { address: addresses.secondaryTokenOut, symbol: "TOUT2", name: "Token Out 2", decimals: 18 },
        ],
        defaultInput: addresses.tokenIn,
        defaultOutput: addresses.tokenOut,
      },
      vaults: [
        {
          address: addresses.vault,
          collateral: addresses.tokenOut,
          name: "Mock Vault",
        },
      ],
    },
    vaults: [addresses.vault],
    rpcUrls: [],
    solverSharedSecret: undefined,
    host: "127.0.0.1",
    port: 42072,
    logLevel: "silent",
    permitDeadlineSeconds: 120,
    solverTimeoutMs: 50,
    ...overrides,
  };
}

type PublicClientConfig = {
  readonly allowance?: bigint;
  readonly vaultCollaterals?: Record<`0x${string}`, `0x${string}`>;
  readonly tokenDecimals?: Record<`0x${string}`, number>;
  readonly pausedVaults?: readonly `0x${string}`[];
  readonly maxAssetsByVault?: Record<`0x${string}`, bigint>;
  readonly maxRateByVault?: Record<`0x${string}`, bigint>;
  readonly amountOutByCollateral?: Record<`0x${string}`, bigint>;
  readonly marketMakerByVault?: Record<`0x${string}`, `0x${string}`>;
  readonly curatorByVault?: Record<`0x${string}`, `0x${string}`>;
  readonly isFillerByMarketMaker?: Record<`0x${string}`, boolean>;
  readonly isUsedNonceByPair?: Record<string, boolean>;
  readonly minDiscountByPair?: Record<string, bigint>;
  readonly vaults?: readonly `0x${string}`[];
  readonly multicallFailureMode?: "all-fail";
};

export function createMockPublicClient(config: PublicClientConfig = {}) {
  const pausedVaults = new Set(config.pausedVaults ?? []);
  const vaults = config.vaults ?? [addresses.vault];

  return {
    async getTransactionCount() {
      return 7;
    },
    async waitForTransactionReceipt() {
      return { status: "success" } as const;
    },
    async readContract({
      address,
      functionName,
      args,
    }: {
      readonly address: `0x${string}`;
      readonly functionName: string;
      readonly args?: readonly unknown[];
    }) {
      switch (functionName) {
        case "VAULT_FACTORY":
          return addresses.vaultFactory;
        case "allowance":
          return config.allowance ?? 0n;
        case "collateral":
          return config.vaultCollaterals?.[address] ?? addresses.tokenOut;
        case "decimals":
          return config.tokenDecimals?.[address] ?? 18;
        case "totalEntities":
          return BigInt(vaults.length);
        case "entity":
          return vaults[Number(args?.[0] ?? 0)] ?? addresses.vault;
        case "isPaused":
          return pausedVaults.has(args?.[0] as `0x${string}`);
        case "getMaxAssets":
          return config.maxAssetsByVault?.[args?.[0] as `0x${string}`] ?? 1_000_000n;
        case "getMaxRate":
          return config.maxRateByVault?.[args?.[0] as `0x${string}`] ?? 1_000_000_000_000_000_000n;
        case "getAmountOut":
          return config.amountOutByCollateral?.[args?.[1] as `0x${string}`] ?? 1_000_000n;
        case "marketMaker":
          return config.marketMakerByVault?.[args?.[0] as `0x${string}`] ?? addresses.referrer;
        case "getCurator":
          return config.curatorByVault?.[args?.[0] as `0x${string}`] ?? addresses.solverC;
        case "isFiller":
          return config.isFillerByMarketMaker?.[args?.[0] as `0x${string}`] ?? true;
        case "isUsedNonce":
          return config.isUsedNonceByPair?.[
            `${String(args?.[0]).toLowerCase()}:${String(args?.[1]).toLowerCase()}:${String(args?.[2])}`
          ] ?? false;
        case "minDiscount":
          return (
            config.minDiscountByPair?.[
              `${String(args?.[0]).toLowerCase()}:${String(args?.[1]).toLowerCase()}`
            ] ?? 0n
          );
        default:
          throw new Error(`Unsupported readContract call: ${functionName}`);
      }
    },
    async multicall({
      contracts,
    }: {
      readonly contracts: ReadonlyArray<{
        readonly address: `0x${string}`;
        readonly functionName: string;
        readonly args?: readonly unknown[];
      }>;
      readonly allowFailure?: boolean;
    }) {
      if (config.multicallFailureMode === "all-fail") {
        return contracts.map(() => ({
          status: "failure" as const,
        }));
      }

      return Promise.all(
        contracts.map(async (contract) => ({
          result: await this.readContract(contract),
          status: "success" as const,
        })),
      );
    },
  } as RfqServiceDependencies["publicClient"];
}

export function createMockWalletClient() {
  return {
    async sendTransaction() {
      return `0x${"12".repeat(32)}` as `0x${string}`;
    },
  } as unknown as RfqServiceDependencies["walletClient"];
}

export type MemoryRepositoryState = {
  solvers: SolverConfig[];
  quotes: QuoteRequestRecord[];
  solverQuotes: SolverQuoteRecord[];
  orders: OrderRecord[];
  orderStatusHistory: Array<{
    readonly orderId: string;
    readonly publicStatus: OrderPublicStatus;
    readonly internalStatus: OrderInternalStatus;
    readonly reason: string | null;
    readonly createdAt: Date;
  }>;
  discounts: DiscountRecord[];
  settledAmountsByOrderHash: Map<`0x${string}`, SettledAmount[]>;
  delegatedAuthorizedFillersByMarketMaker: Map<`0x${string}`, string[]>;
};

export function createMemoryRepositories(input: Partial<MemoryRepositoryState> = {}) {
  const state: MemoryRepositoryState = {
    solvers: [...(input.solvers ?? [])],
    quotes: [...(input.quotes ?? [])],
    solverQuotes: [...(input.solverQuotes ?? [])],
    orders: [...(input.orders ?? [])],
    orderStatusHistory: [...(input.orderStatusHistory ?? [])],
    discounts: [...(input.discounts ?? [])],
    settledAmountsByOrderHash: new Map(input.settledAmountsByOrderHash ?? []),
    delegatedAuthorizedFillersByMarketMaker: new Map(input.delegatedAuthorizedFillersByMarketMaker ?? []),
  };

  const fills: FillReadRepository = {
    async listSettledAmounts(orderHashes) {
      const result = new Map<`0x${string}`, SettledAmount[]>();
      for (const orderHash of orderHashes) {
        result.set(orderHash, state.settledAmountsByOrderHash.get(orderHash) ?? []);
      }
      return result;
    },
    async listAuthorizedFillersForMarketMakers(_chainId, marketMakers) {
      const authorizations = new Map<string, ReadonlySet<string>>();
      for (const marketMaker of marketMakers) {
        const configured = state.delegatedAuthorizedFillersByMarketMaker.get(marketMaker);
        const fillers = configured ?? [addresses.solverA, addresses.solverB, addresses.solverC];
        authorizations.set(marketMaker, new Set(fillers.map((entry) => entry.toLowerCase())));
      }
      return authorizations;
    },
    async listIndexedVaults(_chainId) {
      return [];
    },
  };

  const repositories: BackendRepositories = {
    solvers: {
      async create(solver) {
        state.solvers.push(solver);
      },
      async upsert(solver) {
        const existing = state.solvers.find((candidate) => candidate.id === solver.id);
        if (!existing) {
          state.solvers.push(solver);
          return;
        }

        const index = state.solvers.indexOf(existing);
        state.solvers[index] = solver;
      },
      async listEligible(chainId, at) {
        return state.solvers.filter(
          (solver) =>
            solver.chainId === chainId &&
            solver.enabled &&
            (solver.cooldownUntil === null || solver.cooldownUntil.getTime() <= at.getTime()),
        );
      },
    },
    quotes: {
      async create(quoteRequest) {
        state.quotes.push(quoteRequest);
      },
      async finalize(input) {
        const quote = state.quotes.find((candidate) => candidate.quoteId === input.quoteId);
        if (!quote) {
          throw new Error(`Unknown quoteId ${input.quoteId}`);
        }

        const index = state.quotes.indexOf(quote);
        state.quotes[index] = {
          ...quote,
          permitData: input.permitData,
          outputs: input.outputs,
          bestAmountOut: input.bestAmountOut,
          bestFiller: input.bestFiller,
          selectedSolverId: input.solverId,
        };
      },
      async findByQuoteId(quoteId) {
        return state.quotes.find((quote) => quote.quoteId === quoteId) ?? null;
      },
    },
    solverQuotes: {
      async create(record) {
        state.solverQuotes.push(record);
      },
      async listByQuoteRequest(quoteRequestId) {
        return state.solverQuotes.filter((record) => record.quoteRequestId === quoteRequestId);
      },
    },
    discounts: {
      async upsertLive(record) {
        state.discounts = state.discounts.filter(
          (candidate) => !(candidate.chainId === record.chainId && candidate.vault === record.vault && candidate.tokenToRedeem === record.tokenToRedeem),
        );
        state.discounts.push(record);
      },
      async listLive(chainId) {
        return state.discounts.filter((record) => record.chainId === chainId);
      },
      async findByDiscountId(discountId) {
        return state.discounts.find((record) => record.discountId === discountId) ?? null;
      },
      async findByPair(chainId, vault, tokenToRedeem) {
        return (
          state.discounts.find(
            (record) => record.chainId === chainId && record.vault === vault && record.tokenToRedeem === tokenToRedeem,
          ) ?? null
        );
      },
      async deleteByDiscountId(discountId) {
        state.discounts = state.discounts.filter((record) => record.discountId !== discountId);
      },
      async deleteByPair(chainId, vault, tokenToRedeem) {
        state.discounts = state.discounts.filter(
          (record) => !(record.chainId === chainId && record.vault === vault && record.tokenToRedeem === tokenToRedeem),
        );
      },
    },
    orders: {
      async create(order) {
        state.orders.push(order);
      },
      async findByOrderId(orderId) {
        return state.orders.find((order) => order.orderId === orderId) ?? null;
      },
      async findByQuoteIdAndSignature(quoteId, swapperSignature) {
        return (
          state.orders.find((order) => order.quoteId === quoteId && order.swapperSignature === swapperSignature) ?? null
        );
      },
      async list(filters) {
        const filtered = state.orders
          .filter((order) => {
            if (filters.orderId && order.orderId !== filters.orderId) return false;
            if (filters.orderIds && !filters.orderIds.includes(order.orderId)) return false;
            if (filters.orderStatus && order.publicStatus !== filters.orderStatus) return false;
            if (filters.swapper && order.swapper !== filters.swapper) return false;
            if (filters.filler && order.filler !== filters.filler) return false;
            return true;
          })
          .sort((left, right) => {
            const sortKey = filters.sortKey ?? "createdAt";
            const leftValue = left[sortKey].getTime();
            const rightValue = right[sortKey].getTime();
            return filters.sort === "asc" ? leftValue - rightValue : rightValue - leftValue;
          });

        return {
          orders: filtered.slice(0, filters.limit ?? 20),
          cursor: null,
        };
      },
      async updateStatus(orderId, publicStatus, internalStatus, txHash) {
        const order = state.orders.find((candidate) => candidate.orderId === orderId);
        if (!order) {
          throw new Error(`Unknown orderId ${orderId}`);
        }

        const index = state.orders.indexOf(order);
        state.orders[index] = {
          ...order,
          publicStatus,
          internalStatus,
          txHash: txHash ?? null,
          updatedAt: new Date(),
        };
      },
    },
    orderStatusHistory: {
      async append(input) {
        state.orderStatusHistory.push(input);
      },
    },
    fills,
  };

  return { state, repositories };
}

export function createTestService(input: {
  readonly env?: Partial<BackendEnv>;
  readonly publicClientConfig?: PublicClientConfig;
  readonly repositories?: BackendRepositories;
  readonly fetchImpl?: typeof fetch;
  readonly now?: () => Date;
}) {
  const env = createTestEnv(input.env);
  const metrics = createMetrics();

  return new RfqService({
    env,
    publicClient: createMockPublicClient(input.publicClientConfig),
    walletClient: createMockWalletClient(),
    repositories: input.repositories ?? createMemoryRepositories().repositories,
    metrics,
    fetchImpl: input.fetchImpl ?? fetch,
    now: input.now ?? (() => new Date("2026-03-30T00:00:00.000Z")),
  });
}

export async function signPermitQuote(
  quote: NonNullable<Awaited<ReturnType<RfqService["quote"]>>>,
  account = swapperAccount,
) {
  const signTypedData = account.signTypedData as (input: {
    readonly domain: Record<string, unknown>;
    readonly types: Record<string, readonly Record<string, string>[]>;
    readonly primaryType: string;
    readonly message: Record<string, unknown>;
  }) => Promise<`0x${string}`>;

  return signTypedData({
    domain: quote.permitData.domain,
    types: quote.permitData.types,
    primaryType: "PermitWitnessTransferFrom",
    message: quote.permitData.value,
  });
}

export function createSolverConfig(input: {
  readonly id: string;
  readonly name: string;
  readonly endpointUrl: string;
  readonly filler?: `0x${string}`;
  readonly enabled?: boolean;
  readonly cooldownUntil?: Date | null;
  readonly notifyUrl?: string | null;
}): SolverConfig {
  const now = new Date("2026-03-30T00:00:00.000Z");

  return {
    id: input.id,
    chainId: 1,
    name: input.name,
    endpointUrl: input.endpointUrl,
    notifyUrl: input.notifyUrl ?? null,
    filler: input.filler ?? addresses.solverA,
    enabled: input.enabled ?? true,
    cooldownUntil: input.cooldownUntil ?? null,
    metadata: {},
    createdAt: now,
    updatedAt: now,
  };
}

export function delayedJsonResponse(
  payload: Record<string, unknown>,
  delayMs: number,
  init?: RequestInit,
  status = 200,
): Promise<Response> {
  return new Promise((resolve, reject) => {
    const signal = init?.signal;

    const abort = () => {
      const error = new Error("Aborted");
      error.name = "AbortError";
      reject(error);
    };

    if (signal?.aborted) {
      abort();
      return;
    }

    signal?.addEventListener("abort", abort, { once: true });
    setTimeout(() => {
      signal?.removeEventListener("abort", abort);
      resolve(
        new Response(JSON.stringify(payload), {
          status,
          headers: { "Content-Type": "application/json" },
        }),
      );
    }, delayMs);
  });
}

export function createDiscountRecord(input: Partial<DiscountRecord> = {}): DiscountRecord {
  const now = new Date("2026-03-30T00:00:00.000Z");

  return {
    discountId: (`0x${"ab".repeat(32)}`) as `0x${string}`,
    chainId: 1,
    vault: addresses.vault,
    tokenToRedeem: addresses.tokenIn,
    discountPpm: "50000",
    signer: addresses.solverC,
    protocol: addresses.protocol,
    nonce: "0x01",
    deadline: Math.floor(now.getTime() / 1000) + 3600,
    signerSignature: (`0x${"cd".repeat(65)}`) as `0x${string}`,
    createdAt: now,
    updatedAt: now,
    ...input,
  };
}
