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

export const hoodiFallbackRpcs: readonly FallbackRpc[] = [
  { url: "https://0xrpc.io/hoodi", batch: { batchSize: 10 } },
  { url: "https://ethereum-hoodi.gateway.tatum.io", batch: { batchSize: 10 } },
  { url: "https://rpc.hoodi.ethpandaops.io", batch: { batchSize: 10 } },
];

/**
 * @dev Builds the same fallback RPC transport profile used by the frontend.
 * @param chainId The active chain id.
 * @param customRpcUrls Explicit RPC URLs for non-mainnet or override mode.
 * @returns A viem transport suitable for `createPublicClient`.
 */
export function createRfqTransport(chainId: number, customRpcUrls: readonly string[] = []) {
  if (chainId === mainnet.id && customRpcUrls.length === 0) {
    return fallback(
      mainnetFallbackRpcs.map(({ url, ...transportConfig }) => http(url, { ...httpConfig, ...transportConfig })),
      { retryCount: 6, retryDelay: 100 },
    );
  }

  if (chainId === 560048 && customRpcUrls.length === 0) {
    return fallback(
      hoodiFallbackRpcs.map(({ url, ...transportConfig }) => http(url, { ...httpConfig, ...transportConfig })),
      { retryCount: 6, retryDelay: 100 },
    );
  }

  return fallback(
    customRpcUrls.map((url) => http(url, { ...httpConfig, batch: { batchSize: 10 } })),
    { retryCount: 6, retryDelay: 100 },
  );
}
