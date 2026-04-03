import { config as loadEnv } from "dotenv";
import { createPublicClient, createWalletClient, getAddress, http } from "viem";
import { mainnet } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";
import { z } from "zod";

import { loadProtocolDeploymentManifest } from "./deployment";
import { createRfqTransport } from "../lib/rpc";

loadEnv();

const DEFAULT_LOCAL_FUNDER_PRIVATE_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

function normalizeAddress(value: string): `0x${string}` {
  return getAddress(value as `0x${string}`).toLowerCase() as `0x${string}`;
}

const envSchema = z.object({
  RFQ_PROTOCOL_SIGNER_PRIVATE_KEY: z.string().regex(/^0x[a-fA-F0-9]{64}$/),
  RFQ_SOLVER_SHARED_SECRET: z.string().min(1).optional(),
  RFQ_LOCAL_FUNDER_PRIVATE_KEY: z
    .string()
    .regex(/^0x[a-fA-F0-9]{64}$/)
    .optional(),
  RFQ_DATABASE_URL: z.string().min(1),
  RFQ_RPC_URLS: z
    .string()
    .optional()
    .transform((value) =>
      value
        ? value
            .split(",")
            .map((entry) => entry.trim())
            .filter(Boolean)
        : [],
    ),
  RFQ_HOST: z.string().default("0.0.0.0"),
  RFQ_PORT: z.coerce.number().int().positive().default(42072),
  RFQ_BACKEND_LOG_LEVEL: z.enum(["fatal", "error", "warn", "info", "debug", "trace", "silent"]).default("info"),
  RFQ_PERMIT_DEADLINE_SECONDS: z.coerce.number().int().positive().default(120),
  RFQ_SOLVER_TIMEOUT_MS: z.coerce.number().int().positive().default(1000),
});

export type BackendEnv = ReturnType<typeof getBackendEnv>;

/**
 * @dev Parses and memoizes the backend environment.
 * @returns Normalized backend environment values.
 */
export function getBackendEnv() {
  const env = envSchema.parse(process.env);
  const runtimePort = Number(process.env.PORT || env.RFQ_PORT);
  const deployment = loadProtocolDeploymentManifest();
  const protocolSigner = privateKeyToAccount(env.RFQ_PROTOCOL_SIGNER_PRIVATE_KEY as `0x${string}`);
  const localFunder =
    deployment.environment === "local"
      ? privateKeyToAccount((env.RFQ_LOCAL_FUNDER_PRIVATE_KEY || DEFAULT_LOCAL_FUNDER_PRIVATE_KEY) as `0x${string}`)
      : protocolSigner;

  return {
    deploymentEnv: deployment.environment,
    chainId: deployment.chain.id,
    reactorAddress: normalizeAddress(deployment.contracts.reactor!),
    instantRedemptionAdapterAddress: normalizeAddress(deployment.contracts.instantRedemptionAdapter!),
    curatorRegistryAddress: normalizeAddress(deployment.contracts.curatorRegistry!),
    permit2Address: normalizeAddress(deployment.contracts.permit2!),
    protocolSigner,
    protocolSignerAddress: normalizeAddress(protocolSigner.address),
    localFunder,
    databaseUrl: env.RFQ_DATABASE_URL,
    vaults: deployment.vaults.map((vault) => vault.address),
    deployment,
    rpcUrls: env.RFQ_RPC_URLS,
    solverSharedSecret: env.RFQ_SOLVER_SHARED_SECRET,
    host: env.RFQ_HOST,
    port: runtimePort,
    logLevel: env.RFQ_BACKEND_LOG_LEVEL,
    permitDeadlineSeconds: env.RFQ_PERMIT_DEADLINE_SECONDS,
    solverTimeoutMs: env.RFQ_SOLVER_TIMEOUT_MS,
  };
}

/**
 * @dev Creates the backend public client with the agreed fallback transport profile.
 * @param env Normalized backend environment.
 * @returns A viem public client.
 */
export function createBackendPublicClient(env: BackendEnv) {
  return createPublicClient({
    chain: env.chainId === mainnet.id ? mainnet : { ...mainnet, id: env.chainId },
    transport: createRfqTransport(env.chainId, env.rpcUrls),
  });
}

/**
 * @dev Creates the backend wallet client used for local-only funding and protocol-side writes.
 * @param env Normalized backend environment.
 * @returns A viem wallet client bound to the protocol signer.
 */
export function createBackendWalletClient(env: BackendEnv) {
  return createWalletClient({
    account: env.localFunder,
    chain: env.chainId === mainnet.id ? mainnet : { ...mainnet, id: env.chainId },
    transport: env.rpcUrls[0] ? http(env.rpcUrls[0]) : createRfqTransport(env.chainId, env.rpcUrls),
  });
}
