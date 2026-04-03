import { config as loadEnv } from "dotenv";
import { createPublicClient, createWalletClient, getAddress, http } from "viem";
import { mainnet } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";
import { z } from "zod";

import { loadFillerDeploymentManifest } from "./deployment";
import { createFillerTransport } from "../lib/rpc";

loadEnv();

function normalizeAddress(value: string): `0x${string}` {
  return getAddress(value as `0x${string}`).toLowerCase() as `0x${string}`;
}

const envSchema = z.object({
  RFQ_FILLER_BACKEND_URL: z.string().url(),
  RFQ_FILLER_BACKEND_SHARED_SECRET: z.string().min(1),
  RFQ_FILLER_EXECUTOR_ADDRESS: z.string().regex(/^0x[a-fA-F0-9]{40}$/),
  RFQ_FILLER_CALLER_PRIVATE_KEY: z.string().regex(/^0x[a-fA-F0-9]{64}$/),
  RFQ_FILLER_DISCOUNT_PERCENT: z.coerce.number().min(0).max(100).default(10),
  RFQ_FILLER_RPC_URL: z.string().url().optional(),
  RFQ_FILLER_HOST: z.string().default("0.0.0.0"),
  RFQ_FILLER_PORT: z.coerce.number().int().positive().default(42073),
  RFQ_FILLER_LOG_LEVEL: z.enum(["fatal", "error", "warn", "info", "debug", "trace", "silent"]).default("info"),
  RFQ_FILLER_POLL_INTERVAL_MS: z.coerce.number().int().positive().default(3_000),
  RFQ_FILLER_ORDER_LIMIT: z.coerce.number().int().positive().max(100).default(20),
});

export type FillerEnv = ReturnType<typeof getFillerEnv>;

/**
 * @dev Parses and memoizes the filler environment.
 * @returns Normalized filler configuration.
 */
export function getFillerEnv() {
  const env = envSchema.parse(process.env);
  const runtimePort = Number(process.env.PORT || env.RFQ_FILLER_PORT);
  const callerAccount = privateKeyToAccount(env.RFQ_FILLER_CALLER_PRIVATE_KEY as `0x${string}`);
  const deployment = loadFillerDeploymentManifest();
  const quoteDiscountBps = Math.round(env.RFQ_FILLER_DISCOUNT_PERCENT * 100);

  return {
    deploymentEnv: deployment.environment,
    deployment,
    chainId: deployment.chain.id,
    backendUrl: env.RFQ_FILLER_BACKEND_URL,
    backendSharedSecret: env.RFQ_FILLER_BACKEND_SHARED_SECRET,
    executorAddress: normalizeAddress(env.RFQ_FILLER_EXECUTOR_ADDRESS as `0x${string}`),
    callerAccount,
    curatorRegistryAddress: deployment.contracts.curatorRegistry,
    instantRedemptionAdapterAddress: normalizeAddress(deployment.contracts.instantRedemptionAdapter!),
    quoteDiscountPercent: env.RFQ_FILLER_DISCOUNT_PERCENT,
    quoteDiscountBps,
    rpcUrl: env.RFQ_FILLER_RPC_URL,
    host: env.RFQ_FILLER_HOST,
    port: runtimePort,
    logLevel: env.RFQ_FILLER_LOG_LEVEL,
    pollIntervalMs: env.RFQ_FILLER_POLL_INTERVAL_MS,
    orderLimit: env.RFQ_FILLER_ORDER_LIMIT,
  };
}

function createChain(chainId: number) {
  return chainId === mainnet.id ? mainnet : { ...mainnet, id: chainId };
}

/**
 * @dev Creates the filler public client.
 * @param env The parsed filler environment.
 * @returns A viem public client.
 */
export function createFillerPublicClient(env: FillerEnv) {
  return createPublicClient({
    chain: createChain(env.chainId),
    transport: createFillerTransport(env.chainId, env.rpcUrl),
  });
}

/**
 * @dev Creates the filler wallet client.
 * @param env The parsed filler environment.
 * @returns A viem wallet client.
 */
export function createFillerWalletClient(env: FillerEnv) {
  return createWalletClient({
    account: env.callerAccount,
    chain: createChain(env.chainId),
    transport: env.rpcUrl ? http(env.rpcUrl) : createFillerTransport(env.chainId, env.rpcUrl),
  });
}
