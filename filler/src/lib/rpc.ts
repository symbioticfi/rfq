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
 * @dev Builds the shared RFQ fallback transport profile.
 * @param chainId The target chain id.
 * @param rpcUrl Optional single RPC override.
 * @returns A viem transport for public and wallet clients.
 */
export function createFillerTransport(chainId: number, rpcUrl?: string) {
  if (chainId === mainnet.id && !rpcUrl) {
    return fallback(
      mainnetFallbackRpcs.map(({ url, ...transportConfig }) => http(url, { ...httpConfig, ...transportConfig })),
      { retryCount: 6, retryDelay: 100 },
    );
  }

  if (chainId === 560048 && !rpcUrl) {
    return fallback(
      hoodiFallbackRpcs.map(({ url, ...transportConfig }) => http(url, { ...httpConfig, ...transportConfig })),
      { retryCount: 6, retryDelay: 100 },
    );
  }

  if (!rpcUrl) {
    throw new Error("RFQ_FILLER_RPC_URL is required for non-mainnet chains");
  }

  return fallback([http(rpcUrl, { ...httpConfig, batch: { batchSize: 10 } })], { retryCount: 6, retryDelay: 100 });
}
