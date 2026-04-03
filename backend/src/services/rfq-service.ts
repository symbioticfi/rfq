import { createBackendWalletClient, getBackendEnv } from "../config/env";
import { createMetrics } from "../metrics";
import type {
  CreateOrderRequest,
  DiscountFilters,
  PublishDiscountRequest,
  QuoteRequestInput,
  ResolveDiscountRequest,
} from "../types/domain";
import type { OrderListFilters } from "../types/repositories";
import { DiscountService } from "./discount-service";
import { FundingService } from "./funding-service";
import { OrderReadService } from "./order-read-service";
import { OrderService } from "./order-service";
import { QuoteEngine } from "./quote-engine";
import type { ApprovalCheckInput, PublicClient, RfqServiceDependencies } from "./shared";

export class RfqService {
  readonly #fundingService: FundingService;
  readonly #discountService: DiscountService;
  readonly #quoteEngine: QuoteEngine;
  readonly #orderService: OrderService;
  readonly #orderReadService: OrderReadService;

  constructor(dependencies: RfqServiceDependencies) {
    this.#fundingService = new FundingService({
      env: dependencies.env,
      publicClient: dependencies.publicClient,
      walletClient: dependencies.walletClient,
    });

    this.#discountService = new DiscountService({
      env: dependencies.env,
      publicClient: dependencies.publicClient,
      repositories: dependencies.repositories,
      now: dependencies.now,
    });

    this.#quoteEngine = new QuoteEngine({
      env: dependencies.env,
      publicClient: dependencies.publicClient,
      repositories: dependencies.repositories,
      discountService: this.#discountService,
      metrics: dependencies.metrics,
      fetchImpl: dependencies.fetchImpl,
      now: dependencies.now,
    });

    this.#orderService = new OrderService({
      env: dependencies.env,
      repositories: dependencies.repositories,
      metrics: dependencies.metrics,
      fetchImpl: dependencies.fetchImpl,
      now: dependencies.now,
      quoteEngine: this.#quoteEngine,
    });

    this.#orderReadService = new OrderReadService({
      repositories: dependencies.repositories,
      metrics: dependencies.metrics,
      now: dependencies.now,
    });
  }

  checkApproval(input: ApprovalCheckInput) {
    return this.#fundingService.checkApproval(input);
  }

  fundLocalWallet(input: { readonly walletAddress: `0x${string}` }) {
    return this.#fundingService.fundLocalWallet(input);
  }

  describeLocalFaucet() {
    return this.#fundingService.describeLocalFaucet();
  }

  faucetLocalWallet(input: { readonly walletAddress: `0x${string}` }) {
    return this.#fundingService.faucetLocalWallet(input);
  }

  quote(input: QuoteRequestInput) {
    return this.#quoteEngine.quote(input);
  }

  listDiscounts(filters?: DiscountFilters) {
    return this.#discountService.listLive(filters);
  }

  publishDiscount(input: PublishDiscountRequest) {
    return this.#discountService.publish(input);
  }

  resolveDiscount(input: ResolveDiscountRequest) {
    return this.#discountService.resolve(input);
  }

  createOrder(input: CreateOrderRequest) {
    return this.#orderService.createOrder(input);
  }

  listOrders(filters: OrderListFilters) {
    return this.#orderReadService.listOrders(filters);
  }
}

export function createProductionRfqService(input: {
  readonly publicClient: PublicClient;
  readonly repositories: RfqServiceDependencies["repositories"];
}) {
  const env = getBackendEnv();

  return new RfqService({
    env,
    publicClient: input.publicClient,
    walletClient: createBackendWalletClient(env),
    repositories: input.repositories,
    metrics: createMetrics(),
    fetchImpl: fetch,
    now: () => new Date(),
  });
}

export type { ApprovalCheckInput, RfqServiceDependencies } from "./shared";
