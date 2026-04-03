import type { BackendEnv } from "../config/env";
import type { BackendMetrics } from "../metrics";
import type { BackendRepositories } from "../types/repositories";
import type { SolverInventory } from "../types/domain";

export type PublicClient = ReturnType<typeof import("../config/env").createBackendPublicClient>;
export type WalletClient = ReturnType<typeof import("../config/env").createBackendWalletClient>;

export type SolverVaultInventory = Omit<SolverInventory, "discountId"> & {
  readonly curator: `0x${string}`;
  readonly marketMaker: `0x${string}`;
};

export type RfqServiceDependencies = {
  readonly env: BackendEnv;
  readonly publicClient: PublicClient;
  readonly walletClient: WalletClient;
  readonly repositories: BackendRepositories;
  readonly metrics: BackendMetrics;
  readonly fetchImpl: typeof fetch;
  readonly now: () => Date;
};

export type ApprovalCheckInput = {
  readonly walletAddress: `0x${string}`;
  readonly chainId: number;
  readonly token: `0x${string}`;
  readonly amount: string;
};
