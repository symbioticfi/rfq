import { afterEach, describe, expect, it } from "vitest";

import generatedDeployment from "../src/generated/deployment";
import { getFillerEnv } from "../src/config/env";
import { loadFillerDeploymentManifest } from "../src/config/deployment";

const originalEnv = { ...process.env };

describe("filler deployment config", () => {
  afterEach(() => {
    process.env = { ...originalEnv };
  });

  it("loads deployment data from the generated module", () => {
    process.env = {
      ...originalEnv,
      RFQ_FILLER_BACKEND_URL: "http://127.0.0.1:42072",
      RFQ_FILLER_BACKEND_SHARED_SECRET: "local-rfq-shared-secret",
      RFQ_FILLER_EXECUTOR_ADDRESS: "0x82e01223d51Eb87e16A03E24687EDF0F294da6f1",
      RFQ_FILLER_CALLER_PRIVATE_KEY: "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
    };

    const env = getFillerEnv();

    expect(env.deployment).toEqual(loadFillerDeploymentManifest());
    expect(env.deploymentEnv).toBe(generatedDeployment.environment);
    expect(env.deployment.contracts.instantRedemptionAdapter).toBe(generatedDeployment.contracts.instantRedemptionAdapter);
    expect(env.deployment.contracts.curatorRegistry).toBe(generatedDeployment.contracts.curatorRegistry);
    expect(env.deployment.contracts.reactor).toBe(generatedDeployment.contracts.reactor);
  });
});
