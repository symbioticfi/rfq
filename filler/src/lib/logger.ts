import { randomUUID } from "node:crypto";

import type { MiddlewareHandler } from "hono";
import pino, { type LevelWithSilent, type Logger } from "pino";

export type FillerAppVariables = {
  readonly logger: Logger;
  readonly requestId: string;
};

export function createFillerLogger(service: string, level: LevelWithSilent = "info") {
  return pino({
    name: service,
    level,
    timestamp: pino.stdTimeFunctions.isoTime,
    serializers: {
      err: pino.stdSerializers.err,
    },
  });
}

export function createSilentFillerLogger(service: string) {
  return createFillerLogger(service, "silent");
}

export function createFillerRequestLogger(rootLogger: Logger): MiddlewareHandler<{ Variables: FillerAppVariables }> {
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
