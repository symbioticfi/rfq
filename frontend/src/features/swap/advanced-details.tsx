import { formatUnits } from "viem";

import type { Token } from "../../types/token";
import { formatTokenAmount } from "../../utils/format-number";
import { calcMinReceived } from "../../utils/slippage";
import styles from "./advanced-details.module.css";

type AdvancedDetailsProps = {
  readonly amountOut: string;
  readonly buyToken: Token;
  readonly slippageBps: number;
  readonly minAmountOut?: string;
};

export function AdvancedDetails({ amountOut, buyToken, slippageBps, minAmountOut }: AdvancedDetailsProps) {
  const humanOut = formatUnits(BigInt(amountOut), buyToken.decimals);
  const fallbackMinReceivedRaw = calcMinReceived(humanOut, slippageBps);
  const minReceived = formatTokenAmount(
    minAmountOut ?? (parseFloat(fallbackMinReceivedRaw) * 10 ** buyToken.decimals).toFixed(0),
    buyToken.decimals,
    6,
  );
  const slippagePct = (slippageBps / 100).toFixed(1);

  return (
    <div className={styles.container}>
      <div className={styles.row}>
        <span className={styles.label}>Min received</span>
        <span className={styles.value}>
          {minReceived} {buyToken.symbol}
          <span className={styles.dim}> ({slippagePct}%)</span>
        </span>
      </div>
    </div>
  );
}
