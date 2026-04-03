import { serve } from "@hono/node-server";

import { createApp } from "./app";
import { createBackendPublicClient, createBackendWalletClient, getBackendEnv } from "./config/env";
import { createBackendDb } from "./db/client";
import { createBackendRepositories } from "./db/repositories";
import { createBackendLogger } from "./lib/logger";
import { createMetrics } from "./metrics";
import { RfqService } from "./services/rfq-service";

const env = getBackendEnv();
const logger = createBackendLogger("rfq-backend", env.logLevel);
const publicClient = createBackendPublicClient(env);
const walletClient = createBackendWalletClient(env);
const { pool, db } = createBackendDb(env.databaseUrl);
const metrics = createMetrics();
const repositories = createBackendRepositories(db);
const service = new RfqService({
  env,
  publicClient,
  walletClient,
  repositories,
  metrics,
  fetchImpl: fetch,
  now: () => new Date(),
});
const app = createApp({ service, metrics, logger: logger.child({ component: "http" }) });

serve(
  {
    fetch: app.fetch,
    hostname: env.host,
    port: env.port,
  },
  (info) => {
    logger.info(
      {
        address: info.address,
        port: info.port,
        chainId: env.chainId,
        deploymentEnv: env.deploymentEnv,
      },
      "RFQ backend listening",
    );
  },
);

process.on("SIGINT", async () => {
  logger.info("Shutting down on SIGINT");
  await pool.end();
  process.exit(0);
});

process.on("SIGTERM", async () => {
  logger.info("Shutting down on SIGTERM");
  await pool.end();
  process.exit(0);
});

process.on("unhandledRejection", (error) => {
  logger.error({ err: error }, "Unhandled promise rejection");
});

process.on("uncaughtException", (error) => {
  logger.fatal({ err: error }, "Uncaught exception");
});
