import { useWalletClient } from "wagmi";

import { appChainId } from "../providers/chain-config";

export type ActiveWalletClientState = {
  readonly chainId: number;
  readonly walletClient: NonNullable<ReturnType<typeof useWalletClient>["data"]>;
};

export function useActiveWalletClient() {
  const walletClientQuery = useWalletClient({ chainId: appChainId });

  return {
    ...walletClientQuery,
    data: walletClientQuery.data
      ? ({
          chainId: appChainId,
          walletClient: walletClientQuery.data,
        } satisfies ActiveWalletClientState)
      : undefined,
  };
}
