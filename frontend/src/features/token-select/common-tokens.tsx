import { useMemo } from "react";

import { TokenIcon } from "../../components/token-icon";
import { COMMON_TOKEN_ADDRESSES } from "../../data/common-tokens";
import { TOKENS } from "../../data/tokens";
import type { Token } from "../../types/token";
import styles from "./common-tokens.module.css";

type CommonTokensProps = {
  readonly onSelect: (token: Token) => void;
};

export function CommonTokens({ onSelect }: CommonTokensProps) {
  const commonTokens = useMemo(
    () =>
      COMMON_TOKEN_ADDRESSES.map((addr) => TOKENS.find((t) => t.address.toLowerCase() === addr.toLowerCase())).filter(
        (t): t is Token => t !== undefined,
      ),
    [],
  );

  return (
    <div className={styles.container}>
      {commonTokens.map((token) => (
        <button
          key={token.address}
          className={styles.chip}
          onClick={() => onSelect(token)}
          type="button"
          aria-label={`Select ${token.symbol}`}
        >
          <TokenIcon src={token.logoURI} symbol={token.symbol} size={18} />
          <span className={styles.symbol}>{token.symbol}</span>
        </button>
      ))}
    </div>
  );
}
