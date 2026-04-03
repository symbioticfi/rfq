import { useReducer } from "react";

import { DEFAULT_INPUT_TOKEN, DEFAULT_OUTPUT_TOKEN, DEFAULT_SLIPPAGE_BPS } from "../config/rfq";
import type { SwapAction, SwapState } from "../types/swap";

const INITIAL_STATE: SwapState = {
  sellToken: DEFAULT_INPUT_TOKEN,
  buyToken: DEFAULT_OUTPUT_TOKEN,
  sellAmount: "",
  slippageBps: DEFAULT_SLIPPAGE_BPS,
  slippageMode: "preset",
  deadlineMinutes: 30,
  rateDirection: "forward",
  showAdvanced: false,
  showSettings: false,
  tokenSelectSide: null,
};

function swapReducer(state: SwapState, action: SwapAction): SwapState {
  switch (action.type) {
    case "SET_SELL_TOKEN":
      return {
        ...state,
        sellToken: action.token,
        tokenSelectSide: null,
      };
    case "SET_BUY_TOKEN":
      return {
        ...state,
        buyToken: action.token,
        tokenSelectSide: null,
      };
    case "SET_SELL_AMOUNT":
      return { ...state, sellAmount: action.amount };
    case "SET_SLIPPAGE":
      return {
        ...state,
        slippageBps: action.bps,
        slippageMode: action.mode ?? state.slippageMode,
      };
    case "SET_DEADLINE":
      return { ...state, deadlineMinutes: action.minutes };
    case "TOGGLE_RATE_DIRECTION":
      return {
        ...state,
        rateDirection: state.rateDirection === "forward" ? "reverse" : "forward",
      };
    case "TOGGLE_ADVANCED":
      return { ...state, showAdvanced: !state.showAdvanced };
    case "TOGGLE_SETTINGS":
      return { ...state, showSettings: !state.showSettings };
    case "OPEN_TOKEN_SELECT":
      return { ...state, tokenSelectSide: action.side };
    case "CLOSE_TOKEN_SELECT":
      return { ...state, tokenSelectSide: null };
  }
}

export function useSwapState() {
  return useReducer(swapReducer, INITIAL_STATE);
}
