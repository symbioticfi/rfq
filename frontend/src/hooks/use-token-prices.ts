import { useQuery } from "@tanstack/react-query";

import deployment from "../generated/deployment.json";
import { LEGACY_NATIVE_TOKEN_ADDRESS, NATIVE_TOKEN_ADDRESS, RFQ_DEPLOYMENT_ENV } from "../config/rfq";

const DEFILLAMA_BASE = "https://coins.llama.fi/prices/current";
const WETH_ADDRESS = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
const MOCK_SYMBOL_PRICES_USD = {
  acred: 1_090.54,
  ausd: 1,
  eth: 2_022.46,
  "mf-one": 1.07,
  usdc: 1,
} as const;

type DefiLlamaResponse = {
  readonly coins: Record<
    string,
    {
      readonly price: number;
      readonly symbol: string;
      readonly decimals: number;
      readonly timestamp: number;
      readonly confidence: number;
    }
  >;
};

/** Map our token address to a DefiLlama coin ID. Native ETH uses WETH price. */
function toCoinId(address: string): string {
  const addr = address === NATIVE_TOKEN_ADDRESS || address === LEGACY_NATIVE_TOKEN_ADDRESS ? WETH_ADDRESS : address;

  return `ethereum:${addr}`;
}

function normalizeAddress(address: string) {
  return address.toLowerCase();
}

function buildMockPriceMap() {
  if (RFQ_DEPLOYMENT_ENV === "mainnet") {
    return {};
  }

  const mockPrices: Record<string, number> = {};
  const deploymentTokens = [...deployment.tokens.input, ...deployment.tokens.output];

  for (const token of deploymentTokens) {
    const mockPrice = MOCK_SYMBOL_PRICES_USD[token.symbol.toLowerCase() as keyof typeof MOCK_SYMBOL_PRICES_USD];
    if (mockPrice === undefined) {
      continue;
    }

    mockPrices[normalizeAddress(token.address)] = mockPrice;
  }

  if (mockPrices[normalizeAddress(NATIVE_TOKEN_ADDRESS)] !== undefined) {
    mockPrices[normalizeAddress(LEGACY_NATIVE_TOKEN_ADDRESS)] = mockPrices[normalizeAddress(NATIVE_TOKEN_ADDRESS)];
  }

  return mockPrices;
}

const MOCK_TOKEN_PRICES = buildMockPriceMap();

export function resolveMockTokenPrice(address: string | undefined) {
  if (!address) {
    return null;
  }

  return MOCK_TOKEN_PRICES[normalizeAddress(address)] ?? null;
}

async function fetchPrices(addresses: ReadonlyArray<string>): Promise<Record<string, number>> {
  if (addresses.length === 0) {
    return {};
  }

  const result: Record<string, number> = {};
  const unresolvedAddresses: string[] = [];

  for (const address of addresses) {
    const mockPrice = resolveMockTokenPrice(address);
    if (mockPrice !== null) {
      result[address] = mockPrice;
      continue;
    }

    unresolvedAddresses.push(address);
  }

  if (unresolvedAddresses.length === 0) {
    return result;
  }

  const coinIds = unresolvedAddresses.map(toCoinId);
  const url = `${DEFILLAMA_BASE}/${coinIds.join(",")}`;

  try {
    const res = await fetch(url);
    if (!res.ok) {
      throw new Error(`DefiLlama API error: ${res.status}`);
    }

    const data: DefiLlamaResponse = await res.json();

    for (const address of unresolvedAddresses) {
      const coinId = toCoinId(address);
      const coin = data.coins[coinId];
      if (coin) {
        result[address] = coin.price;
        if (address === NATIVE_TOKEN_ADDRESS || address === LEGACY_NATIVE_TOKEN_ADDRESS) {
          result[NATIVE_TOKEN_ADDRESS] = coin.price;
          result[LEGACY_NATIVE_TOKEN_ADDRESS] = coin.price;
        }
      }
    }

    return result;
  } catch (error) {
    if (Object.keys(result).length > 0) {
      return result;
    }

    throw error;
  }
}

export function useTokenPrices(addresses: ReadonlyArray<string>) {
  return useQuery({
    queryKey: ["token-prices", ...addresses],
    queryFn: () => fetchPrices(addresses),
    enabled: addresses.length > 0,
    staleTime: 30_000,
    retry: 2,
  });
}

export function useTokenPrice(address: string | undefined) {
  const { data } = useTokenPrices(address ? [address] : []);

  return address ? (data?.[address] ?? data?.[normalizeAddress(address)] ?? null) : null;
}
