import type { BackendEnv } from "../config/env";
import {
  encodeOrder,
  getLowercasedAddress,
  hashOrder,
  toReactorOutputs,
  verifyPermitSignature,
  type ReactorOrder,
} from "../lib/reactor";
import type { BackendMetrics } from "../metrics";
import type { CreateOrderRequest, OrderRecord, QuoteRequestRecord, SolverConfig } from "../types/domain";
import type { BackendRepositories } from "../types/repositories";
import { newUuid } from "../utils/ids";
import type { QuoteEngine } from "./quote-engine";

export class OrderService {
  readonly #env: BackendEnv;
  readonly #repositories: BackendRepositories;
  readonly #metrics: BackendMetrics;
  readonly #fetchImpl: typeof fetch;
  readonly #now: () => Date;
  readonly #quoteEngine: QuoteEngine;

  constructor(input: {
    readonly env: BackendEnv;
    readonly repositories: BackendRepositories;
    readonly metrics: BackendMetrics;
    readonly fetchImpl: typeof fetch;
    readonly now: () => Date;
    readonly quoteEngine: QuoteEngine;
  }) {
    this.#env = input.env;
    this.#repositories = input.repositories;
    this.#metrics = input.metrics;
    this.#fetchImpl = input.fetchImpl;
    this.#now = input.now;
    this.#quoteEngine = input.quoteEngine;
  }

  async createOrder(input: CreateOrderRequest) {
    const requestId = newUuid();
    const quote = await this.#repositories.quotes.findByQuoteId(input.quote.quoteId);
    if (!quote) {
      throw new Error("Unknown quoteId");
    }
    if (quote.expiresAt.getTime() <= this.#now().getTime()) {
      throw new Error("Quote expired");
    }
    if (!this.#matchesStoredQuote(quote, input.quote)) {
      throw new Error("Quote mismatch");
    }

    const verified = await verifyPermitSignature(quote.request.swapper, quote.permitData, input.signature);
    if (!verified) {
      throw new Error("Invalid swapper signature");
    }

    const existing = await this.#repositories.orders.findByQuoteIdAndSignature(quote.quoteId, input.signature);
    if (existing) {
      return {
        requestId,
        orderId: existing.orderId,
        orderStatus: existing.publicStatus,
      };
    }

    const winner = await this.#quoteEngine.requote(quote);
    if (!winner || BigInt(winner.amountOut) < BigInt(quote.bestAmountOut ?? "0")) {
      this.#metrics.ordersCreated.inc({ result: "no_winner" });
      throw new Error("Quote cannot be honored anymore");
    }

    const order: ReactorOrder = {
      request: {
        tokenIn: quote.request.tokenIn,
        amountIn: BigInt(quote.request.amount),
        outputs: toReactorOutputs(quote.outputs),
        deadline: BigInt(input.quote.orderInfo.deadline),
        nonce: BigInt(input.quote.orderInfo.nonce),
        protocol: this.#env.protocolSignerAddress,
      },
      swapperSignature: input.signature,
      swapper: quote.request.swapper,
      filler: winner.filler,
    };
    const orderHash = hashOrder(order);
    const encodedOrder = encodeOrder(order);
    const protocolSignature = await this.#env.protocolSigner.signTypedData({
      domain: {
        name: "Reactor",
        version: "1",
        chainId: this.#env.chainId,
        verifyingContract: this.#env.reactorAddress,
      },
      types: {
        Output: [
          { name: "token", type: "address" },
          { name: "amount", type: "uint256" },
          { name: "recipient", type: "address" },
        ],
        Request: [
          { name: "tokenIn", type: "address" },
          { name: "amountIn", type: "uint256" },
          { name: "outputs", type: "Output[]" },
          { name: "deadline", type: "uint256" },
          { name: "nonce", type: "uint256" },
          { name: "protocol", type: "address" },
        ],
        Order: [
          { name: "request", type: "Request" },
          { name: "swapperSignature", type: "bytes" },
          { name: "swapper", type: "address" },
          { name: "filler", type: "address" },
        ],
      },
      primaryType: "Order",
      message: order,
    });

    const now = this.#now();
    const record: OrderRecord = {
      orderId: newUuid(),
      quoteId: quote.quoteId,
      requestId,
      swapper: order.swapper,
      filler: order.filler,
      tokenIn: order.request.tokenIn,
      amountIn: order.request.amountIn.toString(),
      outputs: quote.outputs,
      deadline: Number(order.request.deadline),
      nonce: input.quote.orderInfo.nonce as `0x${string}`,
      orderHash,
      encodedOrder,
      protocolSignature,
      swapperSignature: input.signature,
      publicStatus: "open",
      internalStatus: "winner_selected",
      txHash: null,
      createdAt: now,
      updatedAt: now,
    };

    await this.#repositories.orders.create(record);
    await this.#repositories.orderStatusHistory.append({
      orderId: record.orderId,
      publicStatus: record.publicStatus,
      internalStatus: record.internalStatus,
      reason: null,
      createdAt: now,
    });
    await this.#notifyWinner(winner.solverId, record);

    this.#metrics.ordersCreated.inc({ result: "created" });
    this.#metrics.orderStatusTransitions.inc({
      public_status: record.publicStatus,
      internal_status: record.internalStatus,
    });

    return {
      requestId,
      orderId: record.orderId,
      orderStatus: record.publicStatus,
    };
  }

  #matchesStoredQuote(stored: QuoteRequestRecord, received: CreateOrderRequest["quote"]) {
    return (
      stored.quoteId === received.quoteId &&
      getLowercasedAddress(stored.request.tokenIn) === getLowercasedAddress(received.orderInfo.tokenIn) &&
      stored.request.amount === received.orderInfo.amountIn &&
      stored.outputs.length === received.orderInfo.outputs.length &&
      stored.outputs.every((output, index) => {
        const receivedOutput = received.orderInfo.outputs[index];
        return (
          receivedOutput !== undefined &&
          getLowercasedAddress(output.token) === getLowercasedAddress(receivedOutput.token) &&
          getLowercasedAddress(output.recipient) === getLowercasedAddress(receivedOutput.recipient) &&
          output.amount === receivedOutput.amount
        );
      }) &&
      Number(stored.expiresAt.getTime() / 1000) === received.orderInfo.deadline
    );
  }

  async #notifyWinner(solverId: string, order: OrderRecord) {
    const solvers = await this.#repositories.solvers.listEligible(this.#env.chainId, this.#now());
    const solver = solvers.find((candidate) => candidate.id === solverId);
    if (!solver?.notifyUrl) {
      return;
    }

    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 200);

    try {
      await this.#fetchImpl(solver.notifyUrl, {
        method: "POST",
        signal: controller.signal,
        headers: {
          "Content-Type": "application/json",
          ...(this.#env.solverSharedSecret
            ? {
                "x-rfq-shared-secret": this.#env.solverSharedSecret,
              }
            : {}),
        },
        body: JSON.stringify({
          orderHash: order.orderHash,
          createdAt: Math.floor(order.createdAt.getTime() / 1000),
          notifiedAt: Date.now(),
          signature: order.protocolSignature,
          orderStatus: order.publicStatus,
          encodedOrder: order.encodedOrder,
          chainId: this.#env.chainId,
          filler: order.filler,
          quoteId: order.quoteId,
          offerer: order.swapper,
          type: "Priority",
        }),
      });
    } catch {
      // Best-effort only in v1.
    } finally {
      clearTimeout(timeout);
    }
  }
}
