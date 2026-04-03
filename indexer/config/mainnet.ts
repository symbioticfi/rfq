import { createRfqIndexerConfig } from "./base";

const mainnetConfig = {
  deploymentEnv: "mainnet",
  chainName: "mainnet",
  defaultChainId: 1,
  defaultRpcUrls: [],
  defaultPollingInterval: 100,
} as const;

export default createRfqIndexerConfig(mainnetConfig);
