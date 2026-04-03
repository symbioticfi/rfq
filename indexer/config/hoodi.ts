import { createRfqIndexerConfig } from "./base";

const hoodiConfig = {
  deploymentEnv: "hoodi",
  chainName: "hoodi",
  defaultChainId: 560048,
  defaultRpcUrls: [
    "https://0xrpc.io/hoodi",
    "https://ethereum-hoodi.gateway.tatum.io",
    "https://rpc.hoodi.ethpandaops.io",
  ],
  defaultPollingInterval: 100,
} as const;

export default createRfqIndexerConfig(hoodiConfig);
