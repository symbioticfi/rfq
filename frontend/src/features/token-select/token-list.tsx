import type { ReactNode } from "react";

import type { Token } from "../../types/token";
import styles from "./token-list.module.css";
import { TokenRow } from "./token-row";

type TokenListProps = {
  readonly tokens: ReadonlyArray<Token>;
  readonly onSelect: (token: Token) => void;
  readonly emptyText?: string;
  readonly emptyContent?: ReactNode;
  readonly emptyContentAsList?: boolean;
};

export function TokenList({
  tokens,
  onSelect,
  emptyText = "No tokens found",
  emptyContent,
  emptyContentAsList = false,
}: TokenListProps) {
  if (tokens.length === 0) {
    if (emptyContent && emptyContentAsList) {
      return <div className={styles.list}>{emptyContent}</div>;
    }

    return <div className={styles.empty}>{emptyContent ?? <span className={styles.emptyText}>{emptyText}</span>}</div>;
  }

  return (
    <div className={styles.list}>
      {tokens.map((token) => (
        <TokenRow key={token.address} token={token} onSelect={onSelect} />
      ))}
    </div>
  );
}
