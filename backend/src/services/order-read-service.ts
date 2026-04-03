import type { BackendMetrics } from "../metrics";
import type { OrderListItem, OrderRecord } from "../types/domain";
import type { BackendRepositories, OrderListFilters } from "../types/repositories";
import { getLowercasedAddress } from "../lib/reactor";
import { newUuid } from "../utils/ids";

export class OrderReadService {
  readonly #repositories: BackendRepositories;
  readonly #metrics: BackendMetrics;
  readonly #now: () => Date;

  constructor(input: {
    readonly repositories: BackendRepositories;
    readonly metrics: BackendMetrics;
    readonly now: () => Date;
  }) {
    this.#repositories = input.repositories;
    this.#metrics = input.metrics;
    this.#now = input.now;
  }

  async listOrders(filters: OrderListFilters) {
    await this.#reconcileFilledOrders();
    await this.#reconcileExpiredOrders();
    const { orders, cursor } = await this.#repositories.orders.list(filters);
    const fillsByOrderHash = await this.#repositories.fills.listSettledAmounts(orders.map((order) => order.orderHash));
    const orderItems = orders.map((order): OrderListItem => {
      const settledAmounts = fillsByOrderHash.get(order.orderHash) ?? [];
      const txHash = order.txHash ?? settledAmounts[0]?.txHash ?? null;
      const orderStatus =
        settledAmounts.length > 0 && (order.publicStatus === "open" || order.publicStatus === "expired")
          ? "filled"
          : order.publicStatus;
      if (settledAmounts.length === 0 && order.publicStatus === "filled") {
        this.#metrics.indexerJoinMisses.inc();
      }

      const isFillerOpenView =
        getLowercasedAddress(filters.filler) === getLowercasedAddress(order.filler) && orderStatus === "open";
      return {
        type: "Priority",
        orderId: order.orderId,
        orderStatus,
        quoteId: order.quoteId,
        swapper: order.swapper,
        txHash,
        nonce: order.nonce,
        input: {
          token: order.tokenIn,
          amount: order.amountIn,
        },
        outputs: order.outputs,
        settledAmounts,
        encodedOrder: isFillerOpenView ? order.encodedOrder : undefined,
        signature: isFillerOpenView ? order.protocolSignature : undefined,
        deadline: isFillerOpenView ? order.deadline : undefined,
        filler: isFillerOpenView ? order.filler : undefined,
      };
    });

    return {
      requestId: newUuid(),
      orders: orderItems,
      cursor,
    };
  }

  async #reconcileExpiredOrders() {
    const orders = await this.#listAllOrders({
      orderStatus: "open",
      limit: 1_000,
    });
    const nowSeconds = Math.floor(this.#now().getTime() / 1000);

    for (const order of orders) {
      if (order.deadline > nowSeconds) {
        continue;
      }

      await this.#repositories.orders.updateStatus(order.orderId, "expired", "expired");
      await this.#repositories.orderStatusHistory.append({
        orderId: order.orderId,
        publicStatus: "expired",
        internalStatus: "expired",
        reason: "deadline",
        createdAt: this.#now(),
      });
      this.#metrics.orderStatusTransitions.inc({
        public_status: "expired",
        internal_status: "expired",
      });
    }
  }

  async #reconcileFilledOrders() {
    const openOrders = await this.#listAllOrders({ orderStatus: "open", limit: 1_000 });
    const expiredOrders = await this.#listAllOrders({ orderStatus: "expired", limit: 1_000 });
    const candidates = [...openOrders, ...expiredOrders];
    if (candidates.length === 0) {
      return;
    }

    const fillsByOrderHash = await this.#repositories.fills.listSettledAmounts(
      candidates.map((order) => order.orderHash),
    );

    for (const order of candidates) {
      const settledAmounts = fillsByOrderHash.get(order.orderHash) ?? [];
      if (settledAmounts.length === 0) {
        continue;
      }

      const txHash = settledAmounts[0]?.txHash ?? null;
      await this.#repositories.orders.updateStatus(order.orderId, "filled", "filled", txHash);
      await this.#repositories.orderStatusHistory.append({
        orderId: order.orderId,
        publicStatus: "filled",
        internalStatus: "filled",
        reason: "indexed_fill",
        createdAt: this.#now(),
      });
      this.#metrics.orderStatusTransitions.inc({
        public_status: "filled",
        internal_status: "filled",
      });
    }
  }

  async #listAllOrders(filters: OrderListFilters) {
    const orders: OrderRecord[] = [];
    let cursor: string | null = null;

    while (true) {
      const page = await this.#repositories.orders.list({
        ...filters,
        ...(cursor ? { cursor } : {}),
      });
      orders.push(...page.orders);

      if (!page.cursor) {
        return orders;
      }

      cursor = page.cursor;
    }
  }
}
