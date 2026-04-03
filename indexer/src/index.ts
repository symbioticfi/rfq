import { ponder } from "ponder:registry";

import generatedDeployment from "./generated/deployment";
import { indexerLogger } from "./lib/logger";
import { registerInstantRedemptionAdapterEvents, registerReactorEvents, registerVaultFactoryEvents } from "./indexer";

indexerLogger.info(
  { deploymentEnv: generatedDeployment.environment },
  "Registering RFQ indexer handlers",
);

registerReactorEvents(ponder);
registerInstantRedemptionAdapterEvents(ponder);
registerVaultFactoryEvents(ponder);
