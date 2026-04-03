import type { FillerRepositories } from "../types/repositories";
import type { ExecutionAttemptRecord, LocalOrderRecord, StrategyRecord } from "../types/domain";

/**
 * @dev Creates in-memory repositories for the filler runtime.
 * @returns The filler repositories.
 */
export function createFillerRepositories(): FillerRepositories {
  const strategies = new Map<string, StrategyRecord>();
  const orders = new Map<string, LocalOrderRecord>();
  const attempts = new Map<string, ExecutionAttemptRecord[]>();

  return {
    strategies: {
      async upsert(strategy) {
        strategies.set(strategy.quoteId, strategy);
      },
      async findByQuoteId(quoteId) {
        return strategies.get(quoteId) ?? null;
      },
    },
    orders: {
      async upsertQueued(input) {
        const existing = orders.get(input.orderId);
        const now = new Date();

        if (!existing) {
          orders.set(input.orderId, {
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
            createdAt: now,
            updatedAt: now,
          });
          return;
        }

        if (existing.status === "filled" || existing.status === "expired") {
          return;
        }

        orders.set(input.orderId, {
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
          updatedAt: now,
        });
      },
      async hydrateExecutable(input) {
        const existing = orders.get(input.orderId);
        if (!existing) {
          throw new Error(`Unknown local order ${input.orderId}`);
        }

        const next = {
          ...existing,
          quoteId: input.quoteId,
          filler: input.filler,
          encodedOrder: input.encodedOrder,
          protocolSignature: input.protocolSignature,
          deadline: input.deadline,
          updatedAt: new Date(),
        } satisfies LocalOrderRecord;
        orders.set(input.orderId, next);
        return next;
      },
      async findByOrderId(orderId) {
        return orders.get(orderId) ?? null;
      },
      async findByOrderHash(orderHash) {
        return [...orders.values()].find((order) => order.orderHash === orderHash) ?? null;
      },
      async listActive() {
        return [...orders.values()].filter((order) => ["queued", "submitting", "submitted"].includes(order.status));
      },
      async markStatus(orderId, status, input) {
        const existing = orders.get(orderId);
        if (!existing) {
          throw new Error(`Unknown local order ${orderId}`);
        }

        orders.set(orderId, {
          ...existing,
          status,
          txHash: input?.txHash !== undefined ? input.txHash : existing.txHash,
          lastError: input?.lastError !== undefined ? (input.lastError ?? null) : existing.lastError,
          updatedAt: new Date(),
        });
      },
    },
    attempts: {
      async append(record) {
        const orderAttempts = attempts.get(record.orderId) ?? [];
        orderAttempts.push(record);
        attempts.set(record.orderId, orderAttempts);
      },
      async countByOrderId(orderId) {
        return attempts.get(orderId)?.length ?? 0;
      },
    },
  };
}
