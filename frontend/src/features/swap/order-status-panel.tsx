import { ArrowRight, Copy } from "lucide-react";
import { toast } from "sonner";

import { TokenIcon } from "../../components/token-icon";
import type { Token } from "../../types/token";
import type { TrackedOrder } from "../../types/quote";
import { formatTokenAmountAdaptive } from "../../utils/format-number";
import styles from "./order-status-panel.module.css";

type OrderStatusPanelProps = {
  readonly order: TrackedOrder;
  readonly resolveToken: (address: string) => Token | null;
};

function statusClassName(status: TrackedOrder["displayStatus"]) {
  switch (status) {
    case "Pending":
      return styles.pending;
    case "Filled":
      return styles.filled;
    case "Expired":
      return styles.expired;
    default:
      return styles.failed;
  }
}

function renderAmount(amount: string, token: Token | null) {
  if (!token) {
    return amount;
  }

  return formatTokenAmountAdaptive(amount, token.decimals);
}

function formatOrderId(orderId: string) {
  return `${orderId.slice(0, 3)}...${orderId.slice(-4)}`;
}

async function copyOrderId(orderId: string) {
  await navigator.clipboard.writeText(orderId);
  toast.success("Order ID copied");
}

/**
 * @dev Renders the current tracked order lifecycle and settlement details.
 * @param props The tracked order plus token resolver.
 * @returns An inline lifecycle panel.
 */
export function OrderStatusPanel({ order, resolveToken }: OrderStatusPanelProps) {
  const inputToken = resolveToken(order.input.token);
  const output = order.settledAmounts[0] ?? order.outputs[0] ?? null;
  const outputToken = output ? resolveToken(output.token) : null;

  return (
    <section className={styles.container} aria-live="polite">
      <div className={styles.header}>
        <div className={styles.orderMeta}>
          <span className={styles.title}>Order</span>
          <span className={styles.orderId}>{formatOrderId(order.orderId)}</span>
          <button
            className={styles.copyButton}
            onClick={() => void copyOrderId(order.orderId)}
            type="button"
            aria-label="Copy order ID"
          >
            <Copy size={12} aria-hidden="true" />
          </button>
        </div>
        {order.displayStatus === "Pending" && (
          <span className={`${styles.status} ${statusClassName(order.displayStatus)}`}>{order.displayStatus}</span>
        )}
      </div>

      {output && (
        <div className={styles.flowRow}>
          <div className={styles.asset}>
            <span className={styles.amount}>{renderAmount(order.input.amount, inputToken)}</span>
            <TokenIcon src={inputToken?.logoURI} symbol={inputToken?.symbol ?? "?"} size={18} />
            <span className={styles.symbol}>{inputToken?.symbol ?? order.input.token}</span>
          </div>
          <ArrowRight className={styles.flowArrow} size={14} aria-hidden="true" />
          <div className={styles.asset}>
            <span className={styles.amount}>{renderAmount(output.amount, outputToken)}</span>
            <TokenIcon src={outputToken?.logoURI} symbol={outputToken?.symbol ?? "?"} size={18} />
            <span className={styles.symbol}>{outputToken?.symbol ?? output.token}</span>
          </div>
        </div>
      )}
    </section>
  );
}
