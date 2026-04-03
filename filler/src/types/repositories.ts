import type { ExecutionAttemptRecord, LocalOrderRecord, StrategyRecord } from "./domain";

export interface StrategyRepository {
  upsert(strategy: StrategyRecord): Promise<void>;
  findByQuoteId(quoteId: string): Promise<StrategyRecord | null>;
}

export interface LocalOrderRepository {
  upsertQueued(input: {
    readonly orderId: string;
    readonly orderHash?: `0x${string}` | null;
    readonly quoteId: string | null;
    readonly source: "notify" | "poll";
    readonly filler: `0x${string}` | null;
    readonly encodedOrder?: `0x${string}` | null;
    readonly protocolSignature?: `0x${string}` | null;
    readonly deadline?: number | null;
  }): Promise<void>;
  hydrateExecutable(input: {
    readonly orderId: string;
    readonly quoteId: string;
    readonly filler: `0x${string}`;
    readonly encodedOrder: `0x${string}`;
    readonly protocolSignature: `0x${string}`;
    readonly deadline: number;
  }): Promise<LocalOrderRecord>;
  findByOrderId(orderId: string): Promise<LocalOrderRecord | null>;
  findByOrderHash(orderHash: `0x${string}`): Promise<LocalOrderRecord | null>;
  listActive(): Promise<LocalOrderRecord[]>;
  markStatus(
    orderId: string,
    status: LocalOrderRecord["status"],
    input?: {
      readonly txHash?: `0x${string}` | null;
      readonly lastError?: string | null;
    },
  ): Promise<void>;
}

export interface ExecutionAttemptRepository {
  append(record: ExecutionAttemptRecord): Promise<void>;
  countByOrderId(orderId: string): Promise<number>;
}

export type FillerRepositories = {
  readonly strategies: StrategyRepository;
  readonly orders: LocalOrderRepository;
  readonly attempts: ExecutionAttemptRepository;
};
