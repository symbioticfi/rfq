import { API_BASE_URL } from "../config/api";
import type {
  CheckApprovalRequest,
  CheckApprovalResponse,
  CreateOrderRequest,
  CreateOrderResponse,
  LocalFaucetFundResponse,
  LocalFaucetResponse,
  OrdersResponse,
  PublicQuoteRequest,
  PublicQuoteResponse,
  RfqQuote,
  TrackedOrder,
  TrackedOrderStatus,
} from "../types/quote";

function buildUrl(path: string) {
  return `${API_BASE_URL}${path}`;
}

async function parseJson<T>(response: Response): Promise<T | null> {
  try {
    return (await response.json()) as T;
  } catch {
    return null;
  }
}

function readError(response: Response, data: unknown) {
  if (typeof data === "object" && data !== null && "error" in data && typeof data.error === "string") {
    return data.error;
  }

  return `Request failed (${response.status})`;
}

function normalizeTrackedOrder(order: OrdersResponse["orders"][number]): TrackedOrder {
  let displayStatus: TrackedOrderStatus;

  switch (order.orderStatus) {
    case "filled":
      displayStatus = "Filled";
      break;
    case "expired":
      displayStatus = "Expired";
      break;
    case "open":
      displayStatus = "Pending";
      break;
    default:
      displayStatus = "Failed";
      break;
  }

  return {
    orderId: order.orderId,
    quoteId: order.quoteId,
    orderStatus: order.orderStatus,
    displayStatus,
    txHash: order.txHash,
    input: order.input,
    outputs: order.outputs,
    settledAmounts: order.settledAmounts,
  };
}

export function toRfqQuote(response: PublicQuoteResponse, options: { readonly isPreview: boolean }): RfqQuote {
  const [primaryOutput] = response.quote.aggregatedOutputs;
  if (!primaryOutput) {
    throw new Error("Quote response did not include any outputs");
  }

  return {
    requestId: response.requestId,
    isPreview: options.isPreview,
    tokenOut: primaryOutput.token,
    amountOut: primaryOutput.amount,
    orderInfo: response.quote.orderInfo,
    quote: response.quote,
    permitData: response.permitData,
  };
}

/**
 * @dev Calls the doc-defined Permit2 approval bootstrap endpoint.
 * @param request The approval check input.
 * @returns Approval bootstrap payload or null if already approved.
 */
export async function checkApproval(request: CheckApprovalRequest): Promise<CheckApprovalResponse> {
  const response = await fetch(buildUrl("/check_approval"), {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
    },
    body: JSON.stringify(request),
  });
  const data = await parseJson<CheckApprovalResponse | { readonly error: string }>(response);

  if (!response.ok || !data || "error" in data) {
    throw new Error(readError(response, data));
  }

  return data;
}

/**
 * @dev Reads the fixed local faucet bundle configuration.
 * @returns The list of assets and transfer amounts.
 */
export async function getLocalFaucet(): Promise<LocalFaucetResponse> {
  const response = await fetch(buildUrl("/dev/faucet"));
  const data = await parseJson<LocalFaucetResponse | { readonly error: string }>(response);

  if (!response.ok || !data || "error" in data) {
    throw new Error(readError(response, data));
  }

  return data;
}

/**
 * @dev Transfers the full local faucet bundle to the requested address.
 * @param walletAddress The wallet to fund.
 * @returns The funded asset bundle.
 */
export async function fundFromLocalFaucet(walletAddress: `0x${string}`): Promise<LocalFaucetFundResponse> {
  const response = await fetch(buildUrl("/dev/faucet"), {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ walletAddress }),
  });
  const data = await parseJson<LocalFaucetFundResponse | { readonly error: string }>(response);

  if (!response.ok || !data || "error" in data) {
    throw new Error(readError(response, data));
  }

  return data;
}

/**
 * @dev Requests an indicative quote from the canonical RFQ route.
 * @param request The quote request payload.
 * @param options Optional abort signal and preview flag.
 * @returns A normalized RFQ quote or null when the backend returns no quote.
 */
export async function requestQuote(
  request: PublicQuoteRequest,
  options?: { readonly signal?: AbortSignal; readonly isPreview?: boolean },
): Promise<RfqQuote | null> {
  const response = await fetch(buildUrl("/quote"), {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
    },
    body: JSON.stringify(request),
    signal: options?.signal,
  });

  if (response.status === 404) {
    return null;
  }

  const data = await parseJson<PublicQuoteResponse | { readonly error: string }>(response);
  if (!response.ok || !data || "error" in data) {
    throw new Error(readError(response, data));
  }

  return toRfqQuote(data, { isPreview: options?.isPreview ?? false });
}

/**
 * @dev Submits a signed order for hard RFQ and execution.
 * @param request The order submission payload.
 * @returns The canonical order creation response.
 */
export async function submitOrder(request: CreateOrderRequest): Promise<CreateOrderResponse> {
  const response = await fetch(buildUrl("/order"), {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
    },
    body: JSON.stringify(request),
  });
  const data = await parseJson<CreateOrderResponse | { readonly error: string }>(response);

  if (!response.ok || !data || "error" in data) {
    const error = new Error(readError(response, data));
    (error as Error & { status?: number }).status = response.status;
    throw error;
  }

  return data;
}

/**
 * @dev Fetches orders from the canonical public order retrieval endpoint.
 * @param input The lookup filters.
 * @returns Raw order list response.
 */
export async function listOrders(input: { readonly orderId: string }): Promise<OrdersResponse> {
  const searchParams = new URLSearchParams({ orderId: input.orderId });
  const response = await fetch(buildUrl(`/orders?${searchParams.toString()}`));
  const data = await parseJson<OrdersResponse | { readonly error: string }>(response);

  if (!response.ok || !data || "error" in data) {
    throw new Error(readError(response, data));
  }

  return data;
}

/**
 * @dev Fetches and normalizes a single tracked order.
 * @param orderId The public order id.
 * @returns The tracked order, if any.
 */
export async function getTrackedOrder(orderId: string): Promise<TrackedOrder | null> {
  const response = await listOrders({ orderId });
  const [order] = response.orders;

  return order ? normalizeTrackedOrder(order) : null;
}
