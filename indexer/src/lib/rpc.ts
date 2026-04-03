import { fallback, http } from "viem";
import { mainnet } from "viem/chains";

export const httpConfig = {
  retryDelay: 0,
  timeout: 5_000,
} as const;

export type FallbackRpc = {
  readonly url: string;
  readonly batch?: false | { readonly batchSize: number };
};

export const mainnetFallbackRpcs: readonly FallbackRpc[] = [
  { url: "https://rpc.mevblocker.io", batch: { batchSize: 10 } },
  { url: "https://rpc.ankr.com/eth", batch: { batchSize: 10 } },
  { url: "https://eth-pokt.nodies.app", batch: false },
  { url: "https://eth.drpc.org", batch: false },
  { url: "https://eth.merkle.io", batch: false },
];

/**
 * @dev Builds the shared base fallback transport matching the frontend RPC profile.
 * @param chainId The active chain id.
 * @param customRpcUrls Explicit RPC URLs for override mode.
 * @returns A viem fallback transport suitable for Ponder.
 */
export function createIndexerTransport(chainId: number, customRpcUrls: readonly string[] = []) {
  if (chainId === mainnet.id && customRpcUrls.length === 0) {
    return fallback(
      mainnetFallbackRpcs.map(({ url, ...transportConfig }) => http(url, { ...httpConfig, ...transportConfig })),
      { retryCount: 6, retryDelay: 100 },
    );
  }

  return fallback(
    customRpcUrls.map((url) => http(url, { ...httpConfig, batch: { batchSize: 10 } })),
    { retryCount: 6, retryDelay: 100 },
  );
}
