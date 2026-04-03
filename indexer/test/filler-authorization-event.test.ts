import { describe, expect, it } from "vitest";
import { getAddress } from "viem";

import { mapSetFillerEvent } from "../src/indexer/contracts/filler-authorization-event";

describe("mapSetFillerEvent", () => {
  it("maps SetFiller events into the current authorization row", () => {
    const row = mapSetFillerEvent(560048, {
      transaction: {
        hash: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      },
      log: {
        logIndex: 3,
      },
      block: {
        number: 12345n,
      },
      args: {
        vault: "0xAbCdEf0000000000000000000000000000000001",
        marketMaker: "0xAbCdEf0000000000000000000000000000000002",
        filler: "0xAbCdEf0000000000000000000000000000000003",
        isAuthorized: true,
      },
    });

    const expectedMarketMaker = getAddress("0xAbCdEf0000000000000000000000000000000002");
    const expectedFiller = getAddress("0xAbCdEf0000000000000000000000000000000003");

    expect(row).toEqual({
      id: `560048:${expectedMarketMaker}:${expectedFiller}`,
      chainId: 560048,
      marketMaker: expectedMarketMaker,
      filler: expectedFiller,
      status: true,
      txHash: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      blockNumber: 12345,
      logIndex: 3,
    });
  });
});
