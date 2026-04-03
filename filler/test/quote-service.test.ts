import { describe, expect, it } from "vitest";

import { readPermissionedVaultInventories } from "../src/services/strategy-helpers";
import { createMemoryRepositories, createQuoteService, createSolverQuoteRequest } from "./support";
import { addresses, createMockPublicClient } from "./support";

describe("QuoteService", () => {
  it("returns null when no collateral group can fully cover the requested input", async () => {
    const service = createQuoteService({
      publicClientConfig: {
        maxAssetsByVault: {
          "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa": 1n,
        },
      },
    });

    const response = await service.quote(
      createSolverQuoteRequest({
        vaults: [
          {
            vault: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            collateral: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            collateralDecimals: 6,
            maxCollateralOut: "1",
            maxRate: "1000000",
          },
        ],
      }),
    );

    expect(response).toBeNull();
  });

  it("quotes the direct passthrough path when collateral already matches tokenOut", async () => {
    const { state, repositories } = createMemoryRepositories();
    const service = createQuoteService({ repositories });

    const response = await service.quote(createSolverQuoteRequest());

    expect(response).toMatchObject({
      amountIn: "100000000000000000000",
      amountOut: "108000000",
    });
    expect(state.strategies).toHaveLength(1);
    expect(state.strategies[0]?.collateral).toBe("0x4444444444444444444444444444444444444444");
    expect(state.strategies[0]?.collateralAmountOut).toBe("108000000");
    expect(state.strategies[0]?.quotedAmountOut).toBe("108000000");
  });

  it("accepts lowercased backend tokenOut addresses when chain reads return checksum variants", async () => {
    const { repositories } = createMemoryRepositories();
    const service = createQuoteService({ repositories });

    const response = await service.quote(
      createSolverQuoteRequest({
        tokenOut: "0x4444444444444444444444444444444444444444",
        vaults: [
          {
            vault: "0x6666666666666666666666666666666666666666",
            collateral: "0x4444444444444444444444444444444444444444",
            collateralDecimals: 6,
            maxCollateralOut: "150000000",
            maxRate: "1200000000000000000",
          },
        ],
      }),
    );

    expect(response).not.toBeNull();
    expect(response?.tokenOut).toBe("0x4444444444444444444444444444444444444444");
  });

  it("supports overriding the quote discount percentage from env config", async () => {
    const service = createQuoteService({
      env: {
        quoteDiscountPercent: 5,
        quoteDiscountBps: 500,
      },
    });

    const response = await service.quote(createSolverQuoteRequest());

    expect(response?.amountOut).toBe("114000000");
  });

  it("uses the guaranteed public discount rate when it beats the private env discount", async () => {
    const { state, repositories } = createMemoryRepositories();
    const service = createQuoteService({ repositories });

    const response = await service.quote(
      createSolverQuoteRequest({
        vaults: [
          {
            vault: addresses.vaultA,
            collateral: addresses.usdc,
            collateralDecimals: 6,
            maxCollateralOut: "150000000",
            maxRate: "1200000000000000000",
            discountId: null,
          },
          {
            vault: addresses.vaultB,
            collateral: addresses.usdc,
            collateralDecimals: 6,
            maxCollateralOut: "150000000",
            maxRate: "1140000000000000000",
            discountId: `0x${"de".repeat(32)}`,
          },
        ],
      }),
    );

    expect(response?.amountOut).toBe("114000000");
    expect(state.strategies[0]?.legs).toEqual([
      expect.objectContaining({
        vault: addresses.vaultB,
        amountIn: "100000000000000000000",
        amountOut: "114000000",
        discountId: `0x${"de".repeat(32)}`,
      }),
    ]);
  });

  it("returns null when discounted oracle pricing is still above the vault maxRate", async () => {
    const service = createQuoteService({
      env: {
        quoteDiscountPercent: 5,
        quoteDiscountBps: 500,
      },
    });

    const response = await service.quote(
      createSolverQuoteRequest({
        vaults: [
          {
            vault: "0x6666666666666666666666666666666666666666",
            collateral: "0x4444444444444444444444444444444444444444",
            collateralDecimals: 6,
            maxCollateralOut: "150000000",
            maxRate: "1100000000000000000",
            discountId: null,
          },
        ],
      }),
    );

    expect(response).toBeNull();
  });

  it("combines public and private liquidity at their own effective rates to maximize quote output", async () => {
    const { state, repositories } = createMemoryRepositories();
    const service = createQuoteService({ repositories });

    const response = await service.quote(
      createSolverQuoteRequest({
        vaults: [
          {
            vault: addresses.vaultA,
            collateral: addresses.usdc,
            collateralDecimals: 6,
            maxCollateralOut: "150000000",
            maxRate: "1200000000000000000",
            discountId: null,
          },
          {
            vault: addresses.vaultB,
            collateral: addresses.usdc,
            collateralDecimals: 6,
            maxCollateralOut: "57000000",
            maxRate: "1140000000000000000",
            discountId: `0x${"ef".repeat(32)}`,
          },
        ],
      }),
    );

    expect(response?.amountOut).toBe("111000000");
    expect(state.strategies[0]?.legs).toEqual([
      expect.objectContaining({
        vault: addresses.vaultB,
        amountIn: "50000000000000000000",
        amountOut: "57000000",
        discountId: `0x${"ef".repeat(32)}`,
      }),
      expect.objectContaining({
        vault: addresses.vaultA,
        amountIn: "50000000000000000000",
        amountOut: "54000000",
        discountId: null,
      }),
    ]);
  });

  it("preserves discount-backed legs from backend inventory hints", async () => {
    const { state, repositories } = createMemoryRepositories();
    const service = createQuoteService({ repositories });

    const response = await service.quote(
      createSolverQuoteRequest({
        vaults: [
          {
            vault: "0x6666666666666666666666666666666666666666",
            collateral: "0x4444444444444444444444444444444444444444",
            collateralDecimals: 6,
            maxCollateralOut: "150000000",
            maxRate: "1200000000000000000",
            discountId: `0x${"de".repeat(32)}`,
          },
        ],
      }),
    );

    expect(response).not.toBeNull();
    expect(state.strategies[0]?.legs).toEqual([
      expect.objectContaining({
        vault: "0x6666666666666666666666666666666666666666",
        discountId: `0x${"de".repeat(32)}`,
      }),
    ]);
  });

  it("falls back to sequential reads when multicall is unavailable for permissioned inventory checks", async () => {
    const tokenDecimals = new Map<`0x${string}`, number>();

    const inventories = await readPermissionedVaultInventories({
      publicClient: createMockPublicClient({
        multicallFailureMode: "all-fail",
      }),
      adapterAddress: addresses.adapter,
      curatorRegistryAddress: addresses.router,
      executorAddress: addresses.executor,
      tokenIn: addresses.tokenIn,
      tokenDecimals,
      vaults: [
        {
          vault: addresses.vaultA,
          collateralHint: addresses.usdc,
          collateralDecimalsHint: 6,
        },
      ],
    });

    expect(inventories).toEqual([
      expect.objectContaining({
        vault: addresses.vaultA,
        collateral: addresses.usdc,
        collateralDecimals: 6,
      }),
    ]);
  });

  it("returns null when no vault collateral matches tokenOut", async () => {
    const { state, repositories } = createMemoryRepositories();
    const service = createQuoteService({ repositories });

    const response = await service.quote(
      createSolverQuoteRequest({
        tokenOut: "0x0000000000000000000000000000000000000000",
        vaults: [
          {
            vault: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            collateral: "0x4444444444444444444444444444444444444444",
            collateralDecimals: 6,
            maxCollateralOut: "120000000",
            maxRate: "1200000000000000000",
          },
          {
            vault: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            collateral: "0x5555555555555555555555555555555555555555",
            collateralDecimals: 18,
            maxCollateralOut: "2000000000000000000",
            maxRate: "20000000000000000",
          },
        ],
      }),
    );

    expect(response).toBeNull();
    expect(state.strategies).toHaveLength(0);
  });
});
