import { TokenIcon } from "../../components/token-icon";
import type { Token } from "../../types/token";
import { formatAddress } from "../../utils/format-address";
import styles from "./import-token-row.module.css";

type ImportTokenRowProps = {
  readonly token: Token;
  readonly onSelect: (token: Token) => void;
};

export function ImportTokenRow({ token, onSelect }: ImportTokenRowProps) {
  return (
    <button className={styles.row} onClick={() => onSelect(token)} type="button" aria-label={`Import ${token.symbol}`}>
      <div className={styles.label}>Import token</div>

      <div className={styles.content}>
        <TokenIcon src={token.logoURI} symbol={token.symbol} size={36} />

        <div className={styles.info}>
          <span className={styles.name}>{token.name}</span>
          <div className={styles.secondary}>
            <span className={styles.symbol}>{token.symbol}</span>
            <span className={styles.address}>{formatAddress(token.address, 8, 4)}</span>
          </div>
        </div>

        <span className={styles.badge}>ERC-20</span>
      </div>
    </button>
  );
}
