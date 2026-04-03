import { fireEvent, render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { ConversionRate } from "../src/features/swap/conversion-rate";
import { SwapActionButton } from "../src/features/swap/swap-action-button";
import { appChainId, appChainName } from "../src/providers/chain-config";
import { TokenInput } from "../src/features/swap/token-input";
import type { RfqQuote } from "../src/types/quote";
import type { Token } from "../src/types/token";

const {
  executeSwapMock,
  executeSwapMutateMock,
  useTokenBalanceMock,
  useWalletMock,
  useTokenPriceMock,
  switchChainMock,
  useChainIdMock,
} =
  vi.hoisted(() => ({
    executeSwapMock: vi.fn(),
    executeSwapMutateMock: vi.fn(),
    useTokenBalanceMock: vi.fn(),
    useWalletMock: vi.fn(),
    useTokenPriceMock: vi.fn(),
    switchChainMock: vi.fn(),
    useChainIdMock: vi.fn(),
  }));

vi.mock("../src/hooks/use-execute-swap", () => ({
  useExecuteSwap: () => executeSwapMock(),
}));

vi.mock("../src/hooks/use-token-balances", () => ({
  useTokenBalance: (token: Token | null) => useTokenBalanceMock(token),
}));

vi.mock("../src/hooks/use-wallet", () => ({
  useWallet: () => useWalletMock(),
}));

vi.mock("../src/hooks/use-token-prices", () => ({
  useTokenPrice: (address: string | undefined) => useTokenPriceMock(address),
}));

vi.mock("wagmi", () => ({
  useChainId: () => useChainIdMock(),
  useSwitchChain: () => ({
    mutateAsync: switchChainMock,
  }),
}));

const sellToken: Token = {
  address: "0x1111111111111111111111111111111111111111",
  symbol: "RWA",
  name: "RWA",
  decimals: 18,
};

const buyToken: Token = {
  address: "0x2222222222222222222222222222222222222222",
  symbol: "USD",
  name: "USD",
  decimals: 18,
};

function createQuote(): RfqQuote {
  return {
    requestId: "request-id",
    isPreview: false,
    tokenOut: buyToken.address as `0x${string}`,
    amountOut: "1200000000000000000",
    orderInfo: {
      tokenIn: sellToken.address as `0x${string}`,
      amountIn: "1000000000000000000",
      outputs: [
        {
          token: buyToken.address as `0x${string}`,
          amount: "1200000000000000000",
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
          token: buyToken.address as `0x${string}`,
          amount: "1200000000000000000",
        },
      ],
      orderInfo: {
        tokenIn: sellToken.address as `0x${string}`,
        amountIn: "1000000000000000000",
        outputs: [
          {
            token: buyToken.address as `0x${string}`,
            amount: "1200000000000000000",
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
        chainId: 31337,
        verifyingContract: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
      },
      types: {
        PermitWitnessTransferFrom: [],
      },
      value: {},
    },
  };
}

describe("swap controls", () => {
  const wrongChainId = appChainId === 31_337 ? 560_048 : 31_337;

  beforeEach(() => {
    executeSwapMock.mockReset();
    executeSwapMutateMock.mockReset();
    useTokenBalanceMock.mockReset();
    useWalletMock.mockReset();
    useTokenPriceMock.mockReset();

    executeSwapMock.mockReturnValue({
      isPending: false,
      mutate: executeSwapMutateMock,
    });
    useWalletMock.mockReturnValue({
      address: "0x9999999999999999999999999999999999999999",
      isConnected: true,
      login: vi.fn(),
      ready: true,
    });
    switchChainMock.mockReset();
    useChainIdMock.mockReset();
    useChainIdMock.mockReturnValue(appChainId);
    useTokenBalanceMock.mockReturnValue({
      data: { value: 2_000_000_000_000_000_000n },
      isPending: false,
    });
    useTokenPriceMock.mockReturnValue(1);
  });

  it("uses Swap as the ready submit label", () => {
    render(
      <SwapActionButton
        sellToken={sellToken}
        buyToken={buyToken}
        sellAmount="1"
        quote={createQuote()}
        isQuoting={false}
        quoteError={null}
        hasActiveOrder={false}
        onOrderCreated={() => undefined}
      />,
    );

    expect(screen.getByRole("button", { name: "Swap" })).toBeInTheDocument();
  });

  it("offers a chain switch instead of swap when the wallet is on the wrong chain", () => {
    useChainIdMock.mockReturnValue(wrongChainId);

    render(
      <SwapActionButton
        sellToken={sellToken}
        buyToken={buyToken}
        sellAmount="1"
        quote={createQuote()}
        isQuoting={false}
        quoteError={null}
        hasActiveOrder={false}
        onOrderCreated={() => undefined}
      />,
    );

    fireEvent.click(screen.getByRole("button", { name: `Switch to ${appChainName}` }));

    expect(switchChainMock).toHaveBeenCalledWith({ chainId: appChainId });
    expect(executeSwapMutateMock).not.toHaveBeenCalled();
  });

  it("keeps the button green and disabled while an order is pending", () => {
    render(
      <SwapActionButton
        sellToken={sellToken}
        buyToken={buyToken}
        sellAmount="1"
        quote={createQuote()}
        isQuoting={false}
        quoteError={null}
        hasActiveOrder
        onOrderCreated={() => undefined}
      />,
    );

    const button = screen.getByRole("button", { name: "Pending" });
    expect(button).toBeDisabled();
    expect(button.querySelector("svg")).not.toBeNull();
  });

  it("shows the gasless tooltip on hover", () => {
    render(
      <ConversionRate
        sellToken={sellToken}
        buyToken={buyToken}
        sellAmount="1"
        amountOut="1200000000000000000"
        direction="forward"
        onToggleDirection={() => undefined}
        showAdvanced={false}
        onToggleAdvanced={() => undefined}
      />,
    );

    const tooltip = screen.getByRole("tooltip");

    expect(screen.getByText("Gasless")).toBeInTheDocument();
    expect(tooltip).toHaveTextContent(
      "Submit a signature only. The filler sends the onchain transaction and pays the gas.",
    );
  });

  it("keeps the balance row in skeleton state when no balance data is available", () => {
    useTokenBalanceMock.mockReturnValue({
      data: undefined,
      isPending: true,
    });

    const { container } = render(
      <TokenInput
        label="Sell"
        token={sellToken}
        amount=""
        onAmountChange={() => undefined}
        onTokenSelect={() => undefined}
      />,
    );

    expect(screen.getByRole("button", { name: "Use full RWA balance" })).toBeInTheDocument();
    expect(container.querySelector('[aria-hidden="true"]')).not.toBeNull();
  });

  it("freezes the sell field while an order is pending", () => {
    render(
      <TokenInput
        label="Sell"
        token={sellToken}
        amount="1.25"
        disabled
        onAmountChange={() => undefined}
        onTokenSelect={() => undefined}
      />,
    );

    expect(screen.getByRole("textbox", { name: "Sell" })).toHaveAttribute("readonly");
    expect(screen.getByRole("button", { name: "Use full RWA balance" })).toBeDisabled();
  });

  it("uses the full whole-number balance when clicking Max", () => {
    const handleAmountChange = vi.fn();

    useTokenBalanceMock.mockReturnValue({
      data: { value: 2_000_000_000_000_000_000_000_000n },
      isPending: false,
    });

    render(
      <TokenInput
        label="Sell"
        token={sellToken}
        amount=""
        onAmountChange={handleAmountChange}
        onTokenSelect={() => undefined}
      />,
    );

    fireEvent.click(screen.getByRole("button", { name: "Use full RWA balance" }));

    expect(handleAmountChange).toHaveBeenCalledWith("2000000");
  });
});
