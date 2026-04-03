import { randomUUID } from "node:crypto";

import type { MiddlewareHandler } from "hono";
import pino, { type LevelWithSilent, type Logger } from "pino";

export type IndexerAppVariables = {
  readonly logger: Logger;
  readonly requestId: string;
};

const LOG_LEVELS = new Set<LevelWithSilent>(["fatal", "error", "warn", "info", "debug", "trace", "silent"]);

function resolveLogLevel(value: string | undefined): LevelWithSilent {
  return value && LOG_LEVELS.has(value as LevelWithSilent) ? (value as LevelWithSilent) : "info";
}

export function createIndexerLogger(service: string, level: LevelWithSilent = resolveLogLevel(process.env.RFQ_INDEXER_LOG_LEVEL)) {
  return pino({
    name: service,
    level,
    timestamp: pino.stdTimeFunctions.isoTime,
    serializers: {
      err: pino.stdSerializers.err,
    },
  });
}

export const indexerLogger = createIndexerLogger("rfq-indexer");

export function createIndexerRequestLogger(rootLogger: Logger): MiddlewareHandler<{ Variables: IndexerAppVariables }> {
  return async (context, next) => {
    const startedAt = Date.now();
    const requestId = randomUUID();
    const url = new URL(context.req.url);
    const logger = rootLogger.child({
      requestId,
      method: context.req.method,
      path: url.pathname,
    });

    context.set("requestId", requestId);
    context.set("logger", logger);
    context.header("x-request-id", requestId);

    await next();

    logger.info(
      {
        status: context.res.status,
        durationMs: Date.now() - startedAt,
      },
      "request completed",
    );
  };
}
