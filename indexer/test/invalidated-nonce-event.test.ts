import { describe, expect, it } from "vitest";
import { getAddress } from "viem";

import { mapInvalidateNonceEvent } from "../src/indexer/contracts/invalidated-nonce-event";

describe("mapInvalidateNonceEvent", () => {
  it("maps InvalidateNonce events into the current invalidation row", () => {
    const row = mapInvalidateNonceEvent(560048, {
      transaction: {
        hash: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      },
      log: {
        logIndex: 7,
      },
      block: {
        number: 54321n,
      },
      args: {
        vault: "0xAbCdEf0000000000000000000000000000000001",
        tokenToRedeem: "0xAbCdEf0000000000000000000000000000000004",
        nonce: 42n,
      },
    });

    const expectedVault = getAddress("0xAbCdEf0000000000000000000000000000000001");
    const expectedTokenToRedeem = getAddress("0xAbCdEf0000000000000000000000000000000004");

    expect(row).toEqual({
      id: `560048:${expectedVault}:${expectedTokenToRedeem}:42`,
      chainId: 560048,
      vault: expectedVault,
      tokenToRedeem: expectedTokenToRedeem,
      nonce: 42n,
      txHash: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      blockNumber: 54321,
      logIndex: 7,
    });
  });
});
