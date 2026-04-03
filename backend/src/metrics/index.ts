import { Counter, Histogram, Registry, collectDefaultMetrics } from "prom-client";

export type BackendMetrics = ReturnType<typeof createMetrics>;

/**
 * @dev Creates the Prometheus registry and RFQ-specific metrics.
 * @returns A metrics container used by the backend service.
 */
export function createMetrics() {
  const registry = new Registry();
  collectDefaultMetrics({ register: registry });

  return {
    registry,
    quoteRequests: new Counter({
      name: "rfq_quote_requests_total",
      help: "Number of RFQ quote requests handled by the backend",
      labelNames: ["route", "result"] as const,
      registers: [registry],
    }),
    solverQuoteLatencyMs: new Histogram({
      name: "rfq_solver_quote_latency_ms",
      help: "Latency of solver quote requests",
      labelNames: ["solver_id", "phase", "status"] as const,
      buckets: [25, 50, 100, 250, 500, 1000, 2000],
      registers: [registry],
    }),
    ordersCreated: new Counter({
      name: "rfq_orders_created_total",
      help: "Number of orders created by the backend",
      labelNames: ["result"] as const,
      registers: [registry],
    }),
    orderStatusTransitions: new Counter({
      name: "rfq_order_status_transitions_total",
      help: "Number of order status transitions",
      labelNames: ["public_status", "internal_status"] as const,
      registers: [registry],
    }),
    indexerJoinMisses: new Counter({
      name: "rfq_indexer_join_misses_total",
      help: "Number of orders that had no matching indexed fill",
      registers: [registry],
    }),
  };
}
