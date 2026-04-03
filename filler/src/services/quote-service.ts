import type { FillerEnv } from "../config/env";
import type { StrategyRecord, SolverInventory, SolverQuoteRequest, SolverQuoteResponse } from "../types/domain";
import type { FillerRepositories } from "../types/repositories";
import {
  getTokenDecimals,
  type PublicClientLike,
  seedTokenDecimals,
  selectBestStrategy,
  normalizeAddress,
} from "./strategy-helpers";

type QuoteServiceInput = {
  readonly env: FillerEnv;
  readonly publicClient: PublicClientLike;
  readonly repositories: FillerRepositories;
  readonly now: () => Date;
};

/**
 * @dev Quote service that selects the best single-collateral strategy for a solver RFQ request.
 */
export class QuoteService {
  readonly #env: FillerEnv;
  readonly #publicClient: PublicClientLike;
  readonly #repositories: FillerRepositories;
  readonly #now: () => Date;
  readonly #tokenDecimals = new Map<`0x${string}`, number>();

  constructor(input: QuoteServiceInput) {
    this.#env = input.env;
    this.#publicClient = input.publicClient;
    this.#repositories = input.repositories;
    this.#now = input.now;
    seedTokenDecimals(this.#tokenDecimals, [...input.env.deployment.tokens.input, ...input.env.deployment.tokens.output]);
  }

  /**
   * @dev Produces a filler quote and persists the selected execution strategy by `quoteId`.
   * @param request The backend-to-solver RFQ request.
   * @returns A solver quote response or `null` when no strategy is viable.
   */
  async quote(request: SolverQuoteRequest): Promise<SolverQuoteResponse | null> {
    if (
      request.type !== "EXACT_INPUT" ||
      request.tokenInChainId !== this.#env.chainId ||
      request.tokenOutChainId !== this.#env.chainId ||
      request.vaults.length === 0
    ) {
      return null;
    }

    const tokenInDecimals = await getTokenDecimals(this.#publicClient, this.#tokenDecimals, request.tokenIn);
    const inventories: SolverInventory[] = request.vaults.map((inventory) => ({
      vault: normalizeAddress(inventory.vault),
      collateral: normalizeAddress(inventory.collateral),
      collateralDecimals: inventory.collateralDecimals,
      maxCollateralOut: inventory.maxCollateralOut,
      maxRate: inventory.maxRate,
      discountId: inventory.discountId ?? null,
    }));
    const best = await selectBestStrategy({
      request,
      inventories,
      tokenInDecimals,
      publicClient: this.#publicClient,
      adapterAddress: this.#env.instantRedemptionAdapterAddress,
      quoteDiscountBps: this.#env.quoteDiscountBps,
      now: this.#now,
    });
    if (!best) {
      return null;
    }

    await this.#repositories.strategies.upsert(best);

    return {
      chainId: this.#env.chainId,
      amountIn: request.amount,
      amountOut: best.quotedAmountOut,
      filler: this.#env.executorAddress,
      requestId: request.requestId,
      swapper: request.swapper,
      tokenIn: request.tokenIn,
      tokenOut: request.tokenOut,
      quoteId: request.quoteId,
    };
  }
}
