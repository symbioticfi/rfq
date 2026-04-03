import { renderHook, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { createQueryClientWrapper } from "./test-utils";

const LOCAL_ACRED_ADDRESS = "0x6F6f570F45833E249e27022648a26F4076F48f78";
const LOCAL_MFONE_ADDRESS = "0xCA8c8688914e0F7096c920146cd0Ad85cD7Ae8b9";
const LOCAL_USDC_ADDRESS = "0xB0f05d25e41FbC2b52013099ED9616f1206Ae21B";
const LOCAL_AUSD_ADDRESS = "0x5FeaeBfB4439F3516c74939A9D04e95AFE82C4ae";
const NATIVE_TOKEN_ADDRESS = "0x0000000000000000000000000000000000000000";

async function loadTokenPricesModule() {
  vi.resetModules();
  vi.doMock("../src/generated/deployment.json", () => ({
    default: {
      environment: "local",
      tokens: {
        input: [
          {
            address: LOCAL_ACRED_ADDRESS,
            symbol: "ACRED",
            name: "Apollo Diversified Credit",
            decimals: 18,
          },
          {
            address: LOCAL_MFONE_ADDRESS,
            symbol: "mF-ONE",
            name: "Midas Fasanara ONE",
            decimals: 18,
          },
        ],
        output: [
          {
            address: LOCAL_USDC_ADDRESS,
            symbol: "USDC",
            name: "USD Coin",
            decimals: 18,
          },
          {
            address: LOCAL_AUSD_ADDRESS,
            symbol: "aUSD",
            name: "Anchored USD",
            decimals: 18,
          },
          {
            address: NATIVE_TOKEN_ADDRESS,
            symbol: "ETH",
            name: "Ether",
            decimals: 18,
          },
        ],
        defaultInput: LOCAL_ACRED_ADDRESS,
        defaultOutput: LOCAL_USDC_ADDRESS,
      },
    },
  }));
  vi.doMock("../src/config/rfq", () => ({
    LEGACY_NATIVE_TOKEN_ADDRESS: NATIVE_TOKEN_ADDRESS,
    NATIVE_TOKEN_ADDRESS,
    RFQ_DEPLOYMENT_ENV: "local",
  }));

  return import("../src/hooks/use-token-prices");
}

describe("useTokenPrice", () => {
  beforeEach(() => {
    vi.resetModules();
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    vi.resetModules();
    vi.doUnmock("../src/config/rfq");
    vi.doUnmock("../src/generated/deployment.json");
  });

  it("resolves mocked local deployment prices by token address", async () => {
    const { resolveMockTokenPrice } = await loadTokenPricesModule();

    expect(resolveMockTokenPrice(LOCAL_ACRED_ADDRESS)).toBe(1090.54);
    expect(resolveMockTokenPrice(LOCAL_MFONE_ADDRESS)).toBe(1.07);
    expect(resolveMockTokenPrice(LOCAL_USDC_ADDRESS)).toBe(1);
    expect(resolveMockTokenPrice(LOCAL_AUSD_ADDRESS)).toBe(1);
    expect(resolveMockTokenPrice(NATIVE_TOKEN_ADDRESS)).toBe(2022.46);
  });

  it("returns mocked local prices without hitting the remote pricing API", async () => {
    const fetchSpy = vi.fn();
    vi.stubGlobal("fetch", fetchSpy);
    const { useTokenPrice } = await loadTokenPricesModule();

    const { result } = renderHook(() => useTokenPrice(LOCAL_ACRED_ADDRESS), {
      wrapper: createQueryClientWrapper(),
    });

    await waitFor(() => expect(result.current).toBe(1090.54));
    expect(fetchSpy).not.toHaveBeenCalled();
  });
});
