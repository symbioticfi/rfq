import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Coins, Copy } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { getAddress, isAddress } from "viem";
import { toast } from "sonner";

import { fundFromLocalFaucet, getLocalFaucet } from "../../api/client";
import { TokenIcon } from "../../components/token-icon";
import { getTokenLogoUri, IS_HOODI_DEPLOYMENT, IS_LOCAL_DEPLOYMENT } from "../../config/rfq";
import { useWallet } from "../../hooks/use-wallet";
import type { FaucetAsset } from "../../types/quote";
import { formatTokenAmount } from "../../utils/format-number";
import styles from "./faucet-page.module.css";

function formatShortAddress(address: string) {
  return `${address.slice(0, 6)}...${address.slice(-4)}`;
}

type FaucetAssetRowProps = {
  readonly asset: FaucetAsset;
  readonly onCopyAddress: (address: string) => void;
};

function FaucetAssetRow({ asset, onCopyAddress }: FaucetAssetRowProps) {
  return (
    <div className={styles.assetRow}>
      <div className={styles.assetIdentity}>
        <TokenIcon src={getTokenLogoUri(asset.token)} symbol={asset.symbol} size={34} />
        <div className={styles.assetMeta}>
          <div className={styles.assetTopLine}>
            <span className={styles.assetSymbol}>{asset.symbol}</span>
            <span className={styles.assetName}>{asset.name}</span>
          </div>
          <button
            className={styles.addressButton}
            onClick={() => onCopyAddress(asset.token)}
            type="button"
            aria-label={`Copy ${asset.symbol} address`}
          >
            <span>{formatShortAddress(asset.token)}</span>
            <Copy size={12} aria-hidden="true" />
          </button>
        </div>
      </div>
      <div className={styles.assetAmount}>
        {formatTokenAmount(asset.amount, asset.decimals, 4)} {asset.symbol}
      </div>
    </div>
  );
}

export function FaucetPage() {
  const queryClient = useQueryClient();
  const { address, isConnected } = useWallet();
  const [walletAddress, setWalletAddress] = useState("");

  useEffect(() => {
    if (!walletAddress && isConnected && address) {
      setWalletAddress(address);
    }
  }, [address, isConnected, walletAddress]);

  const faucetQuery = useQuery({
    queryKey: ["local-faucet"],
    queryFn: getLocalFaucet,
    enabled: IS_LOCAL_DEPLOYMENT || IS_HOODI_DEPLOYMENT,
  });

  const fundMutation = useMutation({
    mutationFn: (targetAddress: `0x${string}`) => fundFromLocalFaucet(targetAddress),
    onSuccess: async (response) => {
      toast.success(`Faucet funded ${formatShortAddress(response.walletAddress)}`);
      await queryClient.invalidateQueries({ queryKey: ["token-balance"] });
    },
    onError: (error) => {
      toast.error(error instanceof Error ? error.message : "Faucet funding failed");
    },
  });

  const normalizedWalletAddress = useMemo(
    () => (isAddress(walletAddress) ? (getAddress(walletAddress) as `0x${string}`) : null),
    [walletAddress],
  );

  const handleCopyAddress = (assetAddress: string) => {
    void navigator.clipboard.writeText(assetAddress);
    toast.success("Address copied");
  };

  const handleSubmit = () => {
    if (!normalizedWalletAddress) {
      toast.error("Enter a valid wallet address");
      return;
    }

    fundMutation.mutate(normalizedWalletAddress);
  };

  if (!IS_LOCAL_DEPLOYMENT && !IS_HOODI_DEPLOYMENT) {
    return (
      <section className={styles.page}>
        <div className={styles.card}>
          <h1 className={styles.title}>Faucet unavailable</h1>
          <p className={styles.description}>The faucet page is only available on the local development deployment.</p>
        </div>
      </section>
    );
  }

  return (
    <section className={styles.page}>
      <div className={styles.card}>
        <div className={styles.header}>
          <div className={styles.badge}>
            <Coins size={14} aria-hidden="true" />
            Faucet
          </div>
          <h1 className={styles.title}>{IS_HOODI_DEPLOYMENT ? "Hoodi faucet" : "Local faucet"}</h1>
          <p className={styles.description}>
            {IS_HOODI_DEPLOYMENT
              ? "Fund a Hoodi wallet with test assets from the app faucet. For extra ETH, use the public Google faucet too."
              : "Send the fixed local dev bundle to any address. The bundle uses the same Anvil contracts as the swap flow."}
          </p>
        </div>

        {IS_HOODI_DEPLOYMENT && (
          <a
            className={styles.externalButton}
            href="https://cloud.google.com/application/web3/faucet/ethereum/hoodi"
            target="_blank"
            rel="noopener noreferrer"
          >
            Open Google Faucet
          </a>
        )}

        <label className={styles.field}>
          <span className={styles.fieldLabel}>Recipient</span>
          <input
            className={styles.input}
            type="text"
            inputMode="text"
            autoComplete="off"
            spellCheck={false}
            placeholder="0x..."
            value={walletAddress}
            onChange={(event) => setWalletAddress(event.target.value)}
            aria-label="Recipient wallet address"
          />
        </label>

        <div className={styles.bundleHeader}>
          <span>Assets</span>
          <span>Transfer amount</span>
        </div>

        <div className={styles.assetList}>
          {faucetQuery.isPending ? (
            <div className={styles.loading}>Loading faucet bundle…</div>
          ) : faucetQuery.isError ? (
            <div className={styles.error}>
              {faucetQuery.error instanceof Error ? faucetQuery.error.message : "Failed to load faucet bundle"}
            </div>
          ) : (
            faucetQuery.data?.assets.map((asset) => (
              <FaucetAssetRow key={asset.token.toLowerCase()} asset={asset} onCopyAddress={handleCopyAddress} />
            ))
          )}
        </div>

        <button
          className={styles.fundButton}
          type="button"
          disabled={!normalizedWalletAddress || faucetQuery.isPending || faucetQuery.isError || fundMutation.isPending}
          onClick={handleSubmit}
        >
          {fundMutation.isPending ? "Funding..." : "Fund"}
        </button>
      </div>
    </section>
  );
}
