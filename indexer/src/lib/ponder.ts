import { getAddress } from "viem";

export function normalizeAddress<T extends string>(value: T): T {
  return getAddress(value) as T;
}
