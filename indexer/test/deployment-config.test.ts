import { afterEach, describe, expect, it, vi } from "vitest";
import { getAddress } from "viem";

import { createRfqIndexerConfig } from "../config/base";
import generatedDeployment from "../src/generated/deployment";

const originalEnv = { ...process.env };

describe("indexer deployment config", () => {
  afterEach(() => {
    process.env = { ...originalEnv };
  });

  it("loads deployment data from the generated module", () => {
    process.env = {
      ...originalEnv,
      RFQ_DATABASE_URL: "postgres://postgres:postgres@127.0.0.1:55432/rfq_protocol",
    };

    const config = createRfqIndexerConfig({
      deploymentEnv: generatedDeployment.environment,
      chainName: generatedDeployment.environment === "local" ? "local" : generatedDeployment.environment,
      defaultChainId: generatedDeployment.chain.id,
      defaultRpcUrls: [],
      defaultPollingInterval: 100,
    });

    expect(config.contracts.Reactor.address).toBe(getAddress(generatedDeployment.contracts.reactor));
    expect(config.contracts.InstantRedemptionAdapter.address).toBe(
      getAddress(generatedDeployment.contracts.instantRedemptionAdapter),
    );
    expect(config.contracts.VaultFactory.address).toBe(getAddress(generatedDeployment.contracts.vaultFactory));
  });

  it("builds ponder config from the generated deployment without relying on RFQ_DEPLOYMENT_ENV", async () => {
    process.env = {
      ...originalEnv,
      RFQ_DATABASE_URL: "postgres://postgres:postgres@127.0.0.1:55432/rfq_protocol",
      RFQ_DEPLOYMENT_ENV: "staging",
    };

    vi.resetModules();

    await expect(import("../ponder.config")).resolves.toMatchObject({
      default: expect.objectContaining({
        contracts: expect.objectContaining({
          Reactor: expect.objectContaining({
            address: getAddress(generatedDeployment.contracts.reactor),
          }),
        }),
      }),
    });
  });
});
