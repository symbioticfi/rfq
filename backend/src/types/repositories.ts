import type {
  DiscountRecord,
  OrderInternalStatus,
  OrderPublicStatus,
  OrderRecord,
  QuoteRequestRecord,
  SettledAmount,
  SolverConfig,
  SolverQuoteRecord,
} from "./domain";

export type OrderListFilters = {
  readonly orderType?: string;
  readonly limit?: number;
  readonly cursor?: string;
  readonly orderStatus?: OrderPublicStatus;
  readonly orderId?: string;
  readonly orderIds?: readonly string[];
  readonly orderHash?: `0x${string}`;
  readonly orderHashes?: readonly `0x${string}`[];
  readonly swapper?: `0x${string}`;
  readonly filler?: `0x${string}`;
  readonly sortKey?: "createdAt" | "updatedAt";
  readonly sort?: "asc" | "desc";
};

export interface SolverRepository {
  create(solver: SolverConfig): Promise<void>;
  upsert(solver: SolverConfig): Promise<void>;
  listEligible(chainId: number, at: Date): Promise<SolverConfig[]>;
}

export interface QuoteRepository {
  create(quoteRequest: QuoteRequestRecord): Promise<void>;
  finalize(input: {
    readonly quoteId: string;
    readonly permitData: QuoteRequestRecord["permitData"];
    readonly outputs: QuoteRequestRecord["outputs"];
    readonly bestAmountOut: string;
    readonly bestFiller: `0x${string}`;
    readonly solverId: string;
  }): Promise<void>;
  findByQuoteId(quoteId: string): Promise<QuoteRequestRecord | null>;
}

export interface SolverQuoteRepository {
  create(record: SolverQuoteRecord): Promise<void>;
  listByQuoteRequest(quoteRequestId: string): Promise<SolverQuoteRecord[]>;
}

export interface DiscountRepository {
  upsertLive(record: DiscountRecord): Promise<void>;
  listLive(chainId: number): Promise<DiscountRecord[]>;
  findByDiscountId(discountId: `0x${string}`): Promise<DiscountRecord | null>;
  findByPair(chainId: number, vault: `0x${string}`, tokenToRedeem: `0x${string}`): Promise<DiscountRecord | null>;
  deleteByDiscountId(discountId: `0x${string}`): Promise<void>;
  deleteByPair(chainId: number, vault: `0x${string}`, tokenToRedeem: `0x${string}`): Promise<void>;
}

export interface OrderRepository {
  create(order: OrderRecord): Promise<void>;
  findByOrderId(orderId: string): Promise<OrderRecord | null>;
  findByQuoteIdAndSignature(quoteId: string, swapperSignature: `0x${string}`): Promise<OrderRecord | null>;
  list(filters: OrderListFilters): Promise<{ readonly orders: OrderRecord[]; readonly cursor: string | null }>;
  updateStatus(
    orderId: string,
    publicStatus: OrderPublicStatus,
    internalStatus: OrderInternalStatus,
    txHash?: `0x${string}` | null,
  ): Promise<void>;
}

export interface OrderStatusHistoryRepository {
  append(input: {
    readonly orderId: string;
    readonly publicStatus: OrderPublicStatus;
    readonly internalStatus: OrderInternalStatus;
    readonly reason: string | null;
    readonly createdAt: Date;
  }): Promise<void>;
}

export interface FillReadRepository {
  listSettledAmounts(orderHashes: readonly `0x${string}`[]): Promise<Map<`0x${string}`, SettledAmount[]>>;
  listAuthorizedFillersForMarketMakers(
    chainId: number,
    marketMakers: readonly `0x${string}`[],
  ): Promise<ReadonlyMap<string, ReadonlySet<string>>>;
  listIndexedVaults(chainId: number): Promise<readonly `0x${string}`[]>;
}

export type BackendRepositories = {
  readonly solvers: SolverRepository;
  readonly quotes: QuoteRepository;
  readonly solverQuotes: SolverQuoteRepository;
  readonly discounts: DiscountRepository;
  readonly orders: OrderRepository;
  readonly orderStatusHistory: OrderStatusHistoryRepository;
  readonly fills: FillReadRepository;
};
