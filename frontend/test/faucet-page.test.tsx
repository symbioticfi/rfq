import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { FaucetPage } from "../src/features/faucet/faucet-page";

const { getLocalFaucetMock, fundFromLocalFaucetMock, useWalletMock } = vi.hoisted(() => ({
  getLocalFaucetMock: vi.fn(),
  fundFromLocalFaucetMock: vi.fn(),
  useWalletMock: vi.fn(),
}));

vi.mock("../src/api/client", () => ({
  getLocalFaucet: () => getLocalFaucetMock(),
  fundFromLocalFaucet: (walletAddress: `0x${string}`) => fundFromLocalFaucetMock(walletAddress),
}));

vi.mock("../src/hooks/use-wallet", () => ({
  useWallet: () => useWalletMock(),
}));

vi.mock("../src/config/rfq", async () => {
  const actual = await vi.importActual<typeof import("../src/config/rfq")>("../src/config/rfq");

  return {
    ...actual,
    IS_HOODI_DEPLOYMENT: false,
    IS_LOCAL_DEPLOYMENT: true,
  };
});

function renderPage() {
  const queryClient = new QueryClient({
    defaultOptions: {
      queries: {
        retry: false,
      },
      mutations: {
        retry: false,
      },
    },
  });

  return render(
    <QueryClientProvider client={queryClient}>
      <FaucetPage />
    </QueryClientProvider>,
  );
}

describe("faucet page", () => {
  beforeEach(() => {
    getLocalFaucetMock.mockReset();
    fundFromLocalFaucetMock.mockReset();
    useWalletMock.mockReset();

    useWalletMock.mockReturnValue({
      address: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
      isConnected: true,
    });
    getLocalFaucetMock.mockResolvedValue({
      requestId: "request-1",
      assets: [
        {
          token: "0x99bbA657f2BbC93c02D617f8bA121cB8Fc104Acf",
          symbol: "ACRED",
          name: "Apollo Diversified Credit",
          decimals: 18,
          amount: "1000000000000000000000000",
          kind: "erc20",
        },
        {
          token: "0x0E801D84Fa97b50751Dbf25036d067dCf18858bF",
          symbol: "USDC",
          name: "USD Coin",
          decimals: 18,
          amount: "1000000000000000000000000",
          kind: "erc20",
        },
        {
          token: "0x0000000000000000000000000000000000000000",
          symbol: "ETH",
          name: "Ether",
          decimals: 18,
          amount: "100000000000000000",
          kind: "native",
        },
      ],
    });
    fundFromLocalFaucetMock.mockResolvedValue({
      requestId: "request-2",
      walletAddress: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
      fundedAssets: [],
    });
  });

  it("renders faucet assets and prefills the connected wallet", async () => {
    renderPage();

    expect(await screen.findByText("Local faucet")).toBeInTheDocument();
    expect(await screen.findByLabelText("Copy ACRED address")).toBeInTheDocument();
    expect(await screen.findByLabelText("Copy USDC address")).toBeInTheDocument();
    expect(await screen.findByLabelText("Copy ETH address")).toBeInTheDocument();
    expect(screen.getByLabelText("Recipient wallet address")).toHaveValue("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
  });

  it("funds the entered wallet address", async () => {
    renderPage();

    await screen.findByLabelText("Copy ACRED address");

    const input = screen.getByLabelText("Recipient wallet address");
    fireEvent.change(input, {
      target: { value: "0xc3bf069d557F33c0d24fd119Dd8Fc7B4F448A990" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Fund" }));

    await waitFor(() => {
      expect(fundFromLocalFaucetMock).toHaveBeenCalledWith("0xc3bf069d557F33c0d24fd119Dd8Fc7B4F448A990");
    });
  });
});
