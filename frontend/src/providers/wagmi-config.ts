import { createConfig as createPrivyWagmiConfig } from "@privy-io/wagmi";
import { createConfig as createCoreWagmiConfig, fallback, http, unstable_connector } from "wagmi";
import { hoodi, mainnet } from "wagmi/chains";
import { injected } from "wagmi/connectors";

import { appChain, appChainHasCustomRpc } from "./chain-config";

const httpConfig = {
  retryDelay: 0,
  timeout: 5_000,
} as const;

type FallbackRpc = {
  readonly url: string;
  readonly batch?: false | { readonly batchSize: number };
};

const mainnetFallbackRpcs: readonly FallbackRpc[] = [
  { url: "https://rpc.mevblocker.io", batch: { batchSize: 10 } },
  { url: "https://rpc.ankr.com/eth", batch: { batchSize: 10 } },
  { url: "https://eth-pokt.nodies.app", batch: false },
  { url: "https://eth.drpc.org", batch: false },
  { url: "https://eth.merkle.io", batch: false },
];

const hoodiFallbackRpcs: readonly FallbackRpc[] = [
  { url: "https://0xrpc.io/hoodi", batch: { batchSize: 10 } },
  { url: "https://ethereum-hoodi.gateway.tatum.io", batch: { batchSize: 10 } },
  { url: "https://rpc.hoodi.ethpandaops.io", batch: { batchSize: 10 } },
];

function createFallbackTransport(rpcs: readonly FallbackRpc[]) {
  return fallback(
    [
      ...rpcs.map(({ url, ...transportConfig }) => http(url, { ...httpConfig, ...transportConfig })),
      unstable_connector(
        {
          type: "injected",
        },
        {
          key: "injected",
          name: "Injected",
          retryCount: 0,
        },
      ),
    ],
    { retryCount: 6, retryDelay: 100 },
  );
}

const transport = (() => {
  if (appChain.id === mainnet.id && !appChainHasCustomRpc) {
    return createFallbackTransport(mainnetFallbackRpcs);
  }

  if (appChain.id === hoodi.id) {
    return createFallbackTransport(hoodiFallbackRpcs);
  }

  return fallback(
    appChain.rpcUrls.default.http.map((url) => http(url, { ...httpConfig, batch: { batchSize: 10 } })),
    { retryCount: 6, retryDelay: 100 },
  );
})();

const transports = {
  [appChain.id]: transport,
};

const commonConfig = {
  chains: [appChain] as const,
  transports,
  batch: {
    multicall: {
      batchSize: 16383,
      wait: 100,
    },
  },
  cacheTime: 250,
  pollingInterval: 4000,
};

export const privyWagmiConfig = createPrivyWagmiConfig({
  ...commonConfig,
});

export const readonlyWagmiConfig = createCoreWagmiConfig({
  ...commonConfig,
  connectors: [
    injected({
      shimDisconnect: true,
      target: "metaMask",
    }),
    injected({
      shimDisconnect: true,
    }),
  ],
  multiInjectedProviderDiscovery: false,
});
