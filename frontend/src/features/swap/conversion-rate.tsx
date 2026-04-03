import { ChevronDown, Zap } from "lucide-react";
import { formatUnits } from "viem";

import { useTokenPrice } from "../../hooks/use-token-prices";
import type { Token } from "../../types/token";
import { formatUSD } from "../../utils/format-currency";
import { formatNumber } from "../../utils/format-number";
import styles from "./conversion-rate.module.css";

type ConversionRateProps = {
  readonly sellToken: Token;
  readonly buyToken: Token;
  readonly amountOut: string;
  readonly sellAmount: string;
  readonly direction: "forward" | "reverse";
  readonly onToggleDirection: () => void;
  readonly showAdvanced: boolean;
  readonly onToggleAdvanced: () => void;
};

export function ConversionRate({
  sellToken,
  buyToken,
  amountOut,
  sellAmount,
  direction,
  onToggleDirection,
  showAdvanced,
  onToggleAdvanced,
}: ConversionRateProps) {
  const sellPrice = useTokenPrice(sellToken.address);
  const buyPrice = useTokenPrice(buyToken.address);

  const sellNum = parseFloat(sellAmount);
  const buyNum = Number(formatUnits(BigInt(amountOut), buyToken.decimals));

  if (!sellNum || !buyNum || sellNum === 0) {
    return null;
  }

  const rate = direction === "forward" ? buyNum / sellNum : sellNum / buyNum;

  const fromToken = direction === "forward" ? sellToken : buyToken;
  const toToken = direction === "forward" ? buyToken : sellToken;
  const unitPrice = direction === "forward" ? sellPrice : buyPrice;

  return (
    <div className={`${styles.container} ${showAdvanced ? styles.expanded : ""}`}>
      <button className={styles.rateButton} onClick={onToggleDirection} type="button">
        <span className={styles.rateText}>
          1 {fromToken.symbol} = {formatNumber(rate, 4)} {toToken.symbol}
        </span>
        {unitPrice !== null && <span className={styles.rateUsd}>({formatUSD(unitPrice)})</span>}
      </button>
      <div className={styles.actions}>
        <div className={styles.gaslessRow}>
          <span className={styles.gaslessButton} aria-describedby="gasless-tooltip" tabIndex={0}>
            <span className={styles.gaslessLabel}>
              <Zap size={14} strokeWidth={2.1} />
              <span>Gasless</span>
            </span>
          </span>
          <div className={styles.gaslessMenu} id="gasless-tooltip" role="tooltip">
            <p className={styles.gaslessMenuText}>
              Submit a signature only. The filler sends the onchain transaction and pays the gas.
            </p>
          </div>
        </div>
        <button
          className={`${styles.expandButton} ${showAdvanced ? styles.chevronExpanded : ""}`}
          onClick={onToggleAdvanced}
          type="button"
          aria-label="Toggle details"
          aria-expanded={showAdvanced}
        >
          <ChevronDown size={14} aria-hidden="true" />
        </button>
      </div>
    </div>
  );
}
