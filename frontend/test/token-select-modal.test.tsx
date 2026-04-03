import { fireEvent, render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { TokenSelectModal } from "../src/features/token-select/token-select-modal";

const { useImportableTokenMock } = vi.hoisted(() => ({
  useImportableTokenMock: vi.fn(),
}));

vi.mock("../src/hooks/use-importable-token", () => ({
  useImportableToken: useImportableTokenMock,
}));

vi.mock("../src/hooks/use-token-balances", () => ({
  useTokenBalance: () => ({
    data: null,
  }),
}));

describe("TokenSelectModal", () => {
  beforeEach(() => {
    useImportableTokenMock.mockReset();
    useImportableTokenMock.mockReturnValue({
      isAddressQuery: true,
      isKnownToken: false,
      resolvedToken: {
        address: "0x9999999999999999999999999999999999999999",
        symbol: "IMPT",
        name: "Imported Token",
        decimals: 18,
      },
      isLoading: false,
    });
  });

  it("does not allow imported tokens on the input side", () => {
    render(
      <TokenSelectModal open onClose={() => undefined} onSelect={() => undefined} tokens={[]} allowImport={false} />,
    );

    fireEvent.change(screen.getByRole("textbox", { name: "Search tokens" }), {
      target: { value: "0x9999999999999999999999999999999999999999" },
    });

    expect(screen.queryByText("IMPT")).not.toBeInTheDocument();
  });

  it("allows imported tokens on the output side", () => {
    render(<TokenSelectModal open onClose={() => undefined} onSelect={() => undefined} tokens={[]} allowImport />);

    fireEvent.change(screen.getByRole("textbox", { name: "Search tokens" }), {
      target: { value: "0x9999999999999999999999999999999999999999" },
    });

    expect(screen.getByText("IMPT")).toBeInTheDocument();
  });
});
