import { renderHook, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { RFQ_OUTPUT_TOKENS } from "../src/config/rfq";
import { useActiveOrder } from "../src/hooks/use-active-order";
import { appChainId } from "../src/providers/chain-config";
import { formatTokenAmountAdaptive } from "../src/utils/format-number";
import { createTestQueryClient, createQueryClientWrapper } from "./test-utils";

const { getTrackedOrderMock, toastSuccessMock, toastErrorMock } = vi.hoisted(() => ({
  getTrackedOrderMock: vi.fn(),
  toastSuccessMock: vi.fn(),
  toastErrorMock: vi.fn(),
}));

vi.mock("../src/api/client", () => ({
  getTrackedOrder: getTrackedOrderMock,
}));

vi.mock("sonner", () => ({
  toast: {
    success: toastSuccessMock,
    error: toastErrorMock,
  },
}));

function createStorageMock() {
  const storage = new Map<string, string>();

  return {
    getItem: (key: string) => storage.get(key) ?? null,
    setItem: (key: string, value: string) => {
      storage.set(key, value);
    },
    removeItem: (key: string) => {
      storage.delete(key);
    },
    clear: () => {
      storage.clear();
    },
  };
}

describe("useActiveOrder", () => {
  beforeEach(() => {
    getTrackedOrderMock.mockReset();
    toastSuccessMock.mockReset();
    toastErrorMock.mockReset();
    Object.defineProperty(window, "localStorage", {
      value: createStorageMock(),
      configurable: true,
    });
    window.localStorage.clear();
    vi.useRealTimers();
  });

  it("resumes a persisted order for the matching wallet", async () => {
    window.localStorage.setItem(
      `rfq-active-order:${appChainId}:0x9999999999999999999999999999999999999999`,
      JSON.stringify({
        chainId: appChainId,
        orderId: "order-id",
        walletAddress: "0x9999999999999999999999999999999999999999",
      }),
    );
    getTrackedOrderMock.mockResolvedValue({
      orderId: "order-id",
      quoteId: "quote-id",
      orderStatus: "open",
      displayStatus: "Pending",
      txHash: null,
      input: {
        token: "0x1111111111111111111111111111111111111111",
        amount: "1000000",
      },
      outputs: [],
      settledAmounts: [],
    });

    const { result } = renderHook(() => useActiveOrder("0x9999999999999999999999999999999999999999"), {
      wrapper: createQueryClientWrapper(),
    });

    await waitFor(() => expect(result.current.activeOrder?.orderId).toBe("order-id"));
    expect(getTrackedOrderMock).toHaveBeenCalledWith("order-id");
    expect(result.current.hasActiveOrder).toBe(true);
  });

  it("hydrates a persisted pending snapshot before the refetch completes", () => {
    window.localStorage.setItem(
      `rfq-active-order:${appChainId}:0x9999999999999999999999999999999999999999`,
      JSON.stringify({
        chainId: appChainId,
        orderId: "order-id",
        order: {
          orderId: "order-id",
          quoteId: "quote-id",
          orderStatus: "open",
          displayStatus: "Pending",
          txHash: null,
          input: {
            token: "0x1111111111111111111111111111111111111111",
            amount: "1250000000000000000",
          },
          outputs: [
            {
              token: "0x2222222222222222222222222222222222222222",
              amount: "1500000000000000000",
              recipient: "0x9999999999999999999999999999999999999999",
            },
          ],
          settledAmounts: [],
        },
        walletAddress: "0x9999999999999999999999999999999999999999",
      }),
    );
    getTrackedOrderMock.mockImplementation(() => new Promise(() => undefined));

    const { result } = renderHook(() => useActiveOrder("0x9999999999999999999999999999999999999999"), {
      wrapper: createQueryClientWrapper(),
    });

    expect(result.current.activeOrder?.orderId).toBe("order-id");
    expect(result.current.activeOrder?.input.amount).toBe("1250000000000000000");
    expect(result.current.hasActiveOrder).toBe(true);
  });

  it("updates to terminal status, clears persistence, and drops the active panel state", async () => {
    window.localStorage.setItem(
      `rfq-active-order:${appChainId}:0x9999999999999999999999999999999999999999`,
      JSON.stringify({
        chainId: appChainId,
        orderId: "order-id",
        walletAddress: "0x9999999999999999999999999999999999999999",
      }),
    );

    getTrackedOrderMock
      .mockResolvedValueOnce({
        orderId: "order-id",
        quoteId: "quote-id",
        orderStatus: "open",
        displayStatus: "Pending",
        txHash: null,
        input: {
          token: "0x1111111111111111111111111111111111111111",
          amount: "1000000",
        },
        outputs: [],
        settledAmounts: [],
      })
      .mockResolvedValueOnce({
        orderId: "order-id",
        quoteId: "quote-id",
        orderStatus: "filled",
        displayStatus: "Filled",
        txHash: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        input: {
          token: "0x1111111111111111111111111111111111111111",
          amount: "1000000",
        },
        outputs: [],
        settledAmounts: [],
      });

    const { result } = renderHook(() => useActiveOrder("0x9999999999999999999999999999999999999999"), {
      wrapper: createQueryClientWrapper(),
    });

    await waitFor(() => expect(result.current.activeOrder?.displayStatus).toBe("Pending"));
    await result.current.refetch();
    await waitFor(() => expect(result.current.activeOrder).toBeNull());
    expect(
      window.localStorage.getItem(`rfq-active-order:${appChainId}:0x9999999999999999999999999999999999999999`),
    ).toBeNull();
    expect(result.current.hasActiveOrder).toBe(false);
  });

  it("invalidates token balances and includes the received output amount when an order fills", async () => {
    const outputToken = RFQ_OUTPUT_TOKENS[0];
    if (!outputToken) {
      throw new Error("Expected at least one RFQ output token in deployment config");
    }

    window.localStorage.setItem(
      `rfq-active-order:${appChainId}:0x9999999999999999999999999999999999999999`,
      JSON.stringify({
        chainId: appChainId,
        orderId: "order-id",
        walletAddress: "0x9999999999999999999999999999999999999999",
      }),
    );

    getTrackedOrderMock
      .mockResolvedValueOnce({
        orderId: "order-id",
        quoteId: "quote-id",
        orderStatus: "open",
        displayStatus: "Pending",
        txHash: null,
        input: {
          token: "0x1111111111111111111111111111111111111111",
          amount: "1000000",
        },
        outputs: [
          {
            token: outputToken.address as `0x${string}`,
            amount: "1234500",
            recipient: "0x9999999999999999999999999999999999999999",
          },
        ],
        settledAmounts: [],
      })
      .mockResolvedValueOnce({
        orderId: "order-id",
        quoteId: "quote-id",
        orderStatus: "filled",
        displayStatus: "Filled",
        txHash: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        input: {
          token: "0x1111111111111111111111111111111111111111",
          amount: "1000000",
        },
        outputs: [
          {
            token: outputToken.address as `0x${string}`,
            amount: "1234500",
            recipient: "0x9999999999999999999999999999999999999999",
          },
        ],
        settledAmounts: [
          {
            token: outputToken.address as `0x${string}`,
            amount: "1234500",
            recipient: "0x9999999999999999999999999999999999999999",
            txHash: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          },
        ],
      });

    const queryClient = createTestQueryClient();
    const invalidateSpy = vi.spyOn(queryClient, "invalidateQueries");
    const { result } = renderHook(() => useActiveOrder("0x9999999999999999999999999999999999999999"), {
      wrapper: createQueryClientWrapper(queryClient),
    });

    await waitFor(() => expect(result.current.activeOrder?.displayStatus).toBe("Pending"));
    await result.current.refetch();

    await waitFor(() =>
      expect(toastSuccessMock).toHaveBeenCalledWith(
        `Order filled: received ${formatTokenAmountAdaptive("1234500", outputToken.decimals)} ${outputToken.symbol}`,
      ),
    );
    expect(invalidateSpy).toHaveBeenCalledWith({
      queryKey: ["token-balance", appChainId, "0x9999999999999999999999999999999999999999"],
    });
  });
});
