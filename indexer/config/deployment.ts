import { getAddress } from "viem";
import { z } from "zod";

import generatedDeployment from "../src/generated/deployment";

const addressSchema = z.string().regex(/^0x[a-fA-F0-9]{40}$/).transform((value) => getAddress(value));

const deploymentManifestSchema = z.object({
  version: z.literal(1),
  environment: z.enum(["local", "hoodi", "mainnet"]),
  deployed: z.boolean(),
  chain: z.object({
    id: z.number().int().positive(),
    name: z.string().min(1),
    rpcUrl: z.string(),
    testnet: z.boolean(),
    startBlock: z.number().int().nonnegative(),
    explorerUrl: z.string(),
  }),
  contracts: z.object({
    permit2: addressSchema,
    instantRedemptionAdapter: addressSchema,
    reactor: addressSchema,
    executor: addressSchema,
    mockSwapRouter: addressSchema,
    vaultFactory: addressSchema,
  }),
});

/**
 * @dev Loads the deployment manifest used by the protocol indexer.
 * @returns Parsed deployment manifest.
 */
export function loadIndexerDeploymentManifest() {
  const parsed = deploymentManifestSchema.parse(generatedDeployment);

  if (!parsed.deployed) {
    throw new Error("Generated deployment manifest is not marked as deployed");
  }

  return parsed;
}
