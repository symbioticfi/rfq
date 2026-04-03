export type RoutingPreference = "BEST_PRICE" | "FASTEST";

export type OrderType = "Priority";

export type QuotePhase = "preview" | "executable";

export type SolverQuoteStatus = "quoted" | "no_quote" | "timeout" | "error" | "cooldown";

export type OrderPublicStatus =
  | "open"
  | "expired"
  | "error"
  | "cancelled"
  | "filled"
  | "unverified"
  | "insufficient-funds";

export type OrderInternalStatus = "hard_auction" | "winner_selected" | "tx_submitted" | "filled" | "expired" | "failed";

export type QuoteWarning =
  | "HighPriceImpact"
  | "LowLiquidity"
  | "StaleState"
  | "HighGasCost"
  | { readonly Custom: string };

export type ApprovalPayload = {
  readonly to: `0x${string}`;
  readonly data: `0x${string}`;
  readonly value: string;
};

export type OrderOutput = {
  readonly token: `0x${string}`;
  readonly recipient: `0x${string}`;
  readonly amount: string;
  readonly portionBps?: number;
};

export type QuoteRequestInput = {
  readonly tokenInChainId: number;
  readonly tokenOutChainId: number;
  readonly tokenIn: `0x${string}`;
  readonly tokenOut: `0x${string}`;
  readonly type: "EXACT_INPUT";
  readonly amount: string;
  readonly swapper: `0x${string}`;
  readonly slippageTolerance: number;
  readonly routingPreference: RoutingPreference;
  readonly permitAmount?: "EXACT";
  readonly outputs: ReadonlyArray<{
    readonly token: `0x${string}`;
    readonly recipient: `0x${string}`;
    readonly portionBps?: number;
  }>;
};

export type SolverInventory = {
  readonly vault: `0x${string}`;
  readonly collateral: `0x${string}`;
  readonly collateralDecimals: number;
  readonly maxCollateralOut: string;
  readonly maxRate: string;
  readonly discountId?: `0x${string}` | null;
};

export type Discount = {
  readonly vault: `0x${string}`;
  readonly tokenToRedeem: `0x${string}`;
  readonly discount: string;
  readonly signer: `0x${string}`;
  readonly protocol: `0x${string}`;
  readonly nonce: `0x${string}`;
  readonly deadline: number;
};

export type DiscountRecord = {
  readonly discountId: `0x${string}`;
  readonly chainId: number;
  readonly vault: `0x${string}`;
  readonly tokenToRedeem: `0x${string}`;
  readonly discountPpm: string;
  readonly signer: `0x${string}`;
  readonly protocol: `0x${string}`;
  readonly nonce: `0x${string}`;
  readonly deadline: number;
  readonly signerSignature: `0x${string}`;
  readonly createdAt: Date;
  readonly updatedAt: Date;
};

export type DiscountListItem = {
  readonly discountId: `0x${string}`;
  readonly vault: `0x${string}`;
  readonly tokenToRedeem: `0x${string}`;
  readonly collateral: `0x${string}`;
  readonly collateralDecimals: number;
  readonly discount: string;
  readonly signer: `0x${string}`;
  readonly deadline: number;
  readonly maxRate: string;
  readonly maxAssets: string;
};

export type DiscountsResponse = {
  readonly requestId: string;
  readonly protocol: `0x${string}`;
  readonly discounts: readonly DiscountListItem[];
};

export type DiscountFilters =
  | {
      readonly discountId?: undefined;
      readonly discountIds?: undefined;
      readonly vault?: undefined;
      readonly tokenToRedeem?: undefined;
      readonly vaults?: undefined;
      readonly tokensToRedeem?: undefined;
    }
  | {
      readonly discountId: `0x${string}`;
      readonly discountIds?: undefined;
      readonly vault?: undefined;
      readonly tokenToRedeem?: undefined;
      readonly vaults?: undefined;
      readonly tokensToRedeem?: undefined;
    }
  | {
      readonly discountId?: undefined;
      readonly discountIds: readonly `0x${string}`[];
      readonly vault?: undefined;
      readonly tokenToRedeem?: undefined;
      readonly vaults?: undefined;
      readonly tokensToRedeem?: undefined;
    }
  | {
      readonly discountId?: undefined;
      readonly discountIds?: undefined;
      readonly vault: `0x${string}`;
      readonly tokenToRedeem: `0x${string}`;
      readonly vaults?: undefined;
      readonly tokensToRedeem?: undefined;
    }
  | {
      readonly discountId?: undefined;
      readonly discountIds?: undefined;
      readonly vault?: undefined;
      readonly tokenToRedeem?: undefined;
      readonly vaults: readonly `0x${string}`[];
      readonly tokensToRedeem: readonly `0x${string}`[];
    };

export type PublishDiscountRequest = {
  readonly discount: Discount;
  readonly signature: `0x${string}`;
};

export type PublishDiscountResponse = {
  readonly requestId: string;
  readonly discountId: `0x${string}`;
};

export type ResolveDiscountRequest =
  | {
      readonly discountId: `0x${string}`;
      readonly discountIds?: undefined;
      readonly vault?: undefined;
      readonly tokenToRedeem?: undefined;
      readonly vaults?: undefined;
      readonly tokensToRedeem?: undefined;
    }
  | {
      readonly discountId?: undefined;
      readonly discountIds?: undefined;
      readonly vault: `0x${string}`;
      readonly tokenToRedeem: `0x${string}`;
      readonly vaults?: undefined;
      readonly tokensToRedeem?: undefined;
    }
  | {
      readonly discountId?: undefined;
      readonly discountIds: readonly `0x${string}`[];
      readonly vault?: undefined;
      readonly tokenToRedeem?: undefined;
      readonly vaults?: undefined;
      readonly tokensToRedeem?: undefined;
    }
  | {
      readonly discountId?: undefined;
      readonly discountIds?: undefined;
      readonly vault?: undefined;
      readonly tokenToRedeem?: undefined;
      readonly vaults: readonly `0x${string}`[];
      readonly tokensToRedeem: readonly `0x${string}`[];
    };

export type ResolvedDiscount = {
  readonly discountId: `0x${string}`;
  readonly discount: Discount;
  readonly signerSignature: `0x${string}`;
  readonly protocolDeadline: number;
  readonly protocolSignature: `0x${string}`;
};

export type ResolveDiscountResponse = {
  readonly requestId: string;
} & ResolvedDiscount;

export type ResolveDiscountsResponse = {
  readonly requestId: string;
  readonly discounts: readonly ResolvedDiscount[];
};

export type SolverQuoteRequest = {
  readonly requestId: string;
  readonly tokenInChainId: number;
  readonly tokenOutChainId: number;
  readonly swapper: `0x${string}`;
  readonly tokenIn: `0x${string}`;
  readonly tokenOut: `0x${string}`;
  readonly amount: string;
  readonly type: "EXACT_INPUT";
  readonly protocol: "v1";
  readonly numOutputs: number;
  readonly quoteId: string;
  readonly vaults: readonly SolverInventory[];
};

export type SolverQuoteResponse = {
  readonly chainId: number;
  readonly amountIn: string;
  readonly amountOut: string;
  readonly filler: `0x${string}`;
  readonly requestId: string;
  readonly swapper: `0x${string}`;
  readonly tokenIn: `0x${string}`;
  readonly tokenOut: `0x${string}`;
  readonly quoteId: string;
};

export type AggregatedOutput = {
  readonly token: `0x${string}`;
  readonly amount: string;
};

export type QuoteOrderInfo = {
  readonly tokenIn: `0x${string}`;
  readonly amountIn: string;
  readonly outputs: readonly OrderOutput[];
  readonly deadline: number;
  readonly nonce: string;
};

export type PermitData = {
  readonly domain: Record<string, unknown>;
  readonly types: Record<string, ReadonlyArray<Record<string, string>>>;
  readonly value: Record<string, unknown>;
};

export type PublicQuoteResponse = {
  readonly requestId: string;
  readonly routing: OrderType;
  readonly quote: {
    readonly quoteId: string;
    readonly slippageTolerance: number;
    readonly aggregatedOutputs: readonly AggregatedOutput[];
    readonly orderInfo: QuoteOrderInfo;
  };
  readonly permitData: PermitData;
};

export type CreateOrderRequest = {
  readonly quote: PublicQuoteResponse["quote"];
  readonly signature: `0x${string}`;
};

export type OrderRecord = {
  readonly orderId: string;
  readonly quoteId: string;
  readonly requestId: string;
  readonly swapper: `0x${string}`;
  readonly filler: `0x${string}`;
  readonly tokenIn: `0x${string}`;
  readonly amountIn: string;
  readonly outputs: readonly OrderOutput[];
  readonly deadline: number;
  readonly nonce: string;
  readonly orderHash: `0x${string}`;
  readonly encodedOrder: `0x${string}`;
  readonly protocolSignature: `0x${string}`;
  readonly swapperSignature: `0x${string}`;
  readonly publicStatus: OrderPublicStatus;
  readonly internalStatus: OrderInternalStatus;
  readonly txHash: `0x${string}` | null;
  readonly createdAt: Date;
  readonly updatedAt: Date;
};

export type SettledAmount = {
  readonly token: `0x${string}`;
  readonly amount: string;
  readonly recipient: `0x${string}`;
  readonly txHash: `0x${string}`;
};

export type OrderListItem = {
  readonly type: OrderType;
  readonly orderId: string;
  readonly orderStatus: OrderPublicStatus;
  readonly quoteId: string;
  readonly swapper: `0x${string}`;
  readonly txHash: `0x${string}` | null;
  readonly nonce: string;
  readonly input: {
    readonly token: `0x${string}`;
    readonly amount: string;
  };
  readonly outputs: readonly OrderOutput[];
  readonly settledAmounts: readonly SettledAmount[];
  readonly encodedOrder?: `0x${string}`;
  readonly signature?: `0x${string}`;
  readonly deadline?: number;
  readonly filler?: `0x${string}`;
};

export type SolverConfig = {
  readonly id: string;
  readonly chainId: number;
  readonly name: string;
  readonly endpointUrl: string;
  readonly notifyUrl: string | null;
  readonly filler: `0x${string}`;
  readonly enabled: boolean;
  readonly cooldownUntil: Date | null;
  readonly metadata: Record<string, unknown>;
  readonly createdAt: Date;
  readonly updatedAt: Date;
};

export type QuoteRequestRecord = {
  readonly id: string;
  readonly requestId: string;
  readonly quoteId: string;
  readonly phase: QuotePhase;
  readonly request: QuoteRequestInput;
  readonly permitData: PermitData;
  readonly outputs: readonly OrderOutput[];
  readonly bestAmountOut: string | null;
  readonly bestFiller: `0x${string}` | null;
  readonly selectedSolverId: string | null;
  readonly expiresAt: Date;
  readonly createdAt: Date;
};

export type SolverQuoteRecord = {
  readonly id: string;
  readonly quoteRequestId: string;
  readonly solverId: string;
  readonly phase: QuotePhase;
  readonly status: SolverQuoteStatus;
  readonly latencyMs: number;
  readonly amountOut: string | null;
  readonly filler: `0x${string}` | null;
  readonly responsePayload: Record<string, unknown> | null;
  readonly errorMessage: string | null;
  readonly createdAt: Date;
};
