import { ExclamationTriangleIcon } from "@radix-ui/react-icons";

import { TokenIcon } from "../../components/token-icon";
import { useTokenBalance } from "../../hooks/use-token-balances";
import type { Token } from "../../types/token";
import { formatAddress } from "../../utils/format-address";
import { formatTokenAmount } from "../../utils/format-number";
import styles from "./token-row.module.css";

type TokenRowProps = {
  readonly token: Token;
  readonly onSelect: (token: Token) => void;
};

export function TokenRow({ token, onSelect }: TokenRowProps) {
  const { data: balance } = useTokenBalance(token);

  const displayBalance = balance?.value ? formatTokenAmount(balance.value.toString(), token.decimals, 4) : null;
  const ariaLabel = token.importWarning ? `Select ${token.symbol}. ${token.importWarning}` : `Select ${token.symbol}`;

  return (
    <button className={styles.row} onClick={() => onSelect(token)} type="button" aria-label={ariaLabel}>
      <TokenIcon src={token.logoURI} symbol={token.symbol} size={36} />

      <div className={styles.info}>
        <div className={styles.nameRow}>
          <span className={styles.name}>{token.name}</span>
          {token.importWarning ? (
            <span className={styles.warning} title={token.importWarning} aria-label={token.importWarning}>
              <ExclamationTriangleIcon aria-hidden="true" />
            </span>
          ) : null}
        </div>
        <div className={styles.secondary}>
          <span className={styles.symbol}>{token.symbol}</span>
          <span className={styles.address}>{formatAddress(token.address, 6, 4)}</span>
        </div>
      </div>

      <div className={styles.balanceCol}>
        {displayBalance && <span className={styles.balance}>{displayBalance}</span>}
      </div>
    </button>
  );
}
