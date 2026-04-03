export type CheckApprovalRequest = {
  readonly walletAddress: `0x${string}`;
  readonly chainId: number;
  readonly token: `0x${string}`;
  readonly amount: string;
};

export type ApprovalPayload = {
  readonly to: `0x${string}`;
  readonly data: `0x${string}`;
  readonly value: string;
};

export type CheckApprovalResponse = {
  readonly requestId: string;
  readonly approval: ApprovalPayload | null;
  readonly cancel: ApprovalPayload | null;
};

export type FaucetAsset = {
  readonly token: `0x${string}`;
  readonly symbol: string;
  readonly name: string;
  readonly decimals: number;
  readonly amount: string;
  readonly kind: "native" | "erc20";
};

export type LocalFaucetResponse = {
  readonly requestId: string;
  readonly assets: readonly FaucetAsset[];
};

export type LocalFaucetFundResponse = {
  readonly requestId: string;
  readonly walletAddress: `0x${string}`;
  readonly fundedAssets: readonly FaucetAsset[];
};

export type QuoteOutputRequest = {
  readonly token: `0x${string}`;
  readonly recipient: `0x${string}`;
  readonly portionBps?: number;
};

export type PublicQuoteRequest = {
  readonly tokenInChainId: number;
  readonly tokenOutChainId: number;
  readonly tokenIn: `0x${string}`;
  readonly tokenOut: `0x${string}`;
  readonly type: "EXACT_INPUT";
  readonly amount: string;
  readonly swapper: `0x${string}`;
  readonly slippageTolerance: number;
  readonly routingPreference: "BEST_PRICE";
  readonly permitAmount: "EXACT";
  readonly outputs: readonly QuoteOutputRequest[];
};

export type AggregatedOutput = {
  readonly token: `0x${string}`;
  readonly amount: string;
};

export type QuoteOrderOutput = {
  readonly token: `0x${string}`;
  readonly amount: string;
  readonly recipient: `0x${string}`;
};

export type QuoteOrderInfo = {
  readonly tokenIn: `0x${string}`;
  readonly amountIn: string;
  readonly outputs: readonly QuoteOrderOutput[];
  readonly deadline: number;
  readonly nonce: `0x${string}`;
};

export type PermitData = {
  readonly domain: Record<string, unknown>;
  readonly types: Record<string, ReadonlyArray<Record<string, string>>>;
  readonly value: Record<string, unknown>;
};

export type PublicQuoteResponse = {
  readonly requestId: string;
  readonly routing: "PRIORITY";
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

export type CreateOrderResponse = {
  readonly requestId: string;
  readonly orderId: string;
  readonly orderStatus: OrderStatus;
};

export type SettledAmount = {
  readonly token: `0x${string}`;
  readonly amount: string;
  readonly recipient: `0x${string}`;
  readonly txHash: `0x${string}`;
};

export type OrderStatus = "open" | "expired" | "error" | "cancelled" | "filled" | "unverified" | "insufficient-funds";

export type OrderListItem = {
  readonly type: "PRIORITY";
  readonly orderId: string;
  readonly orderStatus: OrderStatus;
  readonly quoteId: string;
  readonly swapper: `0x${string}`;
  readonly txHash: `0x${string}` | null;
  readonly nonce: `0x${string}`;
  readonly input: {
    readonly token: `0x${string}`;
    readonly amount: string;
  };
  readonly outputs: readonly QuoteOrderOutput[];
  readonly settledAmounts: readonly SettledAmount[];
  readonly encodedOrder?: `0x${string}`;
  readonly signature?: `0x${string}`;
  readonly deadline?: number;
  readonly filler?: `0x${string}`;
};

export type OrdersResponse = {
  readonly requestId: string;
  readonly orders: readonly OrderListItem[];
  readonly cursor?: string;
};

export type RfqQuote = {
  readonly requestId: string;
  readonly isPreview: boolean;
  readonly tokenOut: `0x${string}`;
  readonly amountOut: string;
  readonly orderInfo: QuoteOrderInfo;
  readonly quote: PublicQuoteResponse["quote"];
  readonly permitData: PermitData;
};

export type TrackedOrderStatus = "Pending" | "Filled" | "Expired" | "Failed";

export type TrackedOrder = {
  readonly orderId: string;
  readonly quoteId: string;
  readonly orderStatus: OrderStatus;
  readonly displayStatus: TrackedOrderStatus;
  readonly txHash: `0x${string}` | null;
  readonly input: OrderListItem["input"];
  readonly outputs: readonly QuoteOrderOutput[];
  readonly settledAmounts: readonly SettledAmount[];
};
