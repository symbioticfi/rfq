import type { BackendEnv } from "../config/env";
import { curatorRegistryAbi, instantRedemptionAdapterAbi, vaultAbi } from "../lib/contracts";
import {
  buildPermitData,
  getLowercasedAddress,
  toNonceHex,
  toReactorOutputs,
  type ReactorRequest,
} from "../lib/reactor";
import type { BackendMetrics } from "../metrics";
import { solverQuoteResponseSchema } from "../schemas/api";
import type { DiscountService } from "./discount-service";
import type {
  OrderOutput,
  PublicQuoteResponse,
  QuoteRequestInput,
  QuoteRequestRecord,
  SolverConfig,
  SolverQuoteRecord,
  SolverQuoteRequest,
  SolverQuoteResponse,
} from "../types/domain";
import type { BackendRepositories } from "../types/repositories";
import { newUuid } from "../utils/ids";
import type { PublicClient, SolverVaultInventory } from "./shared";

type AuthorizationSnapshot = ReadonlyMap<string, ReadonlySet<string>>;

type AuctionRequest = {
  readonly requestId: string;
  readonly tokenInChainId: number;
  readonly tokenOutChainId: number;
  readonly tokenIn: `0x${string}`;
  readonly tokenOut: `0x${string}`;
  readonly amount: string;
  readonly quoteId: string;
  readonly numOutputs: number;
};

type AuctionCandidate = {
  readonly solver: SolverConfig;
  readonly eligibleInventories: readonly (SolverVaultInventory & {
    readonly discountId: `0x${string}` | null;
  })[];
  readonly request: SolverQuoteRequest;
};

type AuctionWinner = {
  readonly solverId: string;
  readonly filler: `0x${string}`;
  readonly amountOut: string;
  readonly latencyMs: number;
};

type ReadContractBatch = Parameters<PublicClient["multicall"]>[0]["contracts"];
type ReadContractCall = Parameters<PublicClient["readContract"]>[0];
type ReadContractInput = ReadContractBatch extends readonly (infer Contract)[] ? Contract : never;
type ReadContractResult = {
  readonly status: "success" | "failure";
  readonly result?: unknown;
};

export class QuoteEngine {
  readonly #env: BackendEnv;
  readonly #publicClient: PublicClient;
  readonly #repositories: BackendRepositories;
  readonly #discountService: Pick<DiscountService, "listLive">;
  readonly #metrics: BackendMetrics;
  readonly #fetchImpl: typeof fetch;
  readonly #now: () => Date;

  constructor(input: {
    readonly env: BackendEnv;
    readonly publicClient: PublicClient;
    readonly repositories: BackendRepositories;
    readonly discountService: Pick<DiscountService, "listLive">;
    readonly metrics: BackendMetrics;
    readonly fetchImpl: typeof fetch;
    readonly now: () => Date;
  }) {
    this.#env = input.env;
    this.#publicClient = input.publicClient;
    this.#repositories = input.repositories;
    this.#discountService = input.discountService;
    this.#metrics = input.metrics;
    this.#fetchImpl = input.fetchImpl;
    this.#now = input.now;
  }

  async quote(input: QuoteRequestInput): Promise<PublicQuoteResponse | null> {
    this.#assertQuoteInput(input);

    const requestId = newUuid();
    const quoteId = newUuid();
    const quoteRequestId = newUuid();
    const now = this.#now();
    const deadline = BigInt(Math.floor(now.getTime() / 1000) + this.#env.permitDeadlineSeconds);
    const nonce = this.#randomNonce();

    const { candidates, authorizationSnapshot } = await this.#buildAuctionCandidates(
      {
        requestId,
        tokenInChainId: input.tokenInChainId,
        tokenOutChainId: input.tokenOutChainId,
        tokenIn: input.tokenIn,
        tokenOut: input.tokenOut,
        amount: input.amount,
        quoteId,
        numOutputs: input.outputs.length,
      },
      input.tokenIn,
    );

    if (candidates.length === 0) {
      this.#metrics.quoteRequests.inc({ route: "/quote", result: "no_quote" });
      return null;
    }

    await this.#repositories.quotes.create({
      id: quoteRequestId,
      requestId,
      quoteId,
      phase: "preview",
      request: input,
      permitData: {
        domain: {},
        types: {},
        value: {},
      },
      outputs: [],
      bestAmountOut: null,
      bestFiller: null,
      selectedSolverId: null,
      expiresAt: new Date(Number(deadline) * 1000),
      createdAt: now,
    });

    const bestQuote = await this.#runAuction(
      "preview",
      quoteId,
      input.routingPreference,
      authorizationSnapshot,
      candidates,
    );
    if (!bestQuote) {
      this.#metrics.quoteRequests.inc({ route: "/quote", result: "no_quote" });
      return null;
    }

    const outputs = this.#allocateOutputs(input.outputs, BigInt(bestQuote.amountOut));
    const reactorRequest: ReactorRequest = {
      tokenIn: input.tokenIn,
      amountIn: BigInt(input.amount),
      outputs: toReactorOutputs(outputs),
      deadline,
      nonce,
      protocol: this.#env.protocolSignerAddress,
    };
    const permitData = buildPermitData({
      permit2: this.#env.permit2Address,
      reactor: this.#env.reactorAddress,
      chainId: this.#env.chainId,
      request: reactorRequest,
    });

    await this.#repositories.quotes.finalize({
      quoteId,
      permitData,
      outputs,
      bestAmountOut: bestQuote.amountOut,
      bestFiller: bestQuote.filler,
      solverId: bestQuote.solverId,
    });

    this.#metrics.quoteRequests.inc({ route: "/quote", result: "quoted" });
    return {
      requestId,
      routing: "Priority",
      quote: {
        quoteId,
        slippageTolerance: input.slippageTolerance,
        aggregatedOutputs: [{ token: input.tokenOut, amount: bestQuote.amountOut }],
        orderInfo: {
          tokenIn: input.tokenIn,
          amountIn: input.amount,
          outputs,
          deadline: Number(deadline),
          nonce: toNonceHex(nonce),
        },
      },
      permitData,
    };
  }

  async requote(quote: QuoteRequestRecord): Promise<AuctionWinner | null> {
    const { candidates, authorizationSnapshot } = await this.#buildAuctionCandidates(
      {
        requestId: newUuid(),
        tokenInChainId: quote.request.tokenInChainId,
        tokenOutChainId: quote.request.tokenOutChainId,
        tokenIn: quote.request.tokenIn,
        tokenOut: quote.request.tokenOut,
        amount: quote.request.amount,
        quoteId: quote.quoteId,
        numOutputs: quote.request.outputs.length,
      },
      quote.request.tokenIn,
    );

    if (candidates.length === 0) {
      return null;
    }

    return this.#runAuction("executable", quote.quoteId, "BEST_PRICE", authorizationSnapshot, candidates);
  }

  async #buildAuctionCandidates(input: AuctionRequest, tokenIn: `0x${string}`): Promise<{
    readonly authorizationSnapshot: AuthorizationSnapshot;
    readonly candidates: readonly AuctionCandidate[];
  }> {
    const [solvers, inventories, liveDiscounts] = await Promise.all([
      this.#repositories.solvers.listEligible(input.tokenInChainId, this.#now()),
      this.#collectVaultInventories(tokenIn),
      this.#discountService.listLive(),
    ]);

    if (solvers.length === 0 || inventories.length === 0) {
      return { authorizationSnapshot: new Map(), candidates: [] };
    }

    const authorizationSnapshot = await this.#buildAuthorizationSnapshot(inventories);

    const discountsByPair = new Map(
      liveDiscounts.discounts.map((discount) => [`${discount.vault}:${discount.tokenToRedeem}`, discount] as const),
    );

    const candidates = solvers.flatMap((solver) => {
      const eligibleInventories = inventories.flatMap<
        SolverVaultInventory & {
          readonly discountId: `0x${string}` | null;
        }
      >((inventory) => {
        if (this.#isAuthorizedFillerForVault(authorizationSnapshot, inventory, solver.filler)) {
          return [
            {
              ...inventory,
              discountId: null,
            } satisfies SolverVaultInventory & { readonly discountId: `0x${string}` | null },
          ];
        }

        const discount = discountsByPair.get(`${inventory.vault}:${tokenIn}`);
        if (!discount) {
          return [];
        }

        return [
          {
            ...inventory,
            maxCollateralOut: discount.maxAssets,
            maxRate: discount.maxRate,
            discountId: discount.discountId,
          } satisfies SolverVaultInventory & { readonly discountId: `0x${string}` | null },
        ];
      });
      if (eligibleInventories.length === 0) {
        return [];
      }

      const eligibleVaults = eligibleInventories.map((inventory) => ({
        vault: inventory.vault,
        collateral: inventory.collateral,
        collateralDecimals: inventory.collateralDecimals,
        maxCollateralOut: inventory.maxCollateralOut,
        maxRate: inventory.maxRate,
        discountId: inventory.discountId,
      })) satisfies SolverQuoteRequest["vaults"];

      return [
        {
          solver,
          eligibleInventories,
          request: {
            requestId: input.requestId,
            tokenInChainId: input.tokenInChainId,
            tokenOutChainId: input.tokenOutChainId,
            swapper: "0x0000000000000000000000000000000000000000",
            tokenIn: input.tokenIn,
            tokenOut: input.tokenOut,
            amount: input.amount,
            type: "EXACT_INPUT",
            protocol: "v1",
            numOutputs: input.numOutputs,
            quoteId: input.quoteId,
            vaults: eligibleVaults,
          } satisfies SolverQuoteRequest,
        },
      ];
    });

    return {
      authorizationSnapshot,
      candidates,
    };
  }

  async #buildAuthorizationSnapshot(inventories: readonly SolverVaultInventory[]): Promise<AuthorizationSnapshot> {
    const marketMakers = [...new Set(inventories.map((inventory) => inventory.marketMaker))];
    return this.#repositories.fills.listAuthorizedFillersForMarketMakers(this.#env.chainId, marketMakers);
  }

  async #runAuction(
    phase: "preview" | "executable",
    quoteId: string,
    routingPreference: QuoteRequestInput["routingPreference"],
    authorizationSnapshot: AuthorizationSnapshot,
    candidates: readonly AuctionCandidate[],
  ): Promise<AuctionWinner | null> {
    const responses = await Promise.all(
      candidates.map(async ({ solver, request, eligibleInventories }) => {
        const startedAt = performance.now();
        try {
          const controller = new AbortController();
          const timeout = setTimeout(() => controller.abort(), this.#env.solverTimeoutMs);
          const response = await this.#fetchImpl(new URL("/quote", solver.endpointUrl), {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              ...(this.#env.solverSharedSecret
                ? {
                    "x-rfq-shared-secret": this.#env.solverSharedSecret,
                  }
                : {}),
            },
            body: JSON.stringify(request),
            signal: controller.signal,
          });
          clearTimeout(timeout);

          const latencyMs = Math.round(performance.now() - startedAt);
          if (response.status === 204) {
            await this.#recordSolverQuote({
              quoteId,
              solver,
              phase,
              status: "no_quote",
              latencyMs,
              amountOut: null,
              filler: null,
              responsePayload: null,
              errorMessage: null,
            });
            return null;
          }

          if (!response.ok) {
            await this.#recordSolverQuote({
              quoteId,
              solver,
              phase,
              status: "error",
              latencyMs,
              amountOut: null,
              filler: null,
              responsePayload: null,
              errorMessage: `HTTP ${response.status}`,
            });
            return null;
          }

          const payload = solverQuoteResponseSchema.parse(await response.json()) as SolverQuoteResponse;
          if (
            payload.chainId !== this.#env.chainId ||
            payload.requestId !== request.requestId ||
            getLowercasedAddress(payload.tokenIn) !== getLowercasedAddress(request.tokenIn) ||
            getLowercasedAddress(payload.tokenOut) !== getLowercasedAddress(request.tokenOut) ||
            getLowercasedAddress(payload.swapper) !== getLowercasedAddress(request.swapper) ||
            payload.quoteId !== request.quoteId
          ) {
            await this.#recordSolverQuote({
              quoteId,
              solver,
              phase,
              status: "error",
              latencyMs,
              amountOut: null,
              filler: payload.filler,
              responsePayload: payload as unknown as Record<string, unknown>,
              errorMessage: "Solver response did not match the request",
            });
            return null;
          }

          if (BigInt(payload.amountOut) === 0n) {
            await this.#recordSolverQuote({
              quoteId,
              solver,
              phase,
              status: "no_quote",
              latencyMs,
              amountOut: null,
              filler: null,
              responsePayload: payload as unknown as Record<string, unknown>,
              errorMessage: null,
            });
            return null;
          }

          const hasAuthorizedPermissionedPath = eligibleInventories.some((inventory) =>
            this.#isAuthorizedFillerForVault(authorizationSnapshot, inventory, payload.filler),
          );
          const hasDiscountBackedPath = eligibleInventories.some(
            (inventory) =>
              inventory.discountId !== null &&
              getLowercasedAddress(payload.filler) === getLowercasedAddress(solver.filler),
          );
          if (!hasAuthorizedPermissionedPath && !hasDiscountBackedPath) {
            await this.#recordSolverQuote({
              quoteId,
              solver,
              phase,
              status: "error",
              latencyMs,
              amountOut: null,
              filler: payload.filler,
              responsePayload: payload as unknown as Record<string, unknown>,
              errorMessage: "Solver returned an unauthorized filler",
            });
            return null;
          }

          await this.#recordSolverQuote({
            quoteId,
            solver,
            phase,
            status: "quoted",
            latencyMs,
            amountOut: payload.amountOut,
            filler: payload.filler,
            responsePayload: payload as unknown as Record<string, unknown>,
            errorMessage: null,
          });
          return {
            solverId: solver.id,
            filler: payload.filler,
            amountOut: payload.amountOut,
            latencyMs,
          } satisfies AuctionWinner;
        } catch (error) {
          const latencyMs = Math.round(performance.now() - startedAt);
          await this.#recordSolverQuote({
            quoteId,
            solver,
            phase,
            status: error instanceof Error && error.name === "AbortError" ? "timeout" : "error",
            latencyMs,
            amountOut: null,
            filler: null,
            responsePayload: null,
            errorMessage: error instanceof Error ? error.message : "Unknown solver error",
          });
          return null;
        }
      }),
    );

    return this.#selectBestQuote(
      routingPreference,
      responses.filter((value): value is AuctionWinner => value !== null),
    );
  }

  async #recordSolverQuote(input: {
    readonly quoteId: string;
    readonly solver: SolverConfig;
    readonly phase: "preview" | "executable";
    readonly status: SolverQuoteRecord["status"];
    readonly latencyMs: number;
    readonly amountOut: string | null;
    readonly filler: `0x${string}` | null;
    readonly responsePayload: Record<string, unknown> | null;
    readonly errorMessage: string | null;
  }) {
    const quote = await this.#repositories.quotes.findByQuoteId(input.quoteId);
    await this.#repositories.solverQuotes.create({
      id: newUuid(),
      quoteRequestId: quote?.id ?? newUuid(),
      solverId: input.solver.id,
      phase: input.phase,
      status: input.status,
      latencyMs: input.latencyMs,
      amountOut: input.amountOut,
      filler: input.filler,
      responsePayload: input.responsePayload,
      errorMessage: input.errorMessage,
      createdAt: this.#now(),
    });
    this.#metrics.solverQuoteLatencyMs.observe(
      {
        solver_id: input.solver.id,
        phase: input.phase,
        status: input.status,
      },
      input.latencyMs,
    );
  }

  #selectBestQuote(
    routingPreference: QuoteRequestInput["routingPreference"],
    quotes: readonly AuctionWinner[],
  ): AuctionWinner | null {
    if (quotes.length === 0) {
      return null;
    }

    if (routingPreference === "FASTEST") {
      return [...quotes].sort((left, right) => left.latencyMs - right.latencyMs)[0] ?? null;
    }

    return (
      [...quotes].sort((left, right) => {
        const amountDelta = BigInt(right.amountOut) - BigInt(left.amountOut);
        if (amountDelta !== 0n) {
          return amountDelta > 0n ? 1 : -1;
        }

        return left.latencyMs - right.latencyMs;
      })[0] ?? null
    );
  }

  #allocateOutputs(outputs: QuoteRequestInput["outputs"], totalAmountOut: bigint): OrderOutput[] {
    const variableOutputs = outputs.filter((output) => output.portionBps === undefined);
    if (variableOutputs.length !== 1) {
      throw new Error("Exactly one output must omit portionBps");
    }

    let allocated = 0n;
    const finalOutputs: OrderOutput[] = outputs.map((output) => {
      if (output.portionBps === undefined) {
        return {
          token: output.token,
          recipient: output.recipient,
          amount: "0",
        };
      }

      const amount = (totalAmountOut * BigInt(output.portionBps)) / 10_000n;
      allocated += amount;
      return {
        token: output.token,
        recipient: output.recipient,
        amount: amount.toString(),
        portionBps: output.portionBps,
      };
    });

    const primaryIndex = finalOutputs.findIndex((output) => output.amount === "0");
    const primaryAmount = totalAmountOut - allocated;
    finalOutputs[primaryIndex] = {
      token: finalOutputs[primaryIndex]!.token,
      recipient: finalOutputs[primaryIndex]!.recipient,
      amount: primaryAmount.toString(),
    };
    return finalOutputs;
  }

  async #collectVaultInventories(tokenIn: `0x${string}`): Promise<SolverVaultInventory[]> {
    const indexedVaults = await this.#repositories.fills.listIndexedVaults(this.#env.chainId);
    const deploymentVaults = this.#env.deployment.vaults.map((vault) => getLowercasedAddress(vault.address));
    const uniqueVaultSet = new Set([...indexedVaults.map(getLowercasedAddress), ...deploymentVaults]);
    const vaults = [...uniqueVaultSet];

    if (vaults.length === 0) {
      return [];
    }

    const collateralDecimalsByAddress = new Map<string, number>(
      this.#env.deployment.tokens.output.map((token) => [getLowercasedAddress(token.address), token.decimals]),
    );
    const inventoryContracts = vaults.flatMap<ReadContractInput>((vault) => [
      {
        address: this.#env.instantRedemptionAdapterAddress,
        abi: instantRedemptionAdapterAbi,
        functionName: "isPaused",
        args: [vault],
      },
      {
        address: this.#env.instantRedemptionAdapterAddress,
        abi: instantRedemptionAdapterAbi,
        functionName: "getMaxAssets",
        args: [vault],
      },
      {
        address: vault,
        abi: vaultAbi,
        functionName: "collateral",
      },
      {
        address: this.#env.curatorRegistryAddress,
        abi: curatorRegistryAbi,
        functionName: "getCurator",
        args: [vault],
      },
      {
        address: this.#env.instantRedemptionAdapterAddress,
        abi: instantRedemptionAdapterAbi,
        functionName: "marketMaker",
        args: [vault],
      },
      {
        address: this.#env.instantRedemptionAdapterAddress,
        abi: instantRedemptionAdapterAbi,
        functionName: "getMaxRate",
        args: [vault, tokenIn],
      },
    ]);
    const inventoryResults = await this.#readContractsAllowFailure(inventoryContracts);

    const inventories: SolverVaultInventory[] = [];
    for (let vaultIndex = 0; vaultIndex < vaults.length; vaultIndex += 1) {
      const vault = vaults[vaultIndex]!;
      const baseIndex = vaultIndex * 6;
      const pausedResult = inventoryResults[baseIndex];
      const maxAssetsResult = inventoryResults[baseIndex + 1];
      const collateralResult = inventoryResults[baseIndex + 2];
      const curatorResult = inventoryResults[baseIndex + 3];
      const marketMakerResult = inventoryResults[baseIndex + 4];
      const maxRateResult = inventoryResults[baseIndex + 5];

      if (
        pausedResult?.status !== "success" ||
        maxAssetsResult?.status !== "success" ||
        collateralResult?.status !== "success" ||
        curatorResult?.status !== "success" ||
        marketMakerResult?.status !== "success" ||
        maxRateResult?.status !== "success"
      ) {
        continue;
      }

      if (pausedResult.result === true) {
        continue;
      }

      const maxCollateralOut = BigInt(maxAssetsResult.result as bigint);
      const maxRate = BigInt(maxRateResult.result as bigint);
      if (maxCollateralOut <= 0n || maxRate <= 0n) {
        continue;
      }

      const collateral = getLowercasedAddress(collateralResult.result as `0x${string}`);
      const collateralDecimals = collateralDecimalsByAddress.get(collateral);
      if (collateralDecimals === undefined) {
        continue;
      }

      inventories.push({
        vault,
        collateral,
        collateralDecimals,
        maxCollateralOut: maxCollateralOut.toString(),
        maxRate: maxRate.toString(),
        curator: getLowercasedAddress(curatorResult.result as `0x${string}`),
        marketMaker: getLowercasedAddress(marketMakerResult.result as `0x${string}`),
      });
    }

    return inventories;
  }

  async #readContractsAllowFailure(contracts: ReadContractBatch): Promise<readonly ReadContractResult[]> {
    try {
      const results = (await this.#publicClient.multicall({
        allowFailure: true,
        contracts,
      })) as readonly ReadContractResult[];
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
            result: await this.#publicClient.readContract(contract as ReadContractCall),
          };
        } catch {
          return {
            status: "failure" as const,
          };
        }
      }),
    );
  }

  #isAuthorizedFillerForVault(
    authorizationSnapshot: AuthorizationSnapshot,
    inventory: SolverVaultInventory,
    filler: `0x${string}`,
  ) {
    const normalizedFiller = getLowercasedAddress(filler);
    if (
      inventory.curator === normalizedFiller ||
      inventory.marketMaker === normalizedFiller
    ) {
      return true;
    }

    const authorizedFillers = authorizationSnapshot.get(inventory.marketMaker);
    if (authorizedFillers) {
      return authorizedFillers.has(normalizedFiller);
    }

    return false;
  }

  #assertQuoteInput(input: QuoteRequestInput) {
    if (input.tokenInChainId !== this.#env.chainId || input.tokenOutChainId !== this.#env.chainId) {
      throw new Error(`Unsupported chainId ${input.tokenInChainId}`);
    }
    if (input.type !== "EXACT_INPUT") {
      throw new Error("Only EXACT_INPUT is supported");
    }
    if (input.outputs.length === 0) {
      throw new Error("At least one output is required");
    }
  }

  #randomNonce() {
    const bytes = crypto.getRandomValues(new Uint8Array(32));
    return BigInt(`0x${Buffer.from(bytes).toString("hex")}`);
  }
}
