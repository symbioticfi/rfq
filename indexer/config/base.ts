import { createConfig } from "ponder";

import { InstantRedemptionAdapterAbi } from "../abis/InstantRedemptionAdapterAbi";
import { ReactorAbi } from "../abis/ReactorAbi";
import { VaultFactoryAbi } from "../abis/VaultFactoryAbi";
import { createIndexerTransport } from "../src/lib/rpc";
import { loadIndexerDeploymentManifest } from "./deployment";

export type RfqDeploymentEnv = "local" | "hoodi" | "mainnet";

export type RfqChainConfig = {
  readonly deploymentEnv: RfqDeploymentEnv;
  readonly chainName: string;
  readonly defaultChainId: number;
  readonly defaultRpcUrls: readonly string[];
  readonly defaultPollingInterval: number;
};

function unique(values: readonly string[]) {
  return Array.from(new Set(values.map((value) => value.trim()).filter(Boolean)));
}

function parseNumber(value: string | undefined, fallback: number) {
  if (!value) {
    return fallback;
  }

  const trimmed = value.trim();
  if (!trimmed) {
    return fallback;
  }

  const parsed = Number(trimmed);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function resolveRpcUrls(config: RfqChainConfig, chainId: number, manifestRpcUrl: string) {
  const rpcUrls = unique([
    ...(process.env.RFQ_RPC_URLS ?? "")
      .split(",")
      .map((value) => value.trim())
      .filter(Boolean),
    process.env[`PONDER_RPC_URL_${chainId}`] ?? "",
    process.env.PONDER_RPC_URL ?? "",
    process.env.NODE_RPC ?? "",
    process.env[`${config.chainName.toUpperCase()}_RPC`] ?? "",
    manifestRpcUrl,
    ...config.defaultRpcUrls,
  ]);

  if (rpcUrls.length === 0 && config.deploymentEnv !== "mainnet") {
    throw new Error(`No RPC URLs configured for ${config.deploymentEnv}.`);
  }

  return rpcUrls;
}

function resolvePollingInterval(config: RfqChainConfig) {
  return parseNumber(
    process.env.RFQ_PONDER_POLLING_INTERVAL ??
      process.env.PONDER_POLLING_INTERVAL ??
      process.env[`${config.chainName.toUpperCase()}_POLLING_INTERVAL`] ??
      process.env.NODE_PRC_POLLING_INTERVAL ??
      process.env.NODE_RPC_POLLING_INTERVAL,
    config.defaultPollingInterval,
  );
}

export function createRfqIndexerConfig(config: RfqChainConfig) {
  const deployment = loadIndexerDeploymentManifest();
  const chainId = deployment.chain.id || config.defaultChainId;
  const startBlock = parseNumber(
    process.env.RFQ_INDEXER_START_BLOCK,
    deployment.chain.startBlock || 0,
  );
  const databaseUrl = process.env.RFQ_DATABASE_URL;
  const pgliteDirectory = process.env.RFQ_INDEXER_PGLITE_DIR;
  const pollingInterval = resolvePollingInterval(config);
  const rpcUrls = resolveRpcUrls(config, chainId, deployment.chain.rpcUrl);

  if (!databaseUrl && !pgliteDirectory) {
    throw new Error("RFQ_DATABASE_URL is required");
  }

  return createConfig({
    database: pgliteDirectory
      ? {
          kind: "pglite",
          directory: pgliteDirectory,
        }
      : {
          kind: "postgres",
          connectionString: `${databaseUrl!}${databaseUrl!.includes("?") ? "&" : "?"}search_path=rfq_indexer`,
        },
    chains: {
      [config.chainName]: {
        id: chainId,
        rpc: createIndexerTransport(chainId, rpcUrls),
        pollingInterval,
      },
    },
    contracts: {
      Reactor: {
        chain: config.chainName,
        abi: ReactorAbi,
        address: deployment.contracts.reactor as `0x${string}`,
        startBlock,
      },
      InstantRedemptionAdapter: {
        chain: config.chainName,
        abi: InstantRedemptionAdapterAbi,
        address: deployment.contracts.instantRedemptionAdapter as `0x${string}`,
        startBlock,
      },
      VaultFactory: {
        chain: config.chainName,
        abi: VaultFactoryAbi,
        address: deployment.contracts.vaultFactory as `0x${string}`,
        startBlock,
      },
    },
  });
}
