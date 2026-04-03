import type { FillerEnv } from "../config/env";
import { encodeExecutorFill } from "../lib/executor";
import { createSilentFillerLogger } from "../lib/logger";
import { decodeOrder, encodeExecutorData } from "../lib/reactor";
import type { Logger } from "pino";
import type {
  BackendOrderItem,
  DiscountsResponse,
  NotifyRequest,
  ReactorDiscountSwapInput,
  ReactorSwap,
  ResolveDiscountResponse,
  StrategyRecord,
} from "../types/domain";
import type { FillerRepositories } from "../types/repositories";
import {
  getTokenDecimals,
  normalizeAddress,
  type PublicClientLike,
  readPermissionedVaultInventories,
  seedTokenDecimals,
  selectBestStrategy,
} from "./strategy-helpers";

type RevalidationPublicClientLike = PublicClientLike & {
  waitForTransactionReceipt(input: {
    readonly hash: `0x${string}`;
  }): Promise<{ readonly status: "success" | "reverted" }>;
};

type WalletClientLike = {
  sendTransaction(input: {
    readonly account: `0x${string}`;
    readonly to: `0x${string}`;
    readonly data: `0x${string}`;
  }): Promise<`0x${string}`>;
};

type BackendClientLike = {
  listOpenOrders(filler: `0x${string}`, limit: number): Promise<readonly BackendOrderItem[]>;
  getExecutableOrder(orderId: string, filler: `0x${string}`): Promise<BackendOrderItem | null>;
  getOrder(orderId: string): Promise<BackendOrderItem | null>;
  listDiscounts(): Promise<DiscountsResponse>;
  resolveDiscount(input:
    | {
        readonly discountId: `0x${string}`;
        readonly vault?: undefined;
        readonly tokenToRedeem?: undefined;
      }
    | {
        readonly discountId?: undefined;
        readonly vault: `0x${string}`;
        readonly tokenToRedeem: `0x${string}`;
      }): Promise<ResolveDiscountResponse>;
};

type ExecutionServiceInput = {
  readonly env: FillerEnv;
  readonly publicClient: RevalidationPublicClientLike;
  readonly walletClient: WalletClientLike;
  readonly repositories: FillerRepositories;
  readonly backendClient: BackendClientLike;
  readonly now: () => Date;
  readonly logger?: Logger;
};

/**
 * @dev Background execution worker that accepts winner hints, polls backend open orders, and submits fills.
 */
export class ExecutionService {
  readonly #env: FillerEnv;
  readonly #publicClient: RevalidationPublicClientLike;
  readonly #walletClient: WalletClientLike;
  readonly #repositories: FillerRepositories;
  readonly #backendClient: BackendClientLike;
  readonly #now: () => Date;
  readonly #logger: Logger;
  readonly #inflight = new Set<string>();
  readonly #tokenDecimals = new Map<`0x${string}`, number>();
  #interval: ReturnType<typeof setInterval> | null = null;

  constructor(input: ExecutionServiceInput) {
    this.#env = input.env;
    this.#publicClient = input.publicClient;
    this.#walletClient = input.walletClient;
    this.#repositories = input.repositories;
    this.#backendClient = input.backendClient;
    this.#now = input.now;
    this.#logger = input.logger ?? createSilentFillerLogger("rfq-filler.execution");
    seedTokenDecimals(this.#tokenDecimals, [...input.env.deployment.tokens.input, ...input.env.deployment.tokens.output]);
  }

  /**
   * @dev Starts the background poll/reconcile loop.
   */
  start() {
    if (this.#interval) {
      return;
    }

    void this.syncOnce();
    this.#interval = setInterval(() => {
      void this.syncOnce();
    }, this.#env.pollIntervalMs);
  }

  /**
   * @dev Stops the background poll/reconcile loop.
   */
  stop() {
    if (this.#interval) {
      clearInterval(this.#interval);
      this.#interval = null;
    }
  }

  /**
   * @dev Accepts a notify webhook payload and queues the referenced order.
   * @param notify The winner notification payload.
   */
  async enqueueFromNotify(notify: NotifyRequest) {
    if (notify.chainId !== this.#env.chainId) {
      this.#logger.debug({ notifyChainId: notify.chainId, chainId: this.#env.chainId }, "Ignoring notify for wrong chain");
      return;
    }
    if (
      notify.filler &&
      normalizeAddress(notify.filler) !== normalizeAddress(this.#env.executorAddress)
    ) {
      this.#logger.debug(
        {
          notifyFiller: notify.filler,
          executorAddress: this.#env.executorAddress,
          orderHash: notify.orderHash,
        },
        "Ignoring notify for a different filler",
      );
      return;
    }
    if (!notify.quoteId || !notify.encodedOrder || !notify.signature) {
      this.#logger.warn({ orderHash: notify.orderHash }, "Ignoring incomplete notify payload");
      return;
    }

    const order = decodeOrder(notify.encodedOrder);
    const existingLocalOrder = await this.#repositories.orders.findByOrderHash(notify.orderHash);
    await this.#repositories.orders.upsertQueued({
      orderId: existingLocalOrder?.orderId ?? crypto.randomUUID(),
      orderHash: notify.orderHash,
      quoteId: notify.quoteId,
      source: "notify",
      filler: notify.filler ?? order.filler,
      encodedOrder: notify.encodedOrder,
      protocolSignature: notify.signature,
      deadline: Number(order.request.deadline),
    });
    this.#logger.info({ orderHash: notify.orderHash, quoteId: notify.quoteId }, "Queued order from notify");
    void this.syncOnce();
  }

  /**
   * @dev Runs one full poll/process/reconcile cycle.
   */
  async syncOnce() {
    try {
      await this.#pollOpenOrders();
    } catch (error) {
      this.#logError("pollOpenOrders", error);
    }
    const activeOrders = await this.#repositories.orders.listActive();
    await Promise.all(activeOrders.map((order) => this.#handleOrder(order.orderId, order.status)));
  }

  async #pollOpenOrders() {
    const orders = await this.#backendClient.listOpenOrders(this.#env.executorAddress, this.#env.orderLimit);
    if (orders.length > 0) {
      this.#logger.debug({ count: orders.length }, "Polled open orders from backend");
    }
    await Promise.all(
      orders.map((order) =>
        this.#repositories.orders.upsertQueued({
          orderId: order.orderId,
          quoteId: order.quoteId,
          source: "poll",
          filler: order.filler ?? this.#env.executorAddress,
        }),
      ),
    );
  }

  async #handleOrder(orderId: string, status: "queued" | "submitting" | "submitted" | "filled" | "expired" | "failed") {
    if (this.#inflight.has(orderId)) {
      return;
    }

    this.#inflight.add(orderId);
    try {
      if (status === "filled" || status === "expired" || status === "failed") {
        return;
      }
      if (status === "submitted") {
        await this.#reconcileTerminalStatus(orderId);
        return;
      }

      await this.#submitOrder(orderId);
    } catch (error) {
      this.#logError(`handleOrder(${orderId})`, error);
    } finally {
      this.#inflight.delete(orderId);
    }
  }

  async #submitOrder(orderId: string) {
    await this.#repositories.orders.markStatus(orderId, "submitting");

    const existingLocalOrder = await this.#repositories.orders.findByOrderId(orderId);
    const executableOrder =
      existingLocalOrder?.source === "notify" &&
      existingLocalOrder.quoteId &&
      existingLocalOrder.encodedOrder &&
      existingLocalOrder.protocolSignature &&
      existingLocalOrder.deadline &&
      existingLocalOrder.filler
        ? this.#buildExecutableOrderFromLocal(existingLocalOrder)
        : await this.#backendClient.getExecutableOrder(orderId, this.#env.executorAddress);
    if (!executableOrder) {
      await this.#reconcileTerminalStatus(orderId);
      return;
    }

    if (
      !executableOrder.encodedOrder ||
      !executableOrder.signature ||
      !executableOrder.deadline ||
      !executableOrder.filler
    ) {
      await this.#fail(orderId, "Executable order payload incomplete");
      return;
    }

    if (normalizeAddress(executableOrder.filler) !== normalizeAddress(this.#env.executorAddress)) {
      await this.#fail(orderId, "Backend assigned a different filler");
      return;
    }

    const localOrder = await this.#repositories.orders.hydrateExecutable({
      orderId,
      quoteId: executableOrder.quoteId,
      filler: executableOrder.filler,
      encodedOrder: executableOrder.encodedOrder,
      protocolSignature: executableOrder.signature,
      deadline: executableOrder.deadline,
    });

    const strategy =
      (await this.#repositories.strategies.findByQuoteId(executableOrder.quoteId)) ??
      (await this.#recoverStrategy(executableOrder));
    if (!strategy) {
      await this.#fail(orderId, `Missing strategy for quoteId ${executableOrder.quoteId}`);
      return;
    }

    const order = decodeOrder(executableOrder.encodedOrder);
    const outputToken = this.#singleOutputToken(executableOrder);
    if (!outputToken) {
      await this.#fail(orderId, "Only single output-token families are supported");
      return;
    }

    const requiredOutput = executableOrder.outputs.reduce((total, output) => total + BigInt(output.amount), 0n);
    const swapInputs: ReactorSwap[] = strategy.legs
      .filter((leg) => leg.discountId == null)
      .map((leg) => ({
        recipient: this.#env.executorAddress,
        vault: leg.vault,
        tokenIn: order.request.tokenIn,
        amountIn: BigInt(leg.amountIn),
        amountOut: BigInt(leg.amountOut),
      }));
    const discountSwapInputs = await this.#buildDiscountSwapInputs(strategy, order.request.tokenIn);

    if (normalizeAddress(strategy.collateral) !== normalizeAddress(outputToken)) {
      await this.#fail(orderId, "Strategy collateral must match order output token");
      return;
    }

    if (BigInt(strategy.quotedAmountOut) < requiredOutput) {
      await this.#fail(orderId, "Stored strategy output is below the required order output");
      return;
    }

    const txData = encodeExecutorFill(
      order,
      executableOrder.signature,
      swapInputs,
      discountSwapInputs,
      encodeExecutorData([]),
    );

    let txHash: `0x${string}`;
    try {
      txHash = await this.#walletClient.sendTransaction({
        account: this.#env.callerAccount.address,
        to: this.#env.executorAddress,
        data: txData,
      });
    } catch (error) {
      await this.#recordAttempt(orderId, null, error instanceof Error ? error.message : "Executor submission failed");
      await this.#fail(orderId, error instanceof Error ? error.message : "Executor submission failed");
      return;
    }

    this.#logger.info({ orderId, quoteId: executableOrder.quoteId, txHash }, "Submitted fill transaction");
    await this.#recordAttempt(orderId, txHash, null);
    await this.#repositories.orders.markStatus(orderId, "submitted", { txHash });
    const receipt = await this.#publicClient.waitForTransactionReceipt({ hash: txHash });
    if (receipt.status === "reverted") {
      await this.#recordAttempt(orderId, txHash, "Transaction reverted");
      await this.#fail(orderId, "Transaction reverted");
      return;
    }

    if (existingLocalOrder?.source === "notify") {
      await this.#repositories.orders.markStatus(orderId, "filled", { txHash, lastError: null });
      return;
    }

    await this.#reconcileTerminalStatus(orderId);
    const hydrated = await this.#repositories.orders.findByOrderId(localOrder.orderId);
    if (hydrated?.status === "submitted") {
      await this.#repositories.orders.markStatus(orderId, "submitted", { txHash, lastError: null });
    }
  }

  #singleOutputToken(order: BackendOrderItem) {
    const [first] = order.outputs;
    if (!first) {
      return null;
    }

    const token = first.token;
    return order.outputs.every((output) => output.token === token) ? token : null;
  }

  async #reconcileTerminalStatus(orderId: string) {
    const localOrder = await this.#repositories.orders.findByOrderId(orderId);
    if (localOrder?.source === "notify") {
      return;
    }

    const order = await this.#backendClient.getOrder(orderId);
    if (!order) {
      return;
    }

    if (order.orderStatus === "filled") {
      await this.#repositories.orders.markStatus(orderId, "filled", { txHash: order.txHash, lastError: null });
      return;
    }

    if (order.orderStatus === "expired") {
      await this.#repositories.orders.markStatus(orderId, "expired", { txHash: order.txHash, lastError: null });
      return;
    }

    if (order.orderStatus !== "open") {
      await this.#repositories.orders.markStatus(orderId, "failed", {
        txHash: order.txHash,
        lastError: `Backend terminal status ${order.orderStatus}`,
      });
    }
  }

  async #recordAttempt(orderId: string, txHash: `0x${string}` | null, error: string | null) {
    const attempt = (await this.#repositories.attempts.countByOrderId(orderId)) + 1;
    await this.#repositories.attempts.append({
      id: crypto.randomUUID(),
      orderId,
      attempt,
      txHash,
      error,
      createdAt: this.#now(),
    });
  }

  async #fail(orderId: string, error: string) {
    this.#logger.warn({ orderId, error }, "Marked order as failed");
    await this.#repositories.orders.markStatus(orderId, "failed", { lastError: error });
  }

  #buildExecutableOrderFromLocal(localOrder: {
    readonly orderId: string;
    readonly quoteId: string | null;
    readonly encodedOrder: `0x${string}` | null;
    readonly protocolSignature: `0x${string}` | null;
    readonly deadline: number | null;
    readonly filler: `0x${string}` | null;
  }): BackendOrderItem | null {
    if (
      !localOrder.quoteId ||
      !localOrder.encodedOrder ||
      !localOrder.protocolSignature ||
      !localOrder.deadline ||
      !localOrder.filler
    ) {
      return null;
    }

    const order = decodeOrder(localOrder.encodedOrder);

    return {
      type: "Priority",
      orderId: localOrder.orderId,
      orderStatus: "open",
      quoteId: localOrder.quoteId,
      swapper: order.swapper,
      txHash: null,
      nonce: `0x${order.request.nonce.toString(16)}`,
      input: {
        token: order.request.tokenIn,
        amount: order.request.amountIn.toString(),
      },
      outputs: order.request.outputs.map((output) => ({
        token: output.token,
        amount: output.amount.toString(),
        recipient: output.recipient,
      })),
      settledAmounts: [],
      encodedOrder: localOrder.encodedOrder,
      signature: localOrder.protocolSignature,
      deadline: localOrder.deadline,
      filler: localOrder.filler,
    };
  }

  async #recoverStrategy(order: BackendOrderItem): Promise<StrategyRecord | null> {
    const outputToken = this.#singleOutputToken(order);
    if (!outputToken) {
      return null;
    }

    const directInventories = await readPermissionedVaultInventories({
      publicClient: this.#publicClient,
      adapterAddress: this.#env.instantRedemptionAdapterAddress,
      curatorRegistryAddress: this.#env.curatorRegistryAddress,
      executorAddress: this.#env.executorAddress,
      tokenIn: order.input.token,
      tokenDecimals: this.#tokenDecimals,
      vaults: this.#env.deployment.vaults.map((vault) => ({
        vault: vault.address as `0x${string}`,
        collateralHint: vault.collateral as `0x${string}`,
      })),
    });
    let liveDiscounts: DiscountsResponse["discounts"] = [];
    try {
      liveDiscounts = (await this.#backendClient.listDiscounts()).discounts;
    } catch (error) {
      this.#logger.warn(
        { err: error, orderId: order.orderId },
        "Failed to fetch live discounts during strategy recovery",
      );
    }

    const permissionedVaults = new Set(directInventories.map((inventory) => normalizeAddress(inventory.vault)));
    const discountInventories = liveDiscounts
      .filter((discount) => normalizeAddress(discount.tokenToRedeem) === normalizeAddress(order.input.token))
      .filter((discount) => !permissionedVaults.has(normalizeAddress(discount.vault)))
      .map((discount) => ({
        vault: normalizeAddress(discount.vault),
        collateral: normalizeAddress(discount.collateral),
        collateralDecimals: discount.collateralDecimals,
        maxCollateralOut: discount.maxAssets,
        maxRate: discount.maxRate,
        discountId: discount.discountId,
      }));
    const inventories = [...directInventories, ...discountInventories];
    if (inventories.length === 0) {
      return null;
    }

    const tokenInDecimals = await getTokenDecimals(this.#publicClient, this.#tokenDecimals, order.input.token);
    const requiredOutput = order.outputs.reduce((total, output) => total + BigInt(output.amount), 0n);
    const best = await selectBestStrategy({
      request: {
        requestId: order.orderId,
        quoteId: order.quoteId,
        tokenIn: order.input.token,
        tokenOut: outputToken,
        amount: order.input.amount,
      },
      inventories,
      tokenInDecimals,
      publicClient: this.#publicClient,
      adapterAddress: this.#env.instantRedemptionAdapterAddress,
      quoteDiscountBps: this.#env.quoteDiscountBps,
      now: this.#now,
    });

    if (!best || BigInt(best.quotedAmountOut) < requiredOutput) {
      return null;
    }

    await this.#repositories.strategies.upsert(best);
    return best;
  }

  async #buildDiscountSwapInputs(
    strategy: StrategyRecord,
    tokenToRedeem: `0x${string}`,
  ): Promise<ReactorDiscountSwapInput[]> {
    const discountLegs = strategy.legs.filter((leg) => leg.discountId != null);
    return Promise.all(
      discountLegs.map(async (leg) => {
        const resolved = leg.discountId
          ? await this.#backendClient.resolveDiscount({ discountId: leg.discountId })
          : await this.#backendClient.resolveDiscount({
              vault: leg.vault,
              tokenToRedeem,
            });

        return {
          discountSwap: {
            discount: {
              vault: resolved.discount.vault,
              tokenToRedeem: resolved.discount.tokenToRedeem,
              discount: BigInt(resolved.discount.discount),
              signer: resolved.discount.signer,
              protocol: resolved.discount.protocol,
              nonce: BigInt(resolved.discount.nonce),
              deadline: resolved.discount.deadline,
            },
            signerSignature: resolved.signerSignature,
            protocolDeadline: resolved.protocolDeadline,
          },
          protocolSignature: resolved.protocolSignature,
          recipient: this.#env.executorAddress,
          amountIn: BigInt(leg.amountIn),
          amountOut: BigInt(leg.amountOut),
        } satisfies ReactorDiscountSwapInput;
      }),
    );
  }

  #logError(scope: string, error: unknown) {
    this.#logger.error({ err: error, scope }, "Execution service error");
  }
}
