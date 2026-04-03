import { renderHook, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { PREVIEW_SWAPPER_ADDRESS } from "../src/config/rfq";
import { useQuote } from "../src/hooks/use-quote";
import type { PublicQuoteRequest } from "../src/types/quote";
import { createQueryClientWrapper } from "./test-utils";

let walletAddress: `0x${string}` | undefined;
const { requestQuoteMock } = vi.hoisted(() => ({
  requestQuoteMock:
    vi.fn<
      (
        request: PublicQuoteRequest,
        options?: { readonly signal?: AbortSignal; readonly isPreview?: boolean },
      ) => Promise<unknown>
    >(),
}));

vi.mock("../src/api/client", () => ({
  requestQuote: requestQuoteMock,
}));

vi.mock("../src/hooks/use-wallet", () => ({
  useWallet: () => ({
    address: walletAddress,
  }),
}));

describe("useQuote", () => {
  beforeEach(() => {
    walletAddress = undefined;
    requestQuoteMock.mockReset();
    requestQuoteMock.mockResolvedValue(null);
  });

  it("uses the preview placeholder and converts bps to percent before connect", async () => {
    renderHook(
      () =>
        useQuote({
          sellToken: {
            address: "0x1111111111111111111111111111111111111111",
            symbol: "ACRED",
            name: "Apollo Diversified Credit",
            decimals: 6,
          },
          buyToken: {
            address: "0x0000000000000000000000000000000000000000",
            symbol: "ETH",
            name: "Ether",
            decimals: 18,
          },
          sellAmount: "123.45",
          slippageBps: 50,
        }),
      {
        wrapper: createQueryClientWrapper(),
      },
    );

    await waitFor(() => expect(requestQuoteMock).toHaveBeenCalledTimes(1));

    expect(requestQuoteMock).toHaveBeenCalledWith(
      expect.objectContaining({
        swapper: PREVIEW_SWAPPER_ADDRESS,
        slippageTolerance: 0.5,
        outputs: [
          {
            token: "0x0000000000000000000000000000000000000000",
            recipient: PREVIEW_SWAPPER_ADDRESS,
          },
        ],
        routingPreference: "BEST_PRICE",
        permitAmount: "EXACT",
      }),
      expect.objectContaining({ isPreview: true }),
    );
  });

  it("requotes with the real connected wallet address", async () => {
    const wrapper = createQueryClientWrapper();
    const baseInput = {
      sellToken: {
        address: "0x1111111111111111111111111111111111111111",
        symbol: "ACRED",
        name: "Apollo Diversified Credit",
        decimals: 6,
      },
      buyToken: {
        address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
        symbol: "USDC",
        name: "USDC",
        decimals: 6,
      },
      sellAmount: "10",
      slippageBps: 100,
    } as const;

    const { rerender } = renderHook(() => useQuote(baseInput), { wrapper });

    await waitFor(() => expect(requestQuoteMock).toHaveBeenCalledTimes(1));
    expect(requestQuoteMock.mock.calls[0]?.[0].swapper).toBe(PREVIEW_SWAPPER_ADDRESS);

    walletAddress = "0x9999999999999999999999999999999999999999";
    rerender();

    await waitFor(() => expect(requestQuoteMock).toHaveBeenCalledTimes(2));
    expect(requestQuoteMock.mock.calls[1]?.[0]).toMatchObject({
      swapper: walletAddress,
      outputs: [
        {
          token: baseInput.buyToken.address,
          recipient: walletAddress,
        },
      ],
      slippageTolerance: 1,
    });
    expect(requestQuoteMock.mock.calls[1]?.[1]).toMatchObject({ isPreview: false });
  });

  it("does not quote while an active order is pending", async () => {
    renderHook(
      () =>
        useQuote({
          sellToken: {
            address: "0x1111111111111111111111111111111111111111",
            symbol: "ACRED",
            name: "Apollo Diversified Credit",
            decimals: 6,
          },
          buyToken: {
            address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
            symbol: "USDC",
            name: "USDC",
            decimals: 6,
          },
          sellAmount: "10",
          slippageBps: 100,
          paused: true,
        }),
      {
        wrapper: createQueryClientWrapper(),
      },
    );

    await new Promise((resolve) => setTimeout(resolve, 350));
    expect(requestQuoteMock).not.toHaveBeenCalled();
  });
});
