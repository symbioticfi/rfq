import { Scalar } from "@scalar/hono-api-reference";
import { Hono } from "hono";
import { cors } from "hono/cors";
import { HTTPException } from "hono/http-exception";
import { describeRoute, openAPIRouteHandler, resolver, validator } from "hono-openapi";
import type { Logger } from "pino";

import { createBackendRequestLogger, createSilentBackendLogger, type BackendAppVariables } from "./lib/logger";
import type { BackendMetrics } from "./metrics";
import {
  approvalCheckResponseSchema,
  approvalCheckSchema,
  createOrderResponseSchema,
  discountsQuerySchema,
  createOrderSchema,
  discountsResponseSchema,
  errorResponseSchema,
  healthResponseSchema,
  localFaucetFundResponseSchema,
  localFaucetResponseSchema,
  localFundResponseSchema,
  localFundSchema,
  ordersResponseSchema,
  ordersQuerySchema,
  publishDiscountResponseSchema,
  publishDiscountSchema,
  publicQuoteResponseSchema,
  quoteRequestSchema,
  resolveDiscountRouteResponseSchema,
  resolveDiscountSchema,
} from "./schemas/api";
import { RfqService } from "./services/rfq-service";

type CreateAppInput = {
  readonly service: RfqService;
  readonly metrics: BackendMetrics;
  readonly logger?: Logger;
};

function mapServiceError(error: unknown) {
  const message = error instanceof Error ? error.message : "Internal error";
  if (message.includes("Unknown quoteId")) {
    return new HTTPException(404, { message });
  }
  if (message.includes("Unknown discount")) {
    return new HTTPException(404, { message });
  }
  if (message.includes("expired") || message.includes("cannot be honored")) {
    return new HTTPException(409, { message });
  }
  if (message.includes("Invalid") || message.includes("Unsupported") || message.includes("mismatch")) {
    return new HTTPException(400, { message });
  }
  return new HTTPException(500, { message });
}

/**
 * @dev Creates the RFQ backend Hono application.
 * @param input The service and metrics dependencies.
 * @returns A configured Hono app.
 */
export function createApp(input: CreateAppInput) {
  const rootLogger = input.logger ?? createSilentBackendLogger("rfq-backend.http");
  const app = new Hono<{ Variables: BackendAppVariables }>();

  app.use("*", createBackendRequestLogger(rootLogger));

  app.use(
    "*",
    cors({
      origin: "*",
      allowMethods: ["GET", "POST", "OPTIONS"],
      allowHeaders: ["Content-Type", "Authorization"],
    }),
  );

  app.onError((error, context) => {
    const httpError = error instanceof HTTPException ? error : mapServiceError(error);
    context.get("logger").error(
      {
        err: error,
        status: httpError.status,
      },
      "request failed",
    );
    return context.json(
      {
        error: httpError.message,
      },
      httpError.status,
    );
  });

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
          title: "Symbiotic RFQ Backend API",
          version: "1.0.0",
          description:
            "Public RFQ backend API for approval checks, quote creation, order submission, and order polling.",
        },
      },
      exclude: [/^\/docs$/, /^\/metrics$/],
    }),
  );

  app.get(
    "/docs",
    Scalar({
      url: "/openapi.json",
      pageTitle: "Symbiotic RFQ Backend API",
      theme: "kepler",
    }),
  );

  app.get("/metrics", async (context) => {
    context.header("Content-Type", input.metrics.registry.contentType);
    return context.body(await input.metrics.registry.metrics());
  });

  app.post(
    "/check_approval",
    describeRoute({
      tags: ["RFQ"],
      summary: "Check Permit2 approval",
      description: "Returns an ERC-20 approval payload when Permit2 allowance is insufficient.",
      responses: {
        200: {
          description: "Approval state resolved",
          content: {
            "application/json": {
              schema: resolver(approvalCheckResponseSchema),
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
      },
    }),
    validator("json", approvalCheckSchema),
    async (context) => {
      const payload = context.req.valid("json");
      return context.json(await input.service.checkApproval(payload));
    },
  );

  app.post(
    "/dev/fund",
    describeRoute({
      tags: ["Development"],
      summary: "Fund a local wallet",
      description: "Local-only helper that tops a wallet up with ETH and the local input token.",
      responses: {
        200: {
          description: "Wallet funding result",
          content: {
            "application/json": {
              schema: resolver(localFundResponseSchema),
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
        500: {
          description: "Funding unavailable",
          content: {
            "application/json": {
              schema: resolver(errorResponseSchema),
            },
          },
        },
      },
    }),
    validator("json", localFundSchema),
    async (context) => {
      const payload = context.req.valid("json");
      return context.json(await input.service.fundLocalWallet(payload));
    },
  );

  app.get(
    "/dev/faucet",
    describeRoute({
      tags: ["Development"],
      summary: "Describe the faucet bundle",
      description: "Development/test helper that lists the fixed faucet bundle available on supported deployments.",
      responses: {
        200: {
          description: "Faucet bundle description",
          content: {
            "application/json": {
              schema: resolver(localFaucetResponseSchema),
            },
          },
        },
        500: {
          description: "Faucet unavailable",
          content: {
            "application/json": {
              schema: resolver(errorResponseSchema),
            },
          },
        },
      },
    }),
    async (context) => context.json(await input.service.describeLocalFaucet()),
  );

  app.post(
    "/dev/faucet",
    describeRoute({
      tags: ["Development"],
      summary: "Fund a wallet from the faucet",
      description: "Development/test helper that transfers the full faucet bundle to the requested wallet.",
      responses: {
        200: {
          description: "Wallet funded from faucet",
          content: {
            "application/json": {
              schema: resolver(localFaucetFundResponseSchema),
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
        500: {
          description: "Faucet unavailable",
          content: {
            "application/json": {
              schema: resolver(errorResponseSchema),
            },
          },
        },
      },
    }),
    validator("json", localFundSchema),
    async (context) => {
      const payload = context.req.valid("json");
      return context.json(await input.service.faucetLocalWallet(payload));
    },
  );

  app.post(
    "/quote",
    describeRoute({
      tags: ["RFQ"],
      summary: "Request a quote",
      description: "Returns an indicative quote or 404 when no solver can quote.",
      responses: {
        200: {
          description: "Quote available",
          content: {
            "application/json": {
              schema: resolver(publicQuoteResponseSchema),
            },
          },
        },
        404: {
          description: "No quote available",
          content: {
            "application/json": {
              schema: resolver(errorResponseSchema),
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
      },
    }),
    validator("json", quoteRequestSchema),
    async (context) => {
      const payload = context.req.valid("json");
      const response = await input.service.quote(payload);
      if (!response) {
        return context.json({ error: "No quotes available" }, 404);
      }

      return context.json(response);
    },
  );

  app.get(
    "/discounts",
    describeRoute({
      tags: ["RFQ"],
      summary: "List live discounts",
      description: "Returns currently live discount-backed inventory for vault/token pairs.",
      responses: {
        200: {
          description: "Live discounts response",
          content: {
            "application/json": {
              schema: resolver(discountsResponseSchema),
            },
          },
        },
      },
    }),
    validator("query", discountsQuerySchema),
    async (context) => {
      const query = context.req.valid("query");
      const filters = query.discountId
        ? { discountId: query.discountId }
        : query.discountIds
          ? { discountIds: query.discountIds }
          : query.vault && query.tokenToRedeem
            ? { vault: query.vault, tokenToRedeem: query.tokenToRedeem }
            : query.vaults && query.tokensToRedeem
              ? { vaults: query.vaults, tokensToRedeem: query.tokensToRedeem }
              : undefined;
      return context.json(await input.service.listDiscounts(filters));
    },
  );

  app.post(
    "/discount",
    describeRoute({
      tags: ["RFQ"],
      summary: "Publish a live discount",
      description: "Validates a reusable discount signature and stores it as the live row for a vault/token pair.",
      responses: {
        200: {
          description: "Discount published",
          content: {
            "application/json": {
              schema: resolver(publishDiscountResponseSchema),
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
      },
    }),
    validator("json", publishDiscountSchema),
    async (context) => {
      const payload = context.req.valid("json");
      return context.json(await input.service.publishDiscount(payload));
    },
  );

  app.post(
    "/discounts",
    describeRoute({
      tags: ["RFQ"],
      summary: "Resolve a live discount",
      description: "Returns the stored discount plus a fresh short-lived protocol signature.",
      responses: {
        200: {
          description: "Resolved discount package",
          content: {
            "application/json": {
              schema: resolver(resolveDiscountRouteResponseSchema),
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
        404: {
          description: "Unknown discount",
          content: {
            "application/json": {
              schema: resolver(errorResponseSchema),
            },
          },
        },
      },
    }),
    validator("json", resolveDiscountSchema),
    async (context) => {
      const payload = context.req.valid("json");
      const request = payload.discountId
        ? { discountId: payload.discountId }
        : payload.discountIds
          ? { discountIds: payload.discountIds }
          : payload.vault && payload.tokenToRedeem
            ? {
                vault: payload.vault,
                tokenToRedeem: payload.tokenToRedeem,
              }
            : {
                vaults: payload.vaults!,
                tokensToRedeem: payload.tokensToRedeem!,
              };
      return context.json(await input.service.resolveDiscount(request));
    },
  );

  app.post(
    "/order",
    describeRoute({
      tags: ["RFQ"],
      summary: "Create an order",
      description: "Submits a signed quote and creates an RFQ order.",
      responses: {
        200: {
          description: "Order created",
          content: {
            "application/json": {
              schema: resolver(createOrderResponseSchema),
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
        404: {
          description: "Unknown quote",
          content: {
            "application/json": {
              schema: resolver(errorResponseSchema),
            },
          },
        },
        409: {
          description: "Quote expired or no longer valid",
          content: {
            "application/json": {
              schema: resolver(errorResponseSchema),
            },
          },
        },
      },
    }),
    validator("json", createOrderSchema),
    async (context) => {
      const payload = context.req.valid("json");
      return context.json(await input.service.createOrder(payload));
    },
  );

  app.get(
    "/orders",
    describeRoute({
      tags: ["RFQ"],
      summary: "List orders",
      description: "Lists orders by supported filters such as orderId, status, swapper, or filler.",
      responses: {
        200: {
          description: "Orders response",
          content: {
            "application/json": {
              schema: resolver(ordersResponseSchema),
            },
          },
        },
        400: {
          description: "Missing or invalid filters",
          content: {
            "application/json": {
              schema: resolver(errorResponseSchema),
            },
          },
        },
      },
    }),
    validator("query", ordersQuerySchema),
    async (context) => {
      const query = context.req.valid("query");
      if (
        !query.orderId &&
        !(query.orderIds && query.orderIds.length > 0) &&
        !query.orderHash &&
        !(query.orderHashes && query.orderHashes.length > 0) &&
        !query.orderStatus &&
        !query.swapper &&
        !query.filler
      ) {
        throw new HTTPException(400, {
          message: "At least one of orderId, orderIds, orderHash, orderHashes, orderStatus, swapper, or filler is required",
        });
      }

      return context.json(await input.service.listOrders(query));
    },
  );

  return app;
}
