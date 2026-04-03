import { useQuery } from "@tanstack/react-query";
import { useMemo } from "react";
import { type Address, erc20Abi, getAddress, hexToString, isAddress } from "viem";
import { usePublicClient } from "wagmi";

import { appChainId } from "../providers/chain-config";
import type { Token } from "../types/token";

const bytes32MetadataAbi = [
  {
    type: "function",
    name: "symbol",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "bytes32" }],
  },
  {
    type: "function",
    name: "name",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "bytes32" }],
  },
] as const;

function sanitizeString(value: string | null | undefined) {
  const trimmed = value?.trim() ?? "";

  return trimmed.length > 0 ? trimmed : null;
}

function sanitizeBytes32(value: `0x${string}`) {
  return sanitizeString(hexToString(value, { size: 32 }).split("\0").join(""));
}

async function readTokenTextMetadata(
  publicClient: NonNullable<ReturnType<typeof usePublicClient>>,
  address: Address,
  field: "symbol" | "name",
) {
  try {
    const value = await publicClient.readContract({
      address,
      abi: erc20Abi,
      functionName: field,
    });

    return sanitizeString(value);
  } catch {
    try {
      const value = await publicClient.readContract({
        address,
        abi: bytes32MetadataAbi,
        functionName: field,
      });

      return sanitizeBytes32(value);
    } catch {
      return null;
    }
  }
}

function buildFallbackSymbol(address: Address) {
  return address.slice(2, 6).toUpperCase();
}

function buildTrustWalletLogoUri(address: Address) {
  return `https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/ethereum/assets/${address}/logo.png`;
}

async function resolveToken(
  publicClient: NonNullable<ReturnType<typeof usePublicClient>>,
  address: Address,
): Promise<Token> {
  const decimals = await publicClient.readContract({
    address,
    abi: erc20Abi,
    functionName: "decimals",
  });

  const [symbol, name] = await Promise.all([
    readTokenTextMetadata(publicClient, address, "symbol"),
    readTokenTextMetadata(publicClient, address, "name"),
  ]);

  return {
    address,
    decimals,
    symbol: symbol ?? buildFallbackSymbol(address),
    name: name ?? `Token ${address.slice(0, 8)}…${address.slice(-4)}`,
    logoURI: buildTrustWalletLogoUri(address),
  } satisfies Token;
}

function findKnownToken(address: Address | null, tokens: ReadonlyArray<Token>) {
  if (!address) {
    return null;
  }

  return tokens.find((token) => token.address.toLowerCase() === address.toLowerCase()) ?? null;
}

export function useImportableToken(query: string, knownTokens: ReadonlyArray<Token>) {
  const publicClient = usePublicClient({ chainId: appChainId });

  const normalizedAddress = useMemo(() => {
    const trimmed = query.trim();
    if (!isAddress(trimmed)) {
      return null;
    }

    return getAddress(trimmed);
  }, [query]);

  const knownToken = useMemo(() => findKnownToken(normalizedAddress, knownTokens), [knownTokens, normalizedAddress]);

  const queryResult = useQuery({
    queryKey: ["importable-token", appChainId, normalizedAddress],
    enabled: Boolean(publicClient && normalizedAddress && !knownToken),
    retry: false,
    staleTime: 5 * 60_000,
    queryFn: async () => {
      if (!publicClient || !normalizedAddress) {
        throw new Error("Missing token address");
      }

      return resolveToken(publicClient, normalizedAddress);
    },
  });

  return {
    isAddressQuery: Boolean(normalizedAddress),
    isKnownToken: Boolean(knownToken),
    resolvedToken: knownToken ?? queryResult.data ?? null,
    isLoading: queryResult.isLoading || queryResult.isFetching,
    error: queryResult.error instanceof Error ? queryResult.error.message : null,
  };
}
