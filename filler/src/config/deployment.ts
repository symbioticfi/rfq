import { getAddress } from "viem";
import { z } from "zod";

import generatedDeployment from "../generated/deployment";

function normalizeAddress(value: string | null): `0x${string}` | null {
  if (!value) {
    return null;
  }

  return getAddress(value as `0x${string}`).toLowerCase() as `0x${string}`;
}

const addressSchema = z
  .string()
  .regex(/^0x[a-fA-F0-9]{40}$/)
  .transform((value) => normalizeAddress(value)!);
const nullableAddressSchema = z
  .union([z.null(), z.string().regex(/^0x[a-fA-F0-9]{40}$/)])
  .transform((value) => normalizeAddress(value));

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
    permit2: nullableAddressSchema,
    curatorRegistry: nullableAddressSchema,
    instantRedemptionAdapter: nullableAddressSchema,
    reactor: nullableAddressSchema,
    executor: nullableAddressSchema,
    mockSwapRouter: nullableAddressSchema,
  }),
  participants: z.object({
    protocolSigner: nullableAddressSchema,
    executorCaller: nullableAddressSchema,
    marketMaker: nullableAddressSchema,
  }),
  tokens: z.object({
    input: z.array(
      z.object({
        address: addressSchema,
        symbol: z.string().min(1),
        name: z.string().min(1),
        decimals: z.number().int().min(0).max(255),
      }),
    ),
    output: z.array(
      z.object({
        address: addressSchema,
        symbol: z.string().min(1),
        name: z.string().min(1),
        decimals: z.number().int().min(0).max(255),
      }),
    ),
    defaultInput: nullableAddressSchema,
    defaultOutput: nullableAddressSchema,
  }),
  vaults: z.array(
    z.object({
      address: addressSchema,
      collateral: addressSchema,
      name: z.string().min(1),
    }),
  ),
});

export type FillerDeploymentManifest = z.infer<typeof deploymentManifestSchema>;

/**
 * @dev Loads and validates the filler deployment manifest.
 * @returns Parsed deployment manifest.
 */
export function loadFillerDeploymentManifest(): FillerDeploymentManifest {
  const parsed = deploymentManifestSchema.parse(generatedDeployment);

  if (!parsed.deployed) {
    throw new Error("Generated deployment manifest is not marked as deployed");
  }
  if (!parsed.contracts.instantRedemptionAdapter) {
    throw new Error("Generated deployment manifest is missing required filler addresses");
  }

  return parsed;
}
