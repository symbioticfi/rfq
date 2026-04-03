import { hashTypedData, verifyTypedData } from "viem";

import type { BackendEnv } from "../config/env";
import type { Discount, DiscountRecord } from "../types/domain";

const discountTypes = {
  Discount: [
    { name: "vault", type: "address" },
    { name: "tokenToRedeem", type: "address" },
    { name: "discount", type: "uint256" },
    { name: "signer", type: "address" },
    { name: "protocol", type: "address" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint48" },
  ],
} as const;

const discountSwapTypes = {
  Discount: discountTypes.Discount,
  DiscountSwap: [
    { name: "discount", type: "Discount" },
    { name: "signerSignature", type: "bytes" },
    { name: "protocolDeadline", type: "uint48" },
  ],
} as const;

export function adapterDomain(env: Pick<BackendEnv, "chainId" | "instantRedemptionAdapterAddress">) {
  return {
    name: "InstantRedemptionAdapter",
    version: "1",
    chainId: env.chainId,
    verifyingContract: env.instantRedemptionAdapterAddress,
  } as const;
}

export function toTypedDiscount(discount: Discount | DiscountRecord) {
  return {
    vault: discount.vault,
    tokenToRedeem: discount.tokenToRedeem,
    discount: BigInt("discountPpm" in discount ? discount.discountPpm : discount.discount),
    signer: discount.signer,
    protocol: discount.protocol,
    nonce: BigInt(discount.nonce),
    deadline: discount.deadline,
  } as const;
}

export async function verifyDiscountSignature(input: {
  readonly env: Pick<BackendEnv, "chainId" | "instantRedemptionAdapterAddress">;
  readonly discount: Discount | DiscountRecord;
  readonly signature: `0x${string}`;
}) {
  return verifyTypedData({
    address: input.discount.signer,
    domain: adapterDomain(input.env),
    types: discountTypes,
    primaryType: "Discount",
    message: toTypedDiscount(input.discount),
    signature: input.signature,
  });
}

export function hashDiscount(input: {
  readonly env: Pick<BackendEnv, "chainId" | "instantRedemptionAdapterAddress">;
  readonly discount: Discount | DiscountRecord;
}) {
  return hashTypedData({
    domain: adapterDomain(input.env),
    types: discountTypes,
    primaryType: "Discount",
    message: toTypedDiscount(input.discount),
  });
}

export async function signDiscountSwap(input: {
  readonly env: Pick<BackendEnv, "chainId" | "instantRedemptionAdapterAddress" | "protocolSigner">;
  readonly discount: Discount | DiscountRecord;
  readonly signerSignature: `0x${string}`;
  readonly protocolDeadline: number;
}) {
  const message = {
    discount: toTypedDiscount(input.discount),
    signerSignature: input.signerSignature,
    protocolDeadline: input.protocolDeadline,
  } as const;

  const protocolSignature = await input.env.protocolSigner.signTypedData({
    domain: adapterDomain(input.env),
    types: discountSwapTypes,
    primaryType: "DiscountSwap",
    message,
  });

  return {
    protocolDeadline: input.protocolDeadline,
    protocolSignature,
  };
}
