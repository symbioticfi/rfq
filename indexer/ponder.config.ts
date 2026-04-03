import "dotenv/config";

import generatedDeployment from "./src/generated/deployment";

const deploymentEnv = generatedDeployment.environment;

const configModuleLoaders = {
  local: () => import("./config/local"),
  hoodi: () => import("./config/hoodi"),
  mainnet: () => import("./config/mainnet"),
} as const;

export default (await configModuleLoaders[deploymentEnv]()).default;
