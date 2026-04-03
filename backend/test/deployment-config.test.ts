import { afterEach, describe, expect, it } from "vitest";

import generatedDeployment from "../src/generated/deployment";
import { getBackendEnv } from "../src/config/env";
import { loadProtocolDeploymentManifest } from "../src/config/deployment";

const originalEnv = { ...process.env };

describe("backend deployment config", () => {
  afterEach(() => {
    process.env = { ...originalEnv };
  });

  it("loads deployment data from the generated module", () => {
    process.env = {
      ...originalEnv,
      RFQ_PROTOCOL_SIGNER_PRIVATE_KEY: "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
      RFQ_DATABASE_URL: "postgres://postgres:postgres@127.0.0.1:55432/rfq_protocol",
    };

    const env = getBackendEnv();

    expect(env.deployment).toEqual(loadProtocolDeploymentManifest());
    expect(env.deploymentEnv).toBe(generatedDeployment.environment);
    expect(env.deployment.contracts.reactor).toBe(generatedDeployment.contracts.reactor);
    expect(env.deployment.contracts.instantRedemptionAdapter).toBe(generatedDeployment.contracts.instantRedemptionAdapter);
    expect(env.deployment.contracts.curatorRegistry).toBe(generatedDeployment.contracts.curatorRegistry);
    expect(env.deployment.contracts.permit2).toBe(generatedDeployment.contracts.permit2);
  });
});
