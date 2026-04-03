import { instantRedemptionAdapterAbi, vaultAbi, curatorRegistryAbi } from "../lib/contracts";
import { getLowercasedAddress } from "../lib/reactor";
import { hashDiscount, signDiscountSwap, verifyDiscountSignature } from "../lib/discounts";
import type {
  Discount,
  DiscountFilters,
  DiscountListItem,
  DiscountRecord,
  DiscountsResponse,
  PublishDiscountRequest,
  PublishDiscountResponse,
  ResolvedDiscount,
  ResolveDiscountRequest,
  ResolveDiscountsResponse,
  ResolveDiscountResponse,
} from "../types/domain";
import type { BackendRepositories } from "../types/repositories";
import { newUuid } from "../utils/ids";
import type { BackendEnv } from "../config/env";
import type { PublicClient } from "./shared";

const DISCOUNT_SCALE = 1_000_000n;
const RATE_SCALE = 10n ** 18n;

type DiscountSelector =
  | {
      readonly kind: "all";
    }
  | {
      readonly kind: "ids";
      readonly discountIds: readonly `0x${string}`[];
    }
  | {
      readonly kind: "pairs";
      readonly pairs: readonly {
        readonly vault: `0x${string}`;
        readonly tokenToRedeem: `0x${string}`;
      }[];
    };

export class DiscountService {
  readonly #env: BackendEnv;
  readonly #publicClient: PublicClient;
  readonly #repositories: BackendRepositories;
  readonly #now: () => Date;

  constructor(input: {
    readonly env: BackendEnv;
    readonly publicClient: PublicClient;
    readonly repositories: BackendRepositories;
    readonly now: () => Date;
  }) {
    this.#env = input.env;
    this.#publicClient = input.publicClient;
    this.#repositories = input.repositories;
    this.#now = input.now;
  }

  async listLive(filters?: DiscountFilters): Promise<DiscountsResponse> {
    const rows = this.#selectRows(await this.#repositories.discounts.listLive(this.#env.chainId), this.#normalizeSelector(filters));
    const discounts: DiscountListItem[] = [];

    for (const row of rows) {
      const validated = await this.#validateStoredDiscount(row);
      if (!validated) {
        continue;
      }
      discounts.push(validated);
    }

    return {
      requestId: newUuid(),
      protocol: this.#env.protocolSignerAddress,
      discounts,
    };
  }

  async publish(input: PublishDiscountRequest): Promise<PublishDiscountResponse> {
    const discount = {
      ...input.discount,
      vault: getLowercasedAddress(input.discount.vault),
      tokenToRedeem: getLowercasedAddress(input.discount.tokenToRedeem),
      signer: getLowercasedAddress(input.discount.signer),
      protocol: getLowercasedAddress(input.discount.protocol),
      nonce: input.discount.nonce.toLowerCase() as `0x${string}`,
    } satisfies Discount;

    await this.#assertDiscountIsLivePublishable(discount, input.signature);

    const now = this.#now();
    const discountId = hashDiscount({ env: this.#env, discount });
    await this.#repositories.discounts.upsertLive({
      discountId,
      chainId: this.#env.chainId,
      vault: discount.vault,
      tokenToRedeem: discount.tokenToRedeem,
      discountPpm: discount.discount,
      signer: discount.signer,
      protocol: discount.protocol,
      nonce: discount.nonce,
      deadline: discount.deadline,
      signerSignature: input.signature,
      createdAt: now,
      updatedAt: now,
    });

    return {
      requestId: newUuid(),
      discountId,
    };
  }

  async resolve(input: ResolveDiscountRequest): Promise<ResolveDiscountResponse | ResolveDiscountsResponse> {
    const selector = this.#normalizeSelector(input);
    if (selector.kind === "all") {
      throw new Error("Unknown discount");
    }
    const records = await this.#loadRecordsForSelector(selector);
    const requestId = newUuid();
    const resolvedDiscounts = await Promise.all(records.map((record) => this.#resolveRecord(record)));

    if (selector.kind === "ids" && selector.discountIds.length > 1) {
      return {
        requestId,
        discounts: resolvedDiscounts,
      };
    }
    if (selector.kind === "pairs" && selector.pairs.length > 1) {
      return {
        requestId,
        discounts: resolvedDiscounts,
      };
    }

    return {
      requestId,
      ...resolvedDiscounts[0]!,
    };
  }

  async #validateStoredDiscount(
    record: DiscountRecord,
    options: { strict?: boolean } = {},
  ): Promise<DiscountListItem | null> {
    const nowUnix = Math.floor(this.#now().getTime() / 1000);
    if (record.deadline <= nowUnix) {
      await this.#repositories.discounts.deleteByDiscountId(record.discountId);
      if (options.strict) {
        throw new Error("Discount expired");
      }
      return null;
    }

    const nonceUsed = (await this.#publicClient.readContract({
      address: this.#env.instantRedemptionAdapterAddress,
      abi: instantRedemptionAdapterAbi,
      functionName: "isUsedNonce",
      args: [record.vault, record.tokenToRedeem, BigInt(record.nonce)],
    })) as boolean;
    if (nonceUsed) {
      await this.#repositories.discounts.deleteByDiscountId(record.discountId);
      if (options.strict) {
        throw new Error("Discount nonce invalidated");
      }
      return null;
    }

    const [paused, maxAssets, collateral, curator, marketMaker] = await Promise.all([
      this.#publicClient.readContract({
        address: this.#env.instantRedemptionAdapterAddress,
        abi: instantRedemptionAdapterAbi,
        functionName: "isPaused",
        args: [record.vault],
      }) as Promise<boolean>,
      this.#publicClient.readContract({
        address: this.#env.instantRedemptionAdapterAddress,
        abi: instantRedemptionAdapterAbi,
        functionName: "getMaxAssets",
        args: [record.vault],
      }) as Promise<bigint>,
      this.#publicClient.readContract({
        address: record.vault,
        abi: vaultAbi,
        functionName: "collateral",
      }) as Promise<`0x${string}`>,
      this.#publicClient.readContract({
        address: this.#env.curatorRegistryAddress,
        abi: curatorRegistryAbi,
        functionName: "getCurator",
        args: [record.vault],
      }) as Promise<`0x${string}`>,
      this.#publicClient.readContract({
        address: this.#env.instantRedemptionAdapterAddress,
        abi: instantRedemptionAdapterAbi,
        functionName: "marketMaker",
        args: [record.vault],
      }) as Promise<`0x${string}`>,
    ]);

    if (paused) {
      if (options.strict) {
        throw new Error("Discount vault is paused");
      }
      return null;
    }

    const signer = record.signer;
    const normalizedCurator = getLowercasedAddress(curator);
    const normalizedMarketMaker = getLowercasedAddress(marketMaker);
    const isAuthorizedSigner =
      signer === normalizedCurator ||
      signer === normalizedMarketMaker ||
      ((await this.#publicClient.readContract({
        address: this.#env.instantRedemptionAdapterAddress,
        abi: instantRedemptionAdapterAbi,
        functionName: "isFiller",
        args: [normalizedMarketMaker, signer],
      })) as boolean);
    if (!isAuthorizedSigner) {
      if (options.strict) {
        throw new Error("Discount signer is not authorized");
      }
      return null;
    }

    const collateralAddress = getLowercasedAddress(collateral);
    const collateralToken = this.#env.deployment.tokens.output.find(
      (token) => getLowercasedAddress(token.address) === collateralAddress,
    );
    const inputToken = this.#env.deployment.tokens.input.find(
      (token) => getLowercasedAddress(token.address) === record.tokenToRedeem,
    );
    if (!collateralToken || !inputToken) {
      if (options.strict) {
        throw new Error("Discount pair is not supported");
      }
      return null;
    }

    const oracleAmountOut = (await this.#publicClient.readContract({
      address: this.#env.instantRedemptionAdapterAddress,
      abi: instantRedemptionAdapterAbi,
      functionName: "getAmountOut",
      args: [record.tokenToRedeem, collateralAddress, 10n ** BigInt(inputToken.decimals)],
    })) as bigint;
    const discountedAmountOut = (oracleAmountOut * (DISCOUNT_SCALE - BigInt(record.discountPpm))) / DISCOUNT_SCALE;
    const maxRate = (discountedAmountOut * RATE_SCALE) / (10n ** BigInt(collateralToken.decimals));
    if (maxAssets <= 0n || maxRate <= 0n) {
      return null;
    }

    return {
      discountId: record.discountId,
      vault: record.vault,
      tokenToRedeem: record.tokenToRedeem,
      collateral: collateralAddress,
      collateralDecimals: collateralToken.decimals,
      discount: record.discountPpm,
      signer: record.signer,
      deadline: record.deadline,
      maxRate: maxRate.toString(),
      maxAssets: maxAssets.toString(),
    };
  }

  async #assertDiscountIsLivePublishable(discount: Discount, signature: `0x${string}`) {
    if (discount.protocol !== this.#env.protocolSignerAddress) {
      throw new Error("Invalid discount protocol");
    }
    if (discount.deadline <= Math.floor(this.#now().getTime() / 1000)) {
      throw new Error("Discount expired");
    }

    const signatureValid = await verifyDiscountSignature({
      env: this.#env,
      discount,
      signature,
    });
    if (!signatureValid) {
      throw new Error("Invalid discount signature");
    }

    const [minDiscount, nonceUsed, collateral, curator, marketMaker] = await Promise.all([
      this.#publicClient.readContract({
        address: this.#env.instantRedemptionAdapterAddress,
        abi: instantRedemptionAdapterAbi,
        functionName: "minDiscount",
        args: [discount.vault, discount.tokenToRedeem],
      }) as Promise<bigint>,
      this.#publicClient.readContract({
        address: this.#env.instantRedemptionAdapterAddress,
        abi: instantRedemptionAdapterAbi,
        functionName: "isUsedNonce",
        args: [discount.vault, discount.tokenToRedeem, BigInt(discount.nonce)],
      }) as Promise<boolean>,
      this.#publicClient.readContract({
        address: discount.vault,
        abi: vaultAbi,
        functionName: "collateral",
      }) as Promise<`0x${string}`>,
      this.#publicClient.readContract({
        address: this.#env.curatorRegistryAddress,
        abi: curatorRegistryAbi,
        functionName: "getCurator",
        args: [discount.vault],
      }) as Promise<`0x${string}`>,
      this.#publicClient.readContract({
        address: this.#env.instantRedemptionAdapterAddress,
        abi: instantRedemptionAdapterAbi,
        functionName: "marketMaker",
        args: [discount.vault],
      }) as Promise<`0x${string}`>,
    ]);

    if (nonceUsed) {
      throw new Error("Discount nonce already used");
    }
    if (BigInt(discount.discount) < minDiscount || BigInt(discount.discount) > DISCOUNT_SCALE) {
      throw new Error("Invalid discount");
    }

    const normalizedSigner = discount.signer;
    const normalizedCurator = getLowercasedAddress(curator);
    const normalizedMarketMaker = getLowercasedAddress(marketMaker);
    const isAuthorizedFiller =
      normalizedSigner !== normalizedCurator &&
      normalizedSigner !== normalizedMarketMaker &&
      ((await this.#publicClient.readContract({
        address: this.#env.instantRedemptionAdapterAddress,
        abi: instantRedemptionAdapterAbi,
        functionName: "isFiller",
        args: [normalizedMarketMaker, normalizedSigner],
      })) as boolean);
    if (!isAuthorizedFiller && normalizedSigner !== normalizedCurator && normalizedSigner !== normalizedMarketMaker) {
      throw new Error("Invalid discount signer");
    }

    await this.#publicClient.readContract({
      address: this.#env.instantRedemptionAdapterAddress,
      abi: instantRedemptionAdapterAbi,
      functionName: "getAmountOut",
      args: [discount.tokenToRedeem, getLowercasedAddress(collateral), 1n],
    });
  }

  #toDiscount(record: DiscountRecord): Discount {
    return {
      vault: record.vault,
      tokenToRedeem: record.tokenToRedeem,
      discount: record.discountPpm,
      signer: record.signer,
      protocol: record.protocol,
      nonce: record.nonce,
      deadline: record.deadline,
    };
  }

  #normalizeSelector(input?: DiscountFilters | ResolveDiscountRequest): DiscountSelector {
    if (!input) {
      return { kind: "all" };
    }
    if ("discountId" in input && input.discountId) {
      return {
        kind: "ids",
        discountIds: [input.discountId],
      };
    }
    if ("discountIds" in input && input.discountIds) {
      return {
        kind: "ids",
        discountIds: input.discountIds,
      };
    }
    if ("vault" in input && input.vault && "tokenToRedeem" in input && input.tokenToRedeem) {
      return {
        kind: "pairs",
        pairs: [
          {
            vault: getLowercasedAddress(input.vault),
            tokenToRedeem: getLowercasedAddress(input.tokenToRedeem),
          },
        ],
      };
    }
    if ("vaults" in input && input.vaults && "tokensToRedeem" in input && input.tokensToRedeem) {
      return {
        kind: "pairs",
        pairs: input.vaults.map((vault, index) => ({
          vault: getLowercasedAddress(vault),
          tokenToRedeem: getLowercasedAddress(input.tokensToRedeem[index]!),
        })),
      };
    }

    return { kind: "all" };
  }

  #selectRows(rows: readonly DiscountRecord[], selector: DiscountSelector) {
    if (selector.kind === "all") {
      return rows;
    }
    if (selector.kind === "ids") {
      const rowsById = new Map(rows.map((row) => [row.discountId, row] as const));
      return selector.discountIds.flatMap((discountId) => {
        const row = rowsById.get(discountId);
        return row ? [row] : [];
      });
    }

    const rowsByPair = new Map(rows.map((row) => [`${row.vault}:${row.tokenToRedeem}`, row] as const));
    return selector.pairs.flatMap((pair) => {
      const row = rowsByPair.get(`${pair.vault}:${pair.tokenToRedeem}`);
      return row ? [row] : [];
    });
  }

  async #loadRecordsForSelector(selector: Exclude<DiscountSelector, { readonly kind: "all" }>) {
    if (selector.kind === "ids") {
      const records = await Promise.all(
        selector.discountIds.map((discountId) => this.#repositories.discounts.findByDiscountId(discountId)),
      );
      if (records.some((record) => !record)) {
        throw new Error("Unknown discount");
      }
      return records as DiscountRecord[];
    }

    const records = await Promise.all(
      selector.pairs.map((pair) =>
        this.#repositories.discounts.findByPair(this.#env.chainId, pair.vault, pair.tokenToRedeem),
      ),
    );
    if (records.some((record) => !record)) {
      throw new Error("Unknown discount");
    }
    return records as DiscountRecord[];
  }

  async #resolveRecord(record: DiscountRecord): Promise<ResolvedDiscount> {
    const validated = await this.#validateStoredDiscount(record, { strict: true });
    if (!validated) {
      throw new Error("Discount is no longer live");
    }

    const protocolDeadline = Math.floor(this.#now().getTime() / 1000) + 90;
    const signed = await signDiscountSwap({
      env: this.#env,
      discount: this.#toDiscount(record),
      signerSignature: record.signerSignature,
      protocolDeadline,
    });

    return {
      discountId: record.discountId,
      discount: this.#toDiscount(record),
      signerSignature: record.signerSignature,
      protocolDeadline: signed.protocolDeadline,
      protocolSignature: signed.protocolSignature,
    };
  }
}
