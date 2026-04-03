import { useQuery } from "@tanstack/react-query";
import { erc20Abi } from "viem";
import { useChainId, usePublicClient } from "wagmi";

import { LEGACY_NATIVE_TOKEN_ADDRESS, NATIVE_TOKEN_ADDRESS } from "../config/rfq";
import { appChainId } from "../providers/chain-config";
import type { Token } from "../types/token";
import { useWallet } from "./use-wallet";

type TokenBalance = {
  readonly value: bigint;
};

export function useTokenBalance(token: Token | null) {
  const { address: walletAddress, isConnected } = useWallet();
  const activeChainId = useChainId();
  const publicClient = usePublicClient({ chainId: appChainId });
  const walletAddressHex = walletAddress as `0x${string}` | undefined;
  const isWrongChain = Boolean(walletAddressHex && isConnected && activeChainId !== undefined && activeChainId !== appChainId);
  const queryEnabled = Boolean(publicClient && walletAddressHex && isConnected && token && !isWrongChain);

  const isETH = token?.address === NATIVE_TOKEN_ADDRESS || token?.address === LEGACY_NATIVE_TOKEN_ADDRESS;

  const query = useQuery<TokenBalance>({
    queryKey: ["token-balance", appChainId, walletAddress, token?.address],
    enabled: queryEnabled,
    staleTime: 15_000,
    refetchInterval: 30_000,
    retry: false,
    queryFn: async () => {
      if (!publicClient || !walletAddressHex || !token) {
        throw new Error("Missing balance query parameters");
      }

      if (isETH) {
        const value = await publicClient.getBalance({
          address: walletAddressHex,
        });

        return { value };
      }

      const value = await publicClient.readContract({
        address: token.address as `0x${string}`,
        abi: erc20Abi,
        functionName: "balanceOf",
        args: [walletAddressHex],
      });

      return { value };
    },
  });

  const shouldHoldSkeleton = Boolean(walletAddressHex && isConnected && token && !isWrongChain && query.data === undefined);
  const isBalanceQueryPending = queryEnabled && (query.isPending || query.isFetching || query.isError);

  return {
    ...query,
    isPending: shouldHoldSkeleton || isBalanceQueryPending,
    isWrongChain,
  };
}
