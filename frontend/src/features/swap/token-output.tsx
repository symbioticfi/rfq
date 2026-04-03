import { formatUnits } from "viem";

import { TokenIcon } from "../../components/token-icon";
import { useTokenPrice } from "../../hooks/use-token-prices";
import type { Token } from "../../types/token";
import { formatUSD } from "../../utils/format-currency";
import { formatTokenAmountAdaptive } from "../../utils/format-number";
import { formatPriceImpact, priceImpactSeverity } from "../../utils/price-impact";
import styles from "./token-output.module.css";

type TokenOutputProps = {
  readonly label: string;
  readonly token: Token | null;
  readonly amountOut: string | undefined;
  readonly referenceUsdValue: number | null;
  readonly priceImpactBps: number | undefined;
  readonly isLoading: boolean;
  readonly disabled?: boolean;
  readonly onTokenSelect: () => void;
};

function formatSignedPercent(value: number) {
  const sign = value > 0 ? "+" : "-";

  return `${sign}${Math.abs(value).toFixed(1)}%`;
}

export function TokenOutput({
  label,
  token,
  amountOut,
  referenceUsdValue,
  priceImpactBps,
  isLoading,
  disabled = false,
  onTokenSelect,
}: TokenOutputProps) {
  const price = useTokenPrice(token?.address);
  const hasResolvedAmount = token && amountOut !== undefined;

  const displayAmount = token && amountOut ? formatTokenAmountAdaptive(amountOut, token.decimals) : "";

  const humanAmount = token && amountOut ? Number(formatUnits(BigInt(amountOut), token.decimals)) : 0;
  const usdValue = price && humanAmount > 0 ? price * humanAmount : null;
  const displayUsdValue = hasResolvedAmount && humanAmount === 0 ? 0 : usdValue;
  const usdDeltaPct =
    displayUsdValue !== null && referenceUsdValue !== null && referenceUsdValue > 0 && Number.isFinite(displayUsdValue)
      ? ((displayUsdValue - referenceUsdValue) / referenceUsdValue) * 100
      : null;
  const severity =
    usdDeltaPct !== null
      ? usdDeltaPct < 0
        ? "negative"
        : usdDeltaPct > 0
          ? "positive"
          : "neutral"
      : priceImpactSeverity(priceImpactBps);
  const impactText =
    usdDeltaPct !== null
      ? formatSignedPercent(usdDeltaPct)
      : priceImpactBps !== undefined && priceImpactBps !== 0
        ? formatPriceImpact(priceImpactBps)
        : null;

  return (
    <div className={[styles.container, disabled ? styles.disabled : ""].filter(Boolean).join(" ")}>
      <div className={styles.labelRow}>
        <span className={styles.label}>{label}</span>
      </div>
      <div className={styles.row}>
        <div className={styles.amountDisplay}>
          {isLoading ? (
            <span className={styles.amountSkeleton} aria-hidden="true" />
          ) : (
            <span className={styles.amount}>{displayAmount || "0"}</span>
          )}
        </div>
        <button
          className={styles.tokenButton}
          onClick={onTokenSelect}
          type="button"
          aria-haspopup="dialog"
          aria-label={token ? `${label} token ${token.symbol}` : `Select ${label} token`}
          disabled={disabled}
        >
          {token ? (
            <>
              <TokenIcon src={token.logoURI} symbol={token.symbol} size={28} />
              <span className={styles.tokenSymbol}>{token.symbol}</span>
            </>
          ) : (
            <span className={styles.selectText}>Select</span>
          )}
        </button>
      </div>
      <div className={styles.bottomRow}>
        <div className={styles.usdRow}>
          {isLoading ? (
            <span className={styles.usdSkeleton} aria-hidden="true" />
          ) : (
            displayUsdValue !== null && (
              <>
                <span className={styles.usdValue}>{formatUSD(displayUsdValue)}</span>
                {impactText !== null && <span className={`${styles.impact} ${styles[severity]}`}>({impactText})</span>}
              </>
            )
          )}
        </div>
        <div />
      </div>
    </div>
  );
}
