import { z } from "zod";

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

export const errorResponseSchema = z.object({
  error: z.string(),
});

export const healthResponseSchema = z.object({
  status: z.literal("ok"),
  timestamp: z.string(),
});

export const solverQuoteResponseSchema = z.object({
  chainId: z.number().int().positive(),
  amountIn: z.string().regex(/^\d+$/),
  amountOut: z.string().regex(/^\d+$/),
  filler: addressSchema,
  requestId: z.string(),
  swapper: addressSchema,
  tokenIn: addressSchema,
  tokenOut: addressSchema,
  quoteId: z.uuid(),
});

export const notifyAcceptedResponseSchema = z.object({
  status: z.literal("queued"),
});

export const solverQuoteRequestSchema = z
  .object({
    requestId: z.uuid(),
    tokenInChainId: z.number().int().positive(),
    tokenOutChainId: z.number().int().positive(),
    swapper: addressSchema,
    tokenIn: addressSchema,
    tokenOut: addressSchema,
    amount: z.string().regex(/^\d+$/),
    type: z.literal("EXACT_INPUT"),
    protocol: z.literal("v1"),
    numOutputs: z.number().int().positive(),
    quoteId: z.uuid(),
    vaults: z.array(
      z.object({
        vault: addressSchema,
        collateral: addressSchema,
        collateralDecimals: z.number().int().min(0).max(255),
        maxCollateralOut: z.string().regex(/^\d+$/),
        maxRate: z.string().regex(/^\d+$/),
        discountId: hashSchema.nullish(),
      }),
    ),
  });

export const notifySchema = z.object({
  orderHash: hexSchema,
  createdAt: z.number().int().nonnegative(),
  notifiedAt: z.number().int().nonnegative().optional(),
  signature: hexSchema.optional(),
  orderStatus: z.string().min(1),
  encodedOrder: hexSchema.optional(),
  chainId: z.number().int().positive(),
  filler: addressSchema.optional(),
  quoteId: z.uuid().optional(),
  offerer: addressSchema.optional(),
  type: z.literal("Priority").optional(),
});
