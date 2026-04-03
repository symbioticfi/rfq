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

export type ResolveDiscountResponse = {
  readonly requestId: string;
  readonly discountId: `0x${string}`;
  readonly discount: Discount;
  readonly signerSignature: `0x${string}`;
  readonly protocolDeadline: number;
  readonly protocolSignature: `0x${string}`;
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

export type NotifyRequest = {
  readonly orderHash: `0x${string}`;
  readonly createdAt: number;
  readonly notifiedAt?: number;
  readonly signature?: `0x${string}`;
  readonly orderStatus: string;
  readonly encodedOrder?: `0x${string}`;
  readonly chainId: number;
  readonly filler?: `0x${string}`;
  readonly quoteId?: string;
  readonly offerer?: `0x${string}`;
  readonly type?: "Priority";
};

export type BackendOrderOutput = {
  readonly token: `0x${string}`;
  readonly amount: string;
  readonly recipient: `0x${string}`;
};

export type BackendOrderItem = {
  readonly type: "Priority";
  readonly orderId: string;
  readonly orderStatus: "open" | "expired" | "error" | "cancelled" | "filled" | "unverified" | "insufficient-funds";
  readonly quoteId: string;
  readonly swapper: `0x${string}`;
  readonly txHash: `0x${string}` | null;
  readonly nonce: `0x${string}`;
  readonly input: {
    readonly token: `0x${string}`;
    readonly amount: string;
  };
  readonly outputs: readonly BackendOrderOutput[];
  readonly settledAmounts: readonly {
    readonly token: `0x${string}`;
    readonly amount: string;
    readonly recipient: `0x${string}`;
    readonly txHash: `0x${string}`;
  }[];
  readonly encodedOrder?: `0x${string}`;
  readonly signature?: `0x${string}`;
  readonly deadline?: number;
  readonly filler?: `0x${string}`;
};

export type OrdersResponse = {
  readonly requestId: string;
  readonly orders: readonly BackendOrderItem[];
  readonly cursor: string | null;
};

export type StrategyLeg = {
  readonly vault: `0x${string}`;
  readonly amountIn: string;
  readonly amountOut: string;
  readonly maxRate: string;
  readonly discountId?: `0x${string}` | null;
};

export type StrategyRecord = {
  readonly quoteId: string;
  readonly requestId: string;
  readonly tokenIn: `0x${string}`;
  readonly tokenOut: `0x${string}`;
  readonly amountIn: string;
  readonly collateral: `0x${string}`;
  readonly collateralDecimals: number;
  readonly collateralAmountOut: string;
  readonly quotedAmountOut: string;
  readonly legs: readonly StrategyLeg[];
  readonly createdAt: Date;
  readonly updatedAt: Date;
};

export type LocalOrderStatus = "queued" | "submitting" | "submitted" | "filled" | "expired" | "failed";

export type LocalOrderRecord = {
  readonly orderId: string;
  readonly orderHash?: `0x${string}` | null;
  readonly quoteId: string | null;
  readonly source: "notify" | "poll";
  readonly status: LocalOrderStatus;
  readonly filler: `0x${string}` | null;
  readonly encodedOrder: `0x${string}` | null;
  readonly protocolSignature: `0x${string}` | null;
  readonly deadline: number | null;
  readonly txHash: `0x${string}` | null;
  readonly lastError: string | null;
  readonly createdAt: Date;
  readonly updatedAt: Date;
};

export type ExecutionAttemptRecord = {
  readonly id: string;
  readonly orderId: string;
  readonly attempt: number;
  readonly txHash: `0x${string}` | null;
  readonly error: string | null;
  readonly createdAt: Date;
};

export type ReactorOutput = {
  readonly token: `0x${string}`;
  readonly amount: bigint;
  readonly recipient: `0x${string}`;
};

export type ReactorRequest = {
  readonly tokenIn: `0x${string}`;
  readonly amountIn: bigint;
  readonly outputs: readonly ReactorOutput[];
  readonly deadline: bigint;
  readonly nonce: bigint;
  readonly protocol: `0x${string}`;
};

export type ReactorOrder = {
  readonly request: ReactorRequest;
  readonly swapperSignature: `0x${string}`;
  readonly swapper: `0x${string}`;
  readonly filler: `0x${string}`;
};

export type ReactorSwap = {
  readonly recipient: `0x${string}`;
  readonly vault: `0x${string}`;
  readonly tokenIn: `0x${string}`;
  readonly amountIn: bigint;
  readonly amountOut: bigint;
};

export type ReactorDiscount = {
  readonly vault: `0x${string}`;
  readonly tokenToRedeem: `0x${string}`;
  readonly discount: bigint;
  readonly signer: `0x${string}`;
  readonly protocol: `0x${string}`;
  readonly nonce: bigint;
  readonly deadline: number;
};

export type ReactorDiscountSwap = {
  readonly discount: ReactorDiscount;
  readonly signerSignature: `0x${string}`;
  readonly protocolDeadline: number;
};

export type ReactorDiscountSwapInput = {
  readonly discountSwap: ReactorDiscountSwap;
  readonly protocolSignature: `0x${string}`;
  readonly recipient: `0x${string}`;
  readonly amountIn: bigint;
  readonly amountOut: bigint;
};

export type ExecutorCall = {
  readonly target: `0x${string}`;
  readonly value: bigint;
  readonly data: `0x${string}`;
};
