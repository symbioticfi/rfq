import { useQuery } from "@tanstack/react-query";
import { parseUnits } from "viem";

import { requestQuote } from "../api/client";
import { PREVIEW_SWAPPER_ADDRESS } from "../config/rfq";
import { appChainId } from "../providers/chain-config";
import type { Token } from "../types/token";
import { useDebounce } from "./use-debounce";
import { useWallet } from "./use-wallet";

type UseQuoteParams = {
  readonly sellToken: Token | null;
  readonly buyToken: Token | null;
  readonly sellAmount: string;
  readonly slippageBps: number;
  readonly paused?: boolean;
};

function toAmountInRaw(amount: string, decimals: number) {
  if (!amount || Number.parseFloat(amount) <= 0) {
    return null;
  }

  try {
    return parseUnits(amount, decimals).toString();
  } catch {
    return null;
  }
}

function bpsToSlippageTolerance(bps: number) {
  return bps / 100;
}

/**
 * @dev Requests a quote as the user types, using a placeholder preview address before connect.
 * @param params Current swap-form state.
 * @returns A TanStack query with the normalized RFQ quote.
 */
export function useQuote({ sellToken, buyToken, sellAmount, slippageBps, paused = false }: UseQuoteParams) {
  const debouncedAmount = useDebounce(sellAmount, 300);
  const { address } = useWallet();

  const amountInRaw = sellToken ? toAmountInRaw(debouncedAmount, sellToken.decimals) : null;
  const hasValidInput = Boolean(!paused && sellToken && buyToken && amountInRaw && BigInt(amountInRaw) > 0n);
  const swapper = (address ?? PREVIEW_SWAPPER_ADDRESS) as `0x${string}`;
  const isPreview = !address;

  return useQuery({
    queryKey: ["rfq-quote", appChainId, sellToken?.address, buyToken?.address, amountInRaw, slippageBps, swapper],
    queryFn: async ({ signal }) => {
      if (!sellToken || !buyToken || !amountInRaw) {
        return null;
      }

      return requestQuote(
        {
          tokenInChainId: appChainId,
          tokenOutChainId: appChainId,
          tokenIn: sellToken.address as `0x${string}`,
          tokenOut: buyToken.address as `0x${string}`,
          type: "EXACT_INPUT",
          amount: amountInRaw,
          swapper,
          slippageTolerance: bpsToSlippageTolerance(slippageBps),
          routingPreference: "BEST_PRICE",
          permitAmount: "EXACT",
          outputs: [
            {
              token: buyToken.address as `0x${string}`,
              recipient: swapper,
            },
          ],
        },
        {
          signal,
          isPreview,
        },
      );
    },
    enabled: hasValidInput,
    staleTime: 0,
    refetchInterval: hasValidInput ? 15_000 : false,
    retry: false,
  });
}
