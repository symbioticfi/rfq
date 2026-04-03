import { URL } from "node:url";

import { z } from "zod";

import type { BackendOrderItem, DiscountsResponse, OrdersResponse, ResolveDiscountResponse } from "../types/domain";

function normalizeAddress(value: string): `0x${string}` {
  return value.toLowerCase() as `0x${string}`;
}

const addressSchema = z
  .string()
  .regex(/^0x[a-fA-F0-9]{40}$/)
  .transform((value) => normalizeAddress(value));
const hexSchema = z
  .string()
  .regex(/^0x[a-fA-F0-9]+$/)
  .transform((value) => value as `0x${string}`);
const hashSchema = z
  .string()
  .regex(/^0x[a-fA-F0-9]{64}$/)
  .transform((value) => value as `0x${string}`);

const backendOrderItemSchema = z.object({
  type: z.literal("Priority"),
  orderId: z.uuid(),
  orderStatus: z.enum(["open", "expired", "error", "cancelled", "filled", "unverified", "insufficient-funds"]),
  quoteId: z.uuid(),
  swapper: addressSchema,
  txHash: hexSchema.nullable(),
  nonce: hexSchema,
  input: z.object({
    token: addressSchema,
    amount: z.string().regex(/^\d+$/),
  }),
  outputs: z.array(
    z.object({
      token: addressSchema,
      amount: z.string().regex(/^\d+$/),
      recipient: addressSchema,
    }),
  ),
  settledAmounts: z.array(
    z.object({
      token: addressSchema,
      amount: z.string().regex(/^\d+$/),
      recipient: addressSchema,
      txHash: hexSchema,
    }),
  ),
  encodedOrder: hexSchema.optional(),
  signature: hexSchema.optional(),
  deadline: z.number().int().positive().optional(),
  filler: addressSchema.optional(),
});

const ordersResponseSchema = z.object({
  requestId: z.uuid(),
  orders: z.array(backendOrderItemSchema),
  cursor: z.string().nullable(),
});

const discountSchema = z.object({
  vault: addressSchema,
  tokenToRedeem: addressSchema,
  discount: z.string().regex(/^\d+$/),
  signer: addressSchema,
  protocol: addressSchema,
  nonce: hexSchema,
  deadline: z.number().int().positive(),
});

const discountListItemSchema = z.object({
  discountId: hashSchema,
  vault: addressSchema,
  tokenToRedeem: addressSchema,
  collateral: addressSchema,
  collateralDecimals: z.number().int().min(0).max(255),
  discount: z.string().regex(/^\d+$/),
  signer: addressSchema,
  deadline: z.number().int().positive(),
  maxRate: z.string().regex(/^\d+$/),
  maxAssets: z.string().regex(/^\d+$/),
});

const discountsResponseSchema = z.object({
  requestId: z.uuid(),
  protocol: addressSchema,
  discounts: z.array(discountListItemSchema),
});

const resolveDiscountResponseSchema = z.object({
  requestId: z.uuid(),
  discountId: hashSchema,
  discount: discountSchema,
  signerSignature: hexSchema,
  protocolDeadline: z.number().int().positive(),
  protocolSignature: hexSchema,
});

type BackendClientInput = {
  readonly baseUrl: string;
  readonly fetchImpl: typeof fetch;
};

/**
 * @dev Small HTTP client for the RFQ backend filler-facing order endpoints.
 */
export class BackendClient {
  readonly #baseUrl: string;
  readonly #fetchImpl: typeof fetch;

  constructor(input: BackendClientInput) {
    this.#baseUrl = input.baseUrl;
    this.#fetchImpl = input.fetchImpl;
  }

  /**
   * @dev Lists open backend orders assigned to this filler.
   * @param filler The executor/filler address.
   * @param limit The page size.
   * @returns Open order rows.
   */
  async listOpenOrders(filler: `0x${string}`, limit: number): Promise<readonly BackendOrderItem[]> {
    const response = await this.#get("/orders", {
      filler,
      orderStatus: "open",
      limit: String(limit),
    });

    return response.orders;
  }

  /**
   * @dev Reads the canonical executable view for a specific open order.
   * @param orderId The backend order id.
   * @param filler The filler address.
   * @returns The open executable order or `null`.
   */
  async getExecutableOrder(orderId: string, filler: `0x${string}`): Promise<BackendOrderItem | null> {
    const response = await this.#get("/orders", {
      orderId,
      filler,
      orderStatus: "open",
    });

    return response.orders[0] ?? null;
  }

  /**
   * @dev Reads the canonical backend view for a specific order regardless of status.
   * @param orderId The backend order id.
   * @returns The order or `null`.
   */
  async getOrder(orderId: string): Promise<BackendOrderItem | null> {
    const response = await this.#get("/orders", { orderId });
    return response.orders[0] ?? null;
  }

  async listDiscounts(): Promise<DiscountsResponse> {
    return this.#getJson("/discounts", discountsResponseSchema);
  }

  async resolveDiscount(input:
    | {
        readonly discountId: `0x${string}`;
        readonly vault?: undefined;
        readonly tokenToRedeem?: undefined;
      }
    | {
        readonly discountId?: undefined;
        readonly vault: `0x${string}`;
        readonly tokenToRedeem: `0x${string}`;
      }): Promise<ResolveDiscountResponse> {
    return this.#postJson("/discounts", resolveDiscountResponseSchema, input);
  }

  async #get(pathname: string, query: Record<string, string>) {
    const url = new URL(pathname, this.#baseUrl);
    for (const [key, value] of Object.entries(query)) {
      url.searchParams.set(key, value);
    }

    const response = await this.#fetchImpl(url, { method: "GET" });
    if (!response.ok) {
      throw new Error(`Backend request failed: ${response.status}`);
    }

    return ordersResponseSchema.parse((await response.json()) satisfies OrdersResponse);
  }

  async #getJson<T>(
    pathname: string,
    schema: z.ZodType<T>,
    query: Record<string, string> = {},
  ): Promise<T> {
    const url = new URL(pathname, this.#baseUrl);
    for (const [key, value] of Object.entries(query)) {
      url.searchParams.set(key, value);
    }

    const response = await this.#fetchImpl(url, { method: "GET" });
    if (!response.ok) {
      throw new Error(`Backend request failed: ${response.status}`);
    }

    return schema.parse(await response.json());
  }

  async #postJson<T>(
    pathname: string,
    schema: z.ZodType<T>,
    payload: Record<string, unknown>,
  ): Promise<T> {
    const url = new URL(pathname, this.#baseUrl);
    const response = await this.#fetchImpl(url, {
      method: "POST",
      headers: {
        "content-type": "application/json",
      },
      body: JSON.stringify(payload),
    });
    if (!response.ok) {
      throw new Error(`Backend request failed: ${response.status}`);
    }

    return schema.parse(await response.json());
  }
}
