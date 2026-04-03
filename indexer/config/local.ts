import { createRfqIndexerConfig } from "./base";

const localConfig = {
  deploymentEnv: "local",
  chainName: "local",
  defaultChainId: 31337,
  defaultRpcUrls: ["http://127.0.0.1:8545"],
  defaultPollingInterval: 100,
} as const;

export default createRfqIndexerConfig(localConfig);
