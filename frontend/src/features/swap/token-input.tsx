import { useId, useRef } from "react";
import { formatUnits } from "viem";

import { NumberInput } from "../../components/number-input";
import { TokenIcon } from "../../components/token-icon";
import { useTokenBalance } from "../../hooks/use-token-balances";
import { useTokenPrice } from "../../hooks/use-token-prices";
import { useWallet } from "../../hooks/use-wallet";
import type { Token } from "../../types/token";
import { formatUSD } from "../../utils/format-currency";
import { formatTokenAmount } from "../../utils/format-number";
import styles from "./token-input.module.css";

type TokenInputProps = {
  readonly label: string;
  readonly token: Token | null;
  readonly amount: string;
  readonly disabled?: boolean;
  readonly onAmountChange: (value: string) => void;
  readonly onTokenSelect: () => void;
};

function trimFractionalZeros(value: string) {
  if (!value.includes(".")) {
    return value;
  }

  return value.replace(/\.?0+$/, "").replace(/\.$/, "");
}

export function TokenInput({ label, token, amount, disabled = false, onAmountChange, onTokenSelect }: TokenInputProps) {
  const labelId = useId();
  const inputId = useId();
  const inputRef = useRef<HTMLInputElement>(null);
  const { isConnected } = useWallet();
  const { data: balance, isPending: isBalancePending } = useTokenBalance(token);
  const price = useTokenPrice(token?.address);

  const usdValue = price && amount ? price * parseFloat(amount || "0") : null;

  const handleSetBalanceAmount = (e: React.MouseEvent<HTMLButtonElement>) => {
    e.stopPropagation();
    if (disabled || !token || !balance) {
      return;
    }

    const formattedBalance = trimFractionalZeros(formatUnits(balance.value, token.decimals));

    onAmountChange(formattedBalance || "0");
    inputRef.current?.focus();
  };

  const handleContainerClick = (e: React.MouseEvent) => {
    if (disabled) {
      return;
    }

    const target = e.target as HTMLElement;
    if (!target.closest("button")) {
      inputRef.current?.focus();
    }
  };

  return (
    <div
      className={[styles.container, disabled ? styles.disabled : ""].filter(Boolean).join(" ")}
      onClick={handleContainerClick}
    >
      <div className={styles.labelRow}>
        <label id={labelId} className={styles.label} htmlFor={inputId}>
          {label}
        </label>
      </div>
      <div className={styles.row}>
        <NumberInput
          ref={inputRef}
          id={inputId}
          name={`${label.toLowerCase()}-amount`}
          aria-labelledby={labelId}
          value={amount}
          onChange={onAmountChange}
          placeholder="0"
          readOnly={disabled}
        />
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
        <div className={styles.usdValue}>{usdValue !== null && usdValue > 0 && formatUSD(usdValue)}</div>
        <div className={styles.balanceInfo}>
          {token && isConnected && (
            <button
              className={styles.balanceButton}
              onClick={handleSetBalanceAmount}
              type="button"
              aria-label={`Use full ${token.symbol} balance`}
              disabled={!balance || disabled}
            >
              <span className={styles.balanceAction}>Max</span>
              {balance ? (
                <span className={styles.balance}>{formatTokenAmount(balance.value.toString(), token.decimals, 4)}</span>
              ) : isBalancePending ? (
                <span className={styles.balanceSkeleton} aria-hidden="true" />
              ) : null}
            </button>
          )}
        </div>
      </div>
    </div>
  );
}
