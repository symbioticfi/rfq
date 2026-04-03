import { z } from "zod";

function splitCommaSeparated(value: string) {
  return value
    .split(",")
    .map((entry) => entry.trim())
    .filter(Boolean);
}

function parseArrayWithSchema<T>(
  raw: unknown,
  arraySchema: z.ZodType<T>,
  context: z.RefinementCtx,
) {
  const parsed = arraySchema.safeParse(raw);
  if (!parsed.success) {
    for (const issue of parsed.error.issues) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        message: issue.message,
        path: issue.path,
      });
    }
    return z.NEVER;
  }
  return parsed.data;
}

const addressSchema = z
  .string()
  .regex(/^0x[a-fA-F0-9]{40}$/)
  .transform((value) => value.toLowerCase() as `0x${string}`);
const signatureSchema = z
  .string()
  .regex(/^0x[a-fA-F0-9]+$/)
  .transform((value) => value as `0x${string}`);
const orderHashSchema = z
  .string()
  .regex(/^0x[a-fA-F0-9]{64}$/)
  .transform((value) => value as `0x${string}`);
const orderHashListSchema = z.array(orderHashSchema).min(1).max(50);
const addressListSchema = z.array(addressSchema).min(1).max(50);
const commaSeparatedOrderHashesSchema = z.string().transform((value, context) =>
  parseArrayWithSchema(splitCommaSeparated(value), orderHashListSchema, context),
);
const commaSeparatedAddressesSchema = z.string().transform((value, context) =>
  parseArrayWithSchema(splitCommaSeparated(value), addressListSchema, context),
);
const commaSeparatedOrArrayOrderHashesSchema = z.unknown().transform((value, context) =>
  parseArrayWithSchema(typeof value === "string" ? splitCommaSeparated(value) : value, orderHashListSchema, context),
);
const commaSeparatedOrArrayAddressesSchema = z.unknown().transform((value, context) =>
  parseArrayWithSchema(typeof value === "string" ? splitCommaSeparated(value) : value, addressListSchema, context),
);

const aggregatedOutputSchema = z.object({
  token: addressSchema,
  amount: z.string().regex(/^\d+$/),
});

const orderOutputSchema = z.object({
  token: addressSchema,
  recipient: addressSchema,
  amount: z.string().regex(/^\d+$/),
  portionBps: z.number().int().min(0).max(10_000).optional(),
});

const permitDataSchema = z.object({
  domain: z.record(z.string(), z.unknown()),
  types: z.record(z.string(), z.array(z.record(z.string(), z.string()))),
  value: z.record(z.string(), z.unknown()),
});

const discountSchema = z.object({
  vault: addressSchema,
  tokenToRedeem: addressSchema,
  discount: z.string().regex(/^\d+$/),
  signer: addressSchema,
  protocol: addressSchema,
  nonce: signatureSchema,
  deadline: z.number().int().positive(),
});

const discountListItemSchema = z.object({
  discountId: orderHashSchema,
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

const settledAmountSchema = z.object({
  token: addressSchema,
  amount: z.string().regex(/^\d+$/),
  recipient: addressSchema,
  txHash: signatureSchema,
});

export const approvalCheckSchema = z.object({
  walletAddress: addressSchema,
  chainId: z.number().int().positive(),
  token: addressSchema,
  amount: z.string().regex(/^\d+$/),
});

export const localFundSchema = z.object({
  walletAddress: addressSchema,
});

export const localFaucetAssetSchema = z.object({
  token: addressSchema,
  symbol: z.string().min(1),
  name: z.string().min(1),
  decimals: z.number().int().min(0),
  amount: z.string().regex(/^\d+$/),
  kind: z.enum(["native", "erc20"]),
});

export const quoteRequestSchema = z
  .object({
    tokenInChainId: z.number().int().positive(),
    tokenOutChainId: z.number().int().positive(),
    tokenIn: addressSchema,
    tokenOut: addressSchema,
    type: z.literal("EXACT_INPUT"),
    amount: z.string().regex(/^\d+$/),
    swapper: addressSchema,
    slippageTolerance: z.number().nonnegative(),
    routingPreference: z.enum(["BEST_PRICE", "FASTEST"]).default("BEST_PRICE"),
    permitAmount: z.literal("EXACT").optional(),
    outputs: z
      .array(
        z.object({
          token: addressSchema,
          recipient: addressSchema,
          portionBps: z.number().int().min(0).max(10_000).optional(),
        }),
      )
      .min(1),
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

export const publishDiscountSchema = z.object({
  discount: discountSchema,
  signature: signatureSchema,
});

export const discountsQuerySchema = z
  .object({
    discountId: orderHashSchema.optional(),
    discountIds: commaSeparatedOrderHashesSchema.optional(),
    vault: addressSchema.optional(),
    tokenToRedeem: addressSchema.optional(),
    vaults: commaSeparatedAddressesSchema.optional(),
    tokensToRedeem: commaSeparatedAddressesSchema.optional(),
  })
  .superRefine((value, context) => {
    const hasSingleId = Boolean(value.discountId);
    const hasManyIds = Boolean(value.discountIds?.length);
    const hasSinglePair = Boolean(value.vault) || Boolean(value.tokenToRedeem);
    const hasManyPairs = Boolean(value.vaults?.length) || Boolean(value.tokensToRedeem?.length);
    const selectedModes = [hasSingleId || hasManyIds, hasSinglePair || hasManyPairs].filter(Boolean).length;

    if (selectedModes > 1) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        message: "Provide discountId(s) or vault/tokenToRedeem selector(s), not both",
      });
    }
    if (hasSinglePair && !(value.vault && value.tokenToRedeem)) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        message: "Provide vault and tokenToRedeem together",
      });
    }
    if (hasManyPairs && !(value.vaults && value.tokensToRedeem)) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        message: "Provide vaults and tokensToRedeem together",
      });
    }
    if (value.vaults && value.tokensToRedeem && value.vaults.length !== value.tokensToRedeem.length) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        message: "vaults and tokensToRedeem must have the same number of entries",
      });
    }
  });

export const resolveDiscountSchema = z
  .object({
    discountId: orderHashSchema.optional(),
    discountIds: commaSeparatedOrArrayOrderHashesSchema.optional(),
    vault: addressSchema.optional(),
    tokenToRedeem: addressSchema.optional(),
    vaults: commaSeparatedOrArrayAddressesSchema.optional(),
    tokensToRedeem: commaSeparatedOrArrayAddressesSchema.optional(),
  })
  .superRefine((value, context) => {
    const hasSingleId = Boolean(value.discountId);
    const hasManyIds = Boolean(value.discountIds?.length);
    const hasSinglePair = Boolean(value.vault) || Boolean(value.tokenToRedeem);
    const hasManyPairs = Boolean(value.vaults?.length) || Boolean(value.tokensToRedeem?.length);
    const selectedModes = [hasSingleId, hasManyIds, hasSinglePair, hasManyPairs].filter(Boolean).length;

    if (selectedModes === 0) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        message: "Provide discountId, discountIds, vault/tokenToRedeem, or vaults/tokensToRedeem",
      });
    }
    if (selectedModes > 1) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        message: "Provide one discount selector mode at a time",
      });
    }
    if (hasSinglePair && !(value.vault && value.tokenToRedeem)) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        message: "Provide vault and tokenToRedeem together",
      });
    }
    if (hasManyPairs && !(value.vaults && value.tokensToRedeem)) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        message: "Provide vaults and tokensToRedeem together",
      });
    }
    if (value.vaults && value.tokensToRedeem && value.vaults.length !== value.tokensToRedeem.length) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        message: "vaults and tokensToRedeem must have the same number of entries",
      });
    }
  });

export const createOrderSchema = z.object({
  quote: z.object({
    quoteId: z.uuid(),
    slippageTolerance: z.number().nonnegative(),
    aggregatedOutputs: z.array(
      z.object({
        token: addressSchema,
        amount: z.string().regex(/^\d+$/),
      }),
    ),
    orderInfo: z.object({
      tokenIn: addressSchema,
      amountIn: z.string().regex(/^\d+$/),
      outputs: z.array(
        z.object({
          token: addressSchema,
          amount: z.string().regex(/^\d+$/),
          recipient: addressSchema,
        }),
      ),
      deadline: z.number().int().positive(),
      nonce: signatureSchema,
    }),
  }),
  signature: signatureSchema,
});

export const ordersQuerySchema = z.object({
  orderType: z.string().optional(),
  limit: z.coerce.number().int().positive().max(100).optional(),
  cursor: z.string().optional(),
  orderStatus: z
    .enum(["open", "expired", "error", "cancelled", "filled", "unverified", "insufficient-funds"])
    .optional(),
  orderId: z.uuid().optional(),
  orderIds: z
    .string()
    .optional()
    .transform((value) =>
      value
        ? value
            .split(",")
            .map((entry) => entry.trim())
            .filter(Boolean)
        : undefined,
    ),
  orderHash: orderHashSchema.optional(),
  orderHashes: z
    .string()
    .optional()
    .transform((value) =>
      value
        ? value
            .split(",")
            .map((entry) => entry.trim())
            .filter(Boolean)
        : undefined,
    )
    .pipe(z.array(orderHashSchema).max(50).optional()),
  swapper: addressSchema.optional(),
  filler: addressSchema.optional(),
  sortKey: z.enum(["createdAt", "updatedAt"]).optional(),
  sort: z.enum(["asc", "desc"]).optional(),
});

export const errorResponseSchema = z.object({
  error: z.string(),
});

export const healthResponseSchema = z.object({
  status: z.literal("ok"),
  timestamp: z.string(),
});

export const approvalCheckResponseSchema = z.object({
  requestId: z.string(),
  approval: z
    .object({
      to: addressSchema,
      data: signatureSchema,
      value: z.string(),
    })
    .nullable(),
  cancel: z.null(),
});

export const localFundResponseSchema = z.object({
  requestId: z.string(),
  walletAddress: addressSchema,
  fundedEth: z.string().regex(/^\d+$/),
  fundedToken: z.string().regex(/^\d+$/),
  token: addressSchema,
});

export const localFaucetResponseSchema = z.object({
  requestId: z.string(),
  assets: z.array(localFaucetAssetSchema),
});

export const localFaucetFundResponseSchema = z.object({
  requestId: z.string(),
  walletAddress: addressSchema,
  fundedAssets: z.array(localFaucetAssetSchema),
});

export const publicQuoteResponseSchema = z.object({
  requestId: z.string(),
  routing: z.literal("Priority"),
  quote: z.object({
    quoteId: z.uuid(),
    slippageTolerance: z.number().nonnegative(),
    aggregatedOutputs: z.array(aggregatedOutputSchema),
    orderInfo: z.object({
      tokenIn: addressSchema,
      amountIn: z.string().regex(/^\d+$/),
      outputs: z.array(orderOutputSchema),
      deadline: z.number().int().positive(),
      nonce: signatureSchema,
    }),
  }),
  permitData: permitDataSchema,
});

export const discountsResponseSchema = z.object({
  requestId: z.uuid(),
  protocol: addressSchema,
  discounts: z.array(discountListItemSchema),
});

export const publishDiscountResponseSchema = z.object({
  requestId: z.uuid(),
  discountId: orderHashSchema,
});

export const resolveDiscountResponseSchema = z.object({
  requestId: z.uuid(),
  discountId: orderHashSchema,
  discount: discountSchema,
  signerSignature: signatureSchema,
  protocolDeadline: z.number().int().positive(),
  protocolSignature: signatureSchema,
});

export const resolveDiscountsResponseSchema = z.object({
  requestId: z.uuid(),
  discounts: z.array(
    z.object({
      discountId: orderHashSchema,
      discount: discountSchema,
      signerSignature: signatureSchema,
      protocolDeadline: z.number().int().positive(),
      protocolSignature: signatureSchema,
    }),
  ),
});

export const resolveDiscountRouteResponseSchema = z.union([
  resolveDiscountResponseSchema,
  resolveDiscountsResponseSchema,
]);

export const createOrderResponseSchema = z.object({
  requestId: z.string(),
  orderId: z.uuid(),
  orderStatus: z.enum(["open", "expired", "error", "cancelled", "filled", "unverified", "insufficient-funds"]),
});

export const orderListItemSchema = z.object({
  type: z.literal("Priority"),
  orderId: z.uuid(),
  orderStatus: z.enum(["open", "expired", "error", "cancelled", "filled", "unverified", "insufficient-funds"]),
  quoteId: z.uuid(),
  swapper: addressSchema,
  txHash: signatureSchema.nullable(),
  nonce: z.string(),
  input: z.object({
    token: addressSchema,
    amount: z.string().regex(/^\d+$/),
  }),
  outputs: z.array(orderOutputSchema),
  settledAmounts: z.array(settledAmountSchema),
  encodedOrder: signatureSchema.optional(),
  signature: signatureSchema.optional(),
  deadline: z.number().int().positive().optional(),
  filler: addressSchema.optional(),
});

export const ordersResponseSchema = z.object({
  requestId: z.string(),
  orders: z.array(orderListItemSchema),
  cursor: z.string().nullable(),
});
