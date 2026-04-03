import { serve } from "@hono/node-server";

import { createApp } from "./app";
import { createFillerPublicClient, createFillerWalletClient, getFillerEnv } from "./config/env";
import { createFillerRepositories } from "./db/repositories";
import { BackendClient } from "./lib/backend";
import { createFillerLogger } from "./lib/logger";
import { ExecutionService } from "./services/execution-service";
import { QuoteService } from "./services/quote-service";

async function main() {
  const env = getFillerEnv();
  const logger = createFillerLogger("rfq-filler", env.logLevel);
  const publicClient = createFillerPublicClient(env);
  const walletClient = createFillerWalletClient(env);
  const repositories = createFillerRepositories();
  const backendClient = new BackendClient({
    baseUrl: env.backendUrl,
    fetchImpl: fetch,
  });
  const quoteService = new QuoteService({
    env,
    publicClient,
    repositories,
    now: () => new Date(),
  });
  const executionService = new ExecutionService({
    env,
    publicClient,
    walletClient: {
      sendTransaction: async (input) =>
        walletClient.sendTransaction({
          account: env.callerAccount,
          to: input.to,
          data: input.data,
        }),
    },
    repositories,
    backendClient,
    now: () => new Date(),
    logger: logger.child({ component: "execution" }),
  });
  const app = createApp({
    quoteService,
    executionService,
    backendSharedSecret: env.backendSharedSecret,
    logger: logger.child({ component: "http" }),
  });

  executionService.start();

  const shutdown = async () => {
    logger.info("Stopping execution worker");
    executionService.stop();
    process.exit(0);
  };

  process.on("SIGINT", () => {
    void shutdown();
  });

  process.on("SIGTERM", () => {
    void shutdown();
  });

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
        "RFQ filler listening",
      );
    },
  );

  process.on("unhandledRejection", (error) => {
    logger.error({ err: error }, "Unhandled promise rejection");
  });

  process.on("uncaughtException", (error) => {
    logger.fatal({ err: error }, "Uncaught exception");
  });
}

void main();
