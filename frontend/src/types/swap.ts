import type { Token } from "./token";

export type SwapState = {
  readonly sellToken: Token | null;
  readonly buyToken: Token | null;
  readonly sellAmount: string;
  readonly slippageBps: number;
  readonly slippageMode: "preset" | "custom";
  readonly deadlineMinutes: number;
  readonly rateDirection: "forward" | "reverse";
  readonly showAdvanced: boolean;
  readonly showSettings: boolean;
  readonly tokenSelectSide: "sell" | "buy" | null;
};

export type SwapAction =
  | { readonly type: "SET_SELL_TOKEN"; readonly token: Token }
  | { readonly type: "SET_BUY_TOKEN"; readonly token: Token }
  | { readonly type: "SET_SELL_AMOUNT"; readonly amount: string }
  | { readonly type: "SET_SLIPPAGE"; readonly bps: number; readonly mode?: "preset" | "custom" }
  | { readonly type: "SET_DEADLINE"; readonly minutes: number }
  | { readonly type: "TOGGLE_RATE_DIRECTION" }
  | { readonly type: "TOGGLE_ADVANCED" }
  | { readonly type: "TOGGLE_SETTINGS" }
  | { readonly type: "OPEN_TOKEN_SELECT"; readonly side: "sell" | "buy" }
  | { readonly type: "CLOSE_TOKEN_SELECT" };
