import { renderHook } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { useExecuteSwap } from "../src/hooks/use-execute-swap";
import { appChainId } from "../src/providers/chain-config";
import type { CheckApprovalResponse, RfqQuote } from "../src/types/quote";
import { createTestQueryClient, createQueryClientWrapper } from "./test-utils";

const {
  checkApprovalMock,
  submitOrderMock,
  waitForTransactionReceiptMock,
  useChainIdMock,
  sendTransactionMutateAsyncMock,
  signTypedDataMutateAsyncMock,
} = vi.hoisted(() => ({
  checkApprovalMock:
    vi.fn<(input: Parameters<typeof import("../src/api/client").checkApproval>[0]) => Promise<CheckApprovalResponse>>(),
  submitOrderMock: vi.fn(),
  waitForTransactionReceiptMock: vi.fn(),
  useChainIdMock: vi.fn(),
  sendTransactionMutateAsyncMock: vi.fn(),
  signTypedDataMutateAsyncMock: vi.fn(),
}));

vi.mock("../src/api/client", () => ({
  checkApproval: checkApprovalMock,
  submitOrder: submitOrderMock,
}));

vi.mock("../src/hooks/use-wallet", () => ({
  useWallet: () => ({
    address: "0x9999999999999999999999999999999999999999",
    isConnected: true,
  }),
}));

vi.mock("wagmi", () => ({
  useChainId: () => useChainIdMock(),
  usePublicClient: () => ({
    waitForTransactionReceipt: waitForTransactionReceiptMock,
  }),
  useSendTransaction: () => ({
    mutateAsync: sendTransactionMutateAsyncMock,
  }),
  useSignTypedData: () => ({
    mutateAsync: signTypedDataMutateAsyncMock,
  }),
}));

function createQuote(): RfqQuote {
  return {
    requestId: "request-id",
    isPreview: false,
    tokenOut: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    amountOut: "1000000",
    orderInfo: {
      tokenIn: "0x1111111111111111111111111111111111111111",
      amountIn: "1000000",
      outputs: [
        {
          token: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
          amount: "1000000",
          recipient: "0x9999999999999999999999999999999999999999",
        },
      ],
      deadline: 1_800_000_000,
      nonce: "0x01",
    },
    quote: {
      quoteId: "quote-id",
      slippageTolerance: 0.5,
      aggregatedOutputs: [
        {
          token: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
          amount: "1000000",
        },
      ],
      orderInfo: {
        tokenIn: "0x1111111111111111111111111111111111111111",
        amountIn: "1000000",
        outputs: [
          {
            token: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
            amount: "1000000",
            recipient: "0x9999999999999999999999999999999999999999",
          },
        ],
        deadline: 1_800_000_000,
        nonce: "0x01",
      },
    },
    permitData: {
      domain: {
        name: "Permit2",
        chainId: appChainId,
        verifyingContract: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
      },
      types: {
        PermitWitnessTransferFrom: [],
      },
      value: {
        permitted: {
          token: "0x1111111111111111111111111111111111111111",
          amount: "1000000",
        },
      },
    },
  };
}

describe("useExecuteSwap", () => {
  beforeEach(() => {
    checkApprovalMock.mockReset();
    submitOrderMock.mockReset();
    waitForTransactionReceiptMock.mockReset();
    useChainIdMock.mockReset();
    sendTransactionMutateAsyncMock.mockReset();
    signTypedDataMutateAsyncMock.mockReset();

    sendTransactionMutateAsyncMock.mockResolvedValue("0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    signTypedDataMutateAsyncMock.mockResolvedValue("0xbb");
    waitForTransactionReceiptMock.mockResolvedValue({ status: "success" });
    submitOrderMock.mockResolvedValue({
      requestId: "request-id",
      orderId: "order-id",
      orderStatus: "open",
    });
    useChainIdMock.mockReturnValue(appChainId);
  });

  it("runs approval, signing, and order submission", async () => {
    checkApprovalMock.mockResolvedValue({
      requestId: "request-id",
      approval: {
        to: "0x1111111111111111111111111111111111111111",
        data: "0xabcdef",
        value: "0",
      },
      cancel: null,
    });

    const queryClient = createTestQueryClient();
    const onOrderCreated = vi.fn();
    const { result } = renderHook(() => useExecuteSwap(), {
      wrapper: createQueryClientWrapper(queryClient),
    });

    const response = await result.current.mutateAsync({
      quote: createQuote(),
      onOrderCreated,
    });

    expect(checkApprovalMock).toHaveBeenCalledWith({
      walletAddress: "0x9999999999999999999999999999999999999999",
      chainId: appChainId,
      token: "0x1111111111111111111111111111111111111111",
      amount: "1000000",
    });
    expect(sendTransactionMutateAsyncMock).toHaveBeenCalledTimes(1);
    expect(signTypedDataMutateAsyncMock).toHaveBeenCalledTimes(1);
    expect(submitOrderMock).toHaveBeenCalledWith({
      quote: createQuote().quote,
      signature: "0xbb",
    });
    expect(onOrderCreated).toHaveBeenCalledWith("order-id");
    expect(response).toMatchObject({ orderId: "order-id", orderStatus: "open" });
  });

  it("retries through a refreshed quote prompt on 409", async () => {
    checkApprovalMock.mockResolvedValue({
      requestId: "request-id",
      approval: null,
      cancel: null,
    });
    const conflict = new Error("Quote cannot be honored anymore") as Error & { status: number };
    conflict.status = 409;
    submitOrderMock.mockRejectedValue(conflict);

    const queryClient = createTestQueryClient();
    const invalidateSpy = vi.spyOn(queryClient, "invalidateQueries");
    const { result } = renderHook(() => useExecuteSwap(), {
      wrapper: createQueryClientWrapper(queryClient),
    });

    await expect(
      result.current.mutateAsync({
        quote: createQuote(),
        onOrderCreated: vi.fn(),
      }),
    ).rejects.toThrow("Quote expired. Review the refreshed quote and sign again.");

    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["rfq-quote"] });
    expect(sendTransactionMutateAsyncMock).not.toHaveBeenCalled();
  });

  it("fails before submission on the wrong chain", async () => {
    useChainIdMock.mockReturnValue(appChainId + 1);

    const queryClient = createTestQueryClient();
    const { result } = renderHook(() => useExecuteSwap(), {
      wrapper: createQueryClientWrapper(queryClient),
    });

    await expect(
      result.current.mutateAsync({
        quote: createQuote(),
        onOrderCreated: vi.fn(),
      }),
    ).rejects.toThrow("Switch to");

    expect(checkApprovalMock).not.toHaveBeenCalled();
    expect(sendTransactionMutateAsyncMock).not.toHaveBeenCalled();
  });
});
