import { Scalar } from "@scalar/hono-api-reference";
import { Hono } from "hono";
import { HTTPException } from "hono/http-exception";
import { describeRoute, openAPIRouteHandler, resolver, validator } from "hono-openapi";
import type { Logger } from "pino";

import { createFillerRequestLogger, createSilentFillerLogger, type FillerAppVariables } from "./lib/logger";
import {
  errorResponseSchema,
  healthResponseSchema,
  notifyAcceptedResponseSchema,
  notifySchema,
  solverQuoteRequestSchema,
  solverQuoteResponseSchema,
} from "./schemas/api";
import { ExecutionService } from "./services/execution-service";
import { QuoteService } from "./services/quote-service";

type CreateAppInput = {
  readonly quoteService: QuoteService;
  readonly executionService: ExecutionService;
  readonly backendSharedSecret: string;
  readonly logger?: Logger;
};

/**
 * @dev Creates the filler Hono application.
 * @param input The quote and execution services.
 * @returns A configured filler app.
 */
export function createApp(input: CreateAppInput) {
  const rootLogger = input.logger ?? createSilentFillerLogger("rfq-filler.http");
  const app = new Hono<{ Variables: FillerAppVariables }>();
  const backendOnly = async (context: Parameters<Parameters<Hono["use"]>[1]>[0], next: () => Promise<void>) => {
    if (context.req.header("x-rfq-shared-secret") !== input.backendSharedSecret) {
      throw new HTTPException(403, { message: "Forbidden" });
    }

    await next();
  };

  app.use("*", createFillerRequestLogger(rootLogger));

  app.onError((error, context) => {
    const message = error instanceof Error ? error.message : "Internal error";
    const httpError = error instanceof HTTPException ? error : new HTTPException(500, { message });
    context.get("logger").error(
      {
        err: error,
        status: httpError.status,
      },
      "request failed",
    );
    return context.json({ error: httpError.message }, httpError.status);
  });

  app.use("/quote", backendOnly);
  app.use("/notify", backendOnly);

  app.get(
    "/health",
    describeRoute({
      tags: ["System"],
      summary: "Health check",
      responses: {
        200: {
          description: "Service is healthy",
          content: {
            "application/json": {
              schema: resolver(healthResponseSchema),
            },
          },
        },
      },
    }),
    (context) =>
      context.json({
        status: "ok",
        timestamp: new Date().toISOString(),
      }),
  );

  app.get(
    "/openapi.json",
    openAPIRouteHandler(app, {
      documentation: {
        openapi: "3.1.0",
        info: {
          title: "Symbiotic RFQ Filler API",
          version: "1.0.0",
          description: "Externally owned filler API for solver quoting and order notifications.",
        },
      },
      exclude: [/^\/docs$/],
    }),
  );

  app.get(
    "/docs",
    Scalar({
      url: "/openapi.json",
      pageTitle: "Symbiotic RFQ Filler API",
      theme: "kepler",
    }),
  );

  app.post(
    "/quote",
    describeRoute({
      tags: ["Filler"],
      summary: "Request a filler quote",
      description: "Returns a solver quote or 204 when the filler cannot quote the request.",
      responses: {
        200: {
          description: "Quote available",
          content: {
            "application/json": {
              schema: resolver(solverQuoteResponseSchema),
            },
          },
        },
        204: {
          description: "No quote available",
        },
        400: {
          description: "Invalid request payload",
          content: {
            "application/json": {
              schema: resolver(errorResponseSchema),
            },
          },
        },
        403: {
          description: "Caller is not the configured backend",
          content: {
            "application/json": {
              schema: resolver(errorResponseSchema),
            },
          },
        },
      },
    }),
    validator("json", solverQuoteRequestSchema),
    async (context) => {
      const payload = context.req.valid("json");
      const response = await input.quoteService.quote(payload);
      if (!response) {
        return context.body(null, 204);
      }

      return context.json(response);
    },
  );

  app.post(
    "/notify",
    describeRoute({
      tags: ["Filler"],
      summary: "Notify the filler about a winning order",
      description: "Queues a backend winner notification for execution.",
      responses: {
        202: {
          description: "Notification accepted",
          content: {
            "application/json": {
              schema: resolver(notifyAcceptedResponseSchema),
            },
          },
        },
        400: {
          description: "Invalid request payload",
          content: {
            "application/json": {
              schema: resolver(errorResponseSchema),
            },
          },
        },
        403: {
          description: "Caller is not the configured backend",
          content: {
            "application/json": {
              schema: resolver(errorResponseSchema),
            },
          },
        },
      },
    }),
    validator("json", notifySchema),
    async (context) => {
      const payload = context.req.valid("json");
      await input.executionService.enqueueFromNotify(payload);
      return context.json({ status: "queued" }, 202);
    },
  );

  return app;
}
