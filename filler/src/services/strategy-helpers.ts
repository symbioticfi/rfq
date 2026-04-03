import type { Abi } from "viem";
import { getAddress } from "viem";

import { curatorRegistryAbi, erc20Abi, instantRedemptionAdapterAbi, vaultAbi } from "../lib/contracts";
import type { SolverInventory, StrategyRecord } from "../types/domain";

const RATE_SCALE = 10n ** 18n;
const BPS_SCALE = 10_000n;

export type PublicClientLike = {
  readContract(input: {
    readonly address: `0x${string}`;
    readonly abi: Abi;
    readonly functionName: string;
    readonly args?: readonly unknown[];
  }): Promise<unknown>;
  multicall(input: {
    readonly allowFailure?: boolean;
    readonly contracts: readonly {
      readonly address: `0x${string}`;
      readonly abi: Abi;
      readonly functionName: string;
      readonly args?: readonly unknown[];
    }[];
  }): Promise<readonly unknown[]>;
};

type MulticallResult = {
  readonly status: "success" | "failure";
  readonly result?: unknown;
};

type ReadContractInput = Parameters<PublicClientLike["readContract"]>[0];

type InventorySource = {
  readonly vault: `0x${string}`;
  readonly collateralHint?: `0x${string}` | null;
  readonly collateralDecimalsHint?: number;
};

type StrategyRequest = {
  readonly requestId: string;
  readonly quoteId: string;
  readonly tokenIn: `0x${string}`;
  readonly tokenOut: `0x${string}`;
  readonly amount: string;
};

type StrategySelectionInput = {
  readonly request: StrategyRequest;
  readonly inventories: readonly SolverInventory[];
  readonly tokenInDecimals: number;
  readonly publicClient: PublicClientLike;
  readonly adapterAddress: `0x${string}`;
  readonly quoteDiscountBps: number;
  readonly now: () => Date;
};

export function normalizeAddress<T extends string | null | undefined>(value: T): T {
  if (typeof value !== "string" || !value.startsWith("0x")) {
    return value;
  }

  return getAddress(value).toLowerCase() as T;
}

export function seedTokenDecimals(
  tokenDecimals: Map<`0x${string}`, number>,
  tokens: readonly { readonly address: `0x${string}`; readonly decimals: number }[],
) {
  for (const token of tokens) {
    tokenDecimals.set(normalizeAddress(token.address), token.decimals);
  }
}

export async function getTokenDecimals(
  publicClient: PublicClientLike,
  tokenDecimals: Map<`0x${string}`, number>,
  token: `0x${string}`,
) {
  const normalizedToken = normalizeAddress(token);
  const cached = tokenDecimals.get(normalizedToken);
  if (cached !== undefined) {
    return cached;
  }

  const decimals = Number(
    await publicClient.readContract({
      address: normalizedToken,
      abi: erc20Abi,
      functionName: "decimals",
    }),
  );
  tokenDecimals.set(normalizedToken, decimals);
  return decimals;
}

export async function warmTokenDecimals(
  publicClient: PublicClientLike,
  tokenDecimals: Map<`0x${string}`, number>,
  tokens: readonly `0x${string}`[],
) {
  const uncachedTokens = [...new Set(tokens.map(normalizeAddress))].filter((token) => !tokenDecimals.has(token));
  if (uncachedTokens.length === 0) {
    return;
  }

  const results = await readContractsAllowFailure(
    publicClient,
    uncachedTokens.map((token) => ({
      address: token,
      abi: erc20Abi,
      functionName: "decimals",
    })),
  );

  for (let index = 0; index < uncachedTokens.length; index += 1) {
    const result = results[index];
    if (result?.status !== "success") {
      continue;
    }

    tokenDecimals.set(uncachedTokens[index]!, Number(result.result));
  }
}

export async function readVaultInventories(input: {
  readonly publicClient: PublicClientLike;
  readonly adapterAddress: `0x${string}`;
  readonly tokenIn: `0x${string}`;
  readonly tokenDecimals: Map<`0x${string}`, number>;
  readonly vaults: readonly InventorySource[];
}) {
  const vaults = [...new Map(input.vaults.map((vault) => [normalizeAddress(vault.vault), vault])).values()];
  if (vaults.length === 0) {
    return [] satisfies SolverInventory[];
  }

  const results = await readContractsAllowFailure(
    input.publicClient,
    vaults.flatMap<ReadContractInput>((vault) => [
      {
        address: input.adapterAddress,
        abi: instantRedemptionAdapterAbi,
        functionName: "isPaused",
        args: [vault.vault],
      },
      {
        address: vault.vault,
        abi: vaultAbi,
        functionName: "collateral",
      },
      {
        address: input.adapterAddress,
        abi: instantRedemptionAdapterAbi,
        functionName: "getMaxAssets",
        args: [vault.vault],
      },
      {
        address: input.adapterAddress,
        abi: instantRedemptionAdapterAbi,
        functionName: "getMaxRate",
        args: [vault.vault, input.tokenIn],
      },
    ]),
  );

  const preliminary: Array<{
    readonly vault: `0x${string}`;
    readonly collateral: `0x${string}`;
    readonly maxCollateralOut: string;
    readonly maxRate: string;
  }> = [];
  const uncachedCollaterals = new Set<`0x${string}`>();

  for (let vaultIndex = 0; vaultIndex < vaults.length; vaultIndex += 1) {
    const vault = vaults[vaultIndex]!;
    const baseIndex = vaultIndex * 4;
    const pausedResult = results[baseIndex];
    const collateralResult = results[baseIndex + 1];
    const maxAssetsResult = results[baseIndex + 2];
    const maxRateResult = results[baseIndex + 3];

    if (
      pausedResult?.status !== "success" ||
      collateralResult?.status !== "success" ||
      maxAssetsResult?.status !== "success" ||
      maxRateResult?.status !== "success" ||
      pausedResult.result === true
    ) {
      continue;
    }

    const collateral = normalizeAddress(collateralResult.result as `0x${string}`);
    const maxCollateralOut = BigInt(maxAssetsResult.result as bigint);
    const maxRate = BigInt(maxRateResult.result as bigint);
    if (maxCollateralOut <= 0n || maxRate <= 0n) {
      continue;
    }

    if (!input.tokenDecimals.has(collateral)) {
      if (normalizeAddress(vault.collateralHint) === collateral && vault.collateralDecimalsHint !== undefined) {
        input.tokenDecimals.set(collateral, vault.collateralDecimalsHint);
      } else {
        uncachedCollaterals.add(collateral);
      }
    }

    preliminary.push({
      vault: vault.vault,
      collateral,
      maxCollateralOut: maxCollateralOut.toString(),
      maxRate: maxRate.toString(),
    });
  }

  await warmTokenDecimals(input.publicClient, input.tokenDecimals, [...uncachedCollaterals]);

  return preliminary.flatMap((inventory) => {
    const collateralDecimals = input.tokenDecimals.get(inventory.collateral);
    if (collateralDecimals === undefined) {
      return [];
    }

    return [
      {
        ...inventory,
        collateralDecimals,
        discountId: null,
      } satisfies SolverInventory,
    ];
  });
}

export async function readPermissionedVaultInventories(input: {
  readonly publicClient: PublicClientLike;
  readonly adapterAddress: `0x${string}`;
  readonly curatorRegistryAddress: `0x${string}` | null;
  readonly executorAddress: `0x${string}`;
  readonly tokenIn: `0x${string}`;
  readonly tokenDecimals: Map<`0x${string}`, number>;
  readonly vaults: readonly InventorySource[];
}) {
  const curatorRegistryAddress = input.curatorRegistryAddress;
  if (!curatorRegistryAddress) {
    return [] satisfies SolverInventory[];
  }

  const baseInventories = await readVaultInventories({
    publicClient: input.publicClient,
    adapterAddress: input.adapterAddress,
    tokenIn: input.tokenIn,
    tokenDecimals: input.tokenDecimals,
    vaults: input.vaults,
  });
  if (baseInventories.length === 0) {
    return baseInventories;
  }

  const authorizationResults = await readContractsAllowFailure(
    input.publicClient,
    baseInventories.flatMap<ReadContractInput>((inventory) => [
      {
        address: input.adapterAddress,
        abi: instantRedemptionAdapterAbi,
        functionName: "marketMaker",
        args: [inventory.vault],
      },
      {
        address: curatorRegistryAddress,
        abi: curatorRegistryAbi,
        functionName: "getCurator",
        args: [inventory.vault],
      },
    ]),
  );

  const directAuthorizations = new Map<`0x${string}`, { readonly marketMaker: `0x${string}`; readonly curator: `0x${string}` }>();
  const fillerChecks: Array<{ readonly vault: `0x${string}`; readonly marketMaker: `0x${string}` }> = [];

  for (let index = 0; index < baseInventories.length; index += 1) {
    const inventory = baseInventories[index]!;
    const marketMakerResult = authorizationResults[index * 2];
    const curatorResult = authorizationResults[index * 2 + 1];
    if (marketMakerResult?.status !== "success" || curatorResult?.status !== "success") {
      continue;
    }

    const marketMaker = normalizeAddress(marketMakerResult.result as `0x${string}`);
    const curator = normalizeAddress(curatorResult.result as `0x${string}`);
    directAuthorizations.set(inventory.vault, { marketMaker, curator });

    if (marketMaker !== input.executorAddress && curator !== input.executorAddress) {
      fillerChecks.push({ vault: inventory.vault, marketMaker });
    }
  }

  const delegatedResults = fillerChecks.length === 0
    ? []
    : (await readContractsAllowFailure(
        input.publicClient,
        fillerChecks.map((entry) => ({
          address: input.adapterAddress,
          abi: instantRedemptionAdapterAbi,
          functionName: "isFiller",
          args: [entry.marketMaker, input.executorAddress],
        })),
      ));
  const delegatedAuthorization = new Map<`0x${string}`, boolean>();
  for (let index = 0; index < fillerChecks.length; index += 1) {
    delegatedAuthorization.set(
      fillerChecks[index]!.vault,
      delegatedResults[index]?.status === "success" && delegatedResults[index]?.result === true,
    );
  }

  return baseInventories.filter((inventory) => {
    const authorization = directAuthorizations.get(inventory.vault);
    if (!authorization) {
      return false;
    }

    return (
      authorization.marketMaker === input.executorAddress ||
      authorization.curator === input.executorAddress ||
      delegatedAuthorization.get(inventory.vault) === true
    );
  });
}

export async function selectBestStrategy(input: StrategySelectionInput): Promise<StrategyRecord | null> {
  const groups = groupInventories(input.inventories);
  const candidates = await Promise.all(
    [...groups.values()].map((group) =>
      evaluateInventoryGroup({
        request: input.request,
        inventories: group,
        tokenInDecimals: input.tokenInDecimals,
        publicClient: input.publicClient,
        adapterAddress: input.adapterAddress,
        quoteDiscountBps: input.quoteDiscountBps,
        now: input.now,
      }),
    ),
  );

  return (
    candidates
      .filter((candidate): candidate is StrategyRecord => candidate !== null)
      .sort((left, right) => {
        const outputDelta = BigInt(right.quotedAmountOut) - BigInt(left.quotedAmountOut);
        if (outputDelta !== 0n) {
          return outputDelta > 0n ? 1 : -1;
        }
        return BigInt(right.collateralAmountOut) > BigInt(left.collateralAmountOut) ? 1 : -1;
      })[0] ?? null
  );
}

function groupInventories(vaults: readonly SolverInventory[]) {
  const groups = new Map<`0x${string}`, SolverInventory[]>();
  for (const vault of vaults) {
    const list = groups.get(vault.collateral) ?? [];
    list.push(vault);
    groups.set(vault.collateral, list);
  }
  return groups;
}

async function evaluateInventoryGroup(input: {
  readonly request: StrategyRequest;
  readonly inventories: readonly SolverInventory[];
  readonly tokenInDecimals: number;
  readonly publicClient: PublicClientLike;
  readonly adapterAddress: `0x${string}`;
  readonly quoteDiscountBps: number;
  readonly now: () => Date;
}): Promise<StrategyRecord | null> {
  const collateral = normalizeAddress(input.inventories[0]!.collateral);
  const collateralDecimals = input.inventories[0]!.collateralDecimals;
  if (collateral !== normalizeAddress(input.request.tokenOut)) {
    return null;
  }

  const oracleAmountOut = BigInt(
    (await input.publicClient.readContract({
      address: input.adapterAddress,
      abi: instantRedemptionAdapterAbi,
      functionName: "getAmountOut",
      args: [input.request.tokenIn, collateral, BigInt(input.request.amount)],
    })) as bigint,
  );
  const privateQuotedAmountOut = applyQuoteDiscount(oracleAmountOut, input.quoteDiscountBps);
  const privateQuotedRate = rateForAmountOut(
    privateQuotedAmountOut,
    input.request.amount,
    input.tokenInDecimals,
    collateralDecimals,
  );
  const eligibleInventories = input.inventories
    .flatMap((inventory) => {
      const maxRate = BigInt(inventory.maxRate);
      const effectiveRate = inventory.discountId == null ? privateQuotedRate : maxRate;
      if (effectiveRate <= 0n) {
        return [];
      }

      if (inventory.discountId == null && maxRate < effectiveRate) {
        return [];
      }

      return [{ inventory, effectiveRate }] as const;
    })
    .sort((left, right) => {
      const rateDelta = right.effectiveRate - left.effectiveRate;
      if (rateDelta !== 0n) {
        return rateDelta > 0n ? 1 : -1;
      }

      const liquidityDelta = BigInt(right.inventory.maxCollateralOut) - BigInt(left.inventory.maxCollateralOut);
      if (liquidityDelta !== 0n) {
        return liquidityDelta > 0n ? 1 : -1;
      }

      const maxRateDelta = BigInt(right.inventory.maxRate) - BigInt(left.inventory.maxRate);
      if (maxRateDelta !== 0n) {
        return maxRateDelta > 0n ? 1 : -1;
      }

      return 0;
    });
  if (eligibleInventories.length === 0) {
    return null;
  }

  let remainingIn = BigInt(input.request.amount);
  let collateralAmountOut = 0n;
  const legs: StrategyRecord["legs"][number][] = [];

  for (const { inventory, effectiveRate } of eligibleInventories) {
    if (remainingIn === 0n) {
      break;
    }

    const maxAmountIn = maxAmountInForRate(
      BigInt(inventory.maxCollateralOut),
      effectiveRate,
      input.tokenInDecimals,
      inventory.collateralDecimals,
    );
    if (maxAmountIn === 0n) {
      continue;
    }

    const amountIn = remainingIn > maxAmountIn ? maxAmountIn : remainingIn;
    const amountOut = amountOutForRate(amountIn, effectiveRate, input.tokenInDecimals, inventory.collateralDecimals);
    if (amountOut === 0n) {
      continue;
    }

    remainingIn -= amountIn;
    collateralAmountOut += amountOut;
    legs.push({
      vault: inventory.vault,
      amountIn: amountIn.toString(),
      amountOut: amountOut.toString(),
      maxRate: inventory.maxRate,
      discountId: inventory.discountId ?? null,
    });
  }

  if (remainingIn !== 0n || legs.length === 0) {
    return null;
  }

  const now = input.now();
  return {
    quoteId: input.request.quoteId,
    requestId: input.request.requestId,
    tokenIn: input.request.tokenIn,
    tokenOut: input.request.tokenOut,
    amountIn: input.request.amount,
    collateral,
    collateralDecimals,
    collateralAmountOut: collateralAmountOut.toString(),
    quotedAmountOut: collateralAmountOut.toString(),
    legs,
    createdAt: now,
    updatedAt: now,
  } satisfies StrategyRecord;
}

function amountOutForRate(amountIn: bigint, rate: bigint, tokenInDecimals: number, collateralDecimals: number) {
  return (amountIn * rate * 10n ** BigInt(collateralDecimals)) / (RATE_SCALE * 10n ** BigInt(tokenInDecimals));
}

function maxAmountInForRate(maxCollateralOut: bigint, rate: bigint, tokenInDecimals: number, collateralDecimals: number) {
  const denominator = rate * 10n ** BigInt(collateralDecimals);
  if (denominator === 0n) {
    return 0n;
  }

  return (maxCollateralOut * RATE_SCALE * 10n ** BigInt(tokenInDecimals)) / denominator;
}

function applyQuoteDiscount(amountOut: bigint, quoteDiscountBps: number) {
  const discountBps = BigInt(quoteDiscountBps);
  if (discountBps <= 0n) {
    return amountOut;
  }

  return (amountOut * (BPS_SCALE - discountBps)) / BPS_SCALE;
}

function rateForAmountOut(amountOut: bigint, amountIn: string, tokenInDecimals: number, collateralDecimals: number) {
  const amountInRaw = BigInt(amountIn);
  if (amountInRaw === 0n) {
    return 0n;
  }

  return (amountOut * RATE_SCALE * 10n ** BigInt(tokenInDecimals)) / (amountInRaw * 10n ** BigInt(collateralDecimals));
}

async function readContractsAllowFailure(
  publicClient: PublicClientLike,
  contracts: readonly ReadContractInput[],
): Promise<readonly MulticallResult[]> {
  try {
    const results = (await publicClient.multicall({
      allowFailure: true,
      contracts,
    })) as readonly MulticallResult[];
    if (results.some((result) => result?.status === "success")) {
      return results;
    }
  } catch {
    // Fall back to sequential reads when multicall infrastructure is unavailable.
  }

  return Promise.all(
    contracts.map(async (contract) => {
      try {
        return {
          status: "success" as const,
          result: await publicClient.readContract(contract),
        };
      } catch {
        return {
          status: "failure" as const,
        };
      }
    }),
  );
}
