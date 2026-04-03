import { Modal } from "../../components/modal";
import { useImportableToken } from "../../hooks/use-importable-token";
import { useTokenList } from "../../hooks/use-token-list";
import type { Token } from "../../types/token";
import { TokenList } from "./token-list";
import { TokenSearchInput } from "./token-search-input";
import styles from "./token-select-modal.module.css";

type TokenSelectModalProps = {
  readonly open: boolean;
  readonly onClose: () => void;
  readonly onSelect: (token: Token) => void;
  readonly tokens: ReadonlyArray<Token>;
  readonly allowImport?: boolean;
};

export function TokenSelectModal({ open, onClose, onSelect, tokens, allowImport = false }: TokenSelectModalProps) {
  const { query, setQuery, tokens: filteredTokens } = useTokenList(tokens);
  const { isAddressQuery, isKnownToken, resolvedToken, isLoading } = useImportableToken(query, tokens);
  const importedResultToken =
    allowImport && resolvedToken && !isKnownToken
      ? ({
          ...resolvedToken,
          importWarning: "Imported by address. Verify the token contract before swapping.",
        } satisfies Token)
      : null;

  const handleSelect = (token: Token) => {
    onSelect(token);
    setQuery("");
  };

  const handleClose = () => {
    onClose();
    setQuery("");
  };

  const displayTokens = importedResultToken ? [importedResultToken] : filteredTokens;
  const emptyText =
    allowImport && isAddressQuery && !isKnownToken && !importedResultToken && !isLoading
      ? "Not ERC-20 token"
      : "No tokens found";
  const emptyContent =
    allowImport && isAddressQuery && !isKnownToken && !importedResultToken && isLoading ? (
      <div className={styles.loadingRow} role="status" aria-live="polite" aria-label="Loading token">
        <span className={styles.loadingIcon} aria-hidden="true" />
        <div className={styles.loadingInfo}>
          <span className={styles.loadingName} aria-hidden="true" />
          <span className={styles.loadingMeta} aria-hidden="true" />
        </div>
        <span className={styles.loadingBalance} aria-hidden="true" />
      </div>
    ) : undefined;

  return (
    <Modal
      open={open}
      onClose={handleClose}
      ariaLabel="Select token"
      cardClassName={styles.modalCard}
      headerContent={<TokenSearchInput value={query} onChange={setQuery} />}
    >
      <div className={styles.content}>
        <TokenList
          tokens={displayTokens}
          onSelect={handleSelect}
          emptyText={emptyText}
          emptyContent={emptyContent}
          emptyContentAsList={isLoading}
        />
      </div>
    </Modal>
  );
}
