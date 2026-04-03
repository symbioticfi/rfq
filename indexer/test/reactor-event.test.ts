import { describe, expect, it } from "vitest";
import { getAddress } from "viem";

import { hashOrder } from "../src/lib/reactor";
import { mapReactorFillEvent } from "../src/indexer/contracts/reactor-event";

describe("mapReactorFillEvent", () => {
  it("computes the backend-compatible order hash and normalizes output rows", () => {
    const event = {
      transaction: {
        hash: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      },
      log: {
        logIndex: 7,
      },
      block: {
        number: 123n,
        timestamp: 456n,
      },
      args: {
        order: {
          request: {
            tokenIn: "0x1111111111111111111111111111111111111111",
            amountIn: 100n,
            outputs: [
              {
                token: "0x2222222222222222222222222222222222222222",
                amount: 90n,
                recipient: "0x3333333333333333333333333333333333333333",
              },
              {
                token: "0x4444444444444444444444444444444444444444",
                amount: 10n,
                recipient: "0x5555555555555555555555555555555555555555",
              },
            ],
            deadline: 789n,
            nonce: 1n,
            protocol: "0x6666666666666666666666666666666666666666",
          },
          swapperSignature: "0x1234",
          swapper: "0x7777777777777777777777777777777777777777",
          filler: "0x8888888888888888888888888888888888888888",
        },
      },
    } as const;

    const { fill, outputs } = mapReactorFillEvent(1, event);
    const expectedOrderHash = hashOrder({
      request: {
        tokenIn: event.args.order.request.tokenIn,
        amountIn: event.args.order.request.amountIn,
        outputs: event.args.order.request.outputs,
        deadline: event.args.order.request.deadline,
        nonce: event.args.order.request.nonce,
        protocol: event.args.order.request.protocol,
      },
      swapperSignature: event.args.order.swapperSignature,
      swapper: event.args.order.swapper,
      filler: event.args.order.filler,
    });

    expect(fill).toMatchObject({
      id: "1:0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:7",
      chainId: 1,
      blockNumber: 123n,
      blockTimestamp: 456n,
      txHash: event.transaction.hash,
      logIndex: 7,
      orderHash: expectedOrderHash,
      tokenIn: event.args.order.request.tokenIn,
      amountIn: 100n,
      deadline: 789n,
      nonce: 1n,
      protocol: event.args.order.request.protocol,
    });
    expect(outputs).toEqual([
      {
        fillId: fill.id,
        outputIndex: 0,
        token: "0x2222222222222222222222222222222222222222",
        recipient: "0x3333333333333333333333333333333333333333",
        amount: 90n,
      },
      {
        fillId: fill.id,
        outputIndex: 1,
        token: "0x4444444444444444444444444444444444444444",
        recipient: "0x5555555555555555555555555555555555555555",
        amount: 10n,
      },
    ]);
  });

  it("checksum-normalizes mixed-case addresses before storing them", () => {
    const event = {
      transaction: {
        hash: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      },
      log: {
        logIndex: 1,
      },
      block: {
        number: 1n,
        timestamp: 2n,
      },
      args: {
        order: {
          request: {
            tokenIn: "0xAbCdEf0000000000000000000000000000000001",
            amountIn: 10n,
            outputs: [
              {
                token: "0xAbCdEf0000000000000000000000000000000002",
                amount: 9n,
                recipient: "0xAbCdEf0000000000000000000000000000000003",
              },
            ],
            deadline: 3n,
            nonce: 4n,
            protocol: "0xAbCdEf0000000000000000000000000000000004",
          },
          swapperSignature: "0x1234",
          swapper: "0xAbCdEf0000000000000000000000000000000005",
          filler: "0xAbCdEf0000000000000000000000000000000006",
        },
      },
    } as const;

    const { fill, outputs } = mapReactorFillEvent(1, event);

    expect(fill.tokenIn).toBe(getAddress(event.args.order.request.tokenIn));
    expect(fill.protocol).toBe(getAddress(event.args.order.request.protocol));
    expect(fill.swapper).toBe(getAddress(event.args.order.swapper));
    expect(fill.filler).toBe(getAddress(event.args.order.filler));
    expect(outputs[0]).toMatchObject({
      token: getAddress(event.args.order.request.outputs[0]!.token),
      recipient: getAddress(event.args.order.request.outputs[0]!.recipient),
    });
  });
});
