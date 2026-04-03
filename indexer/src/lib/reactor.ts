import { encodeAbiParameters, keccak256, parseAbiParameters, toHex } from "viem";

export const OUTPUT_TYPEHASH = keccak256(toHex("Output(address token,uint256 amount,address recipient)"));
export const REQUEST_TYPEHASH = keccak256(
  toHex(
    "Request(address tokenIn,uint256 amountIn,Output[] outputs,uint256 deadline,uint256 nonce,address protocol)Output(address token,uint256 amount,address recipient)",
  ),
);
export const ORDER_TYPEHASH = keccak256(
  toHex(
    "Order(Request request,bytes swapperSignature,address swapper,address filler)Output(address token,uint256 amount,address recipient)Request(address tokenIn,uint256 amountIn,Output[] outputs,uint256 deadline,uint256 nonce,address protocol)",
  ),
);

type Output = {
  readonly token: `0x${string}`;
  readonly amount: bigint;
  readonly recipient: `0x${string}`;
};

type Request = {
  readonly tokenIn: `0x${string}`;
  readonly amountIn: bigint;
  readonly outputs: readonly Output[];
  readonly deadline: bigint;
  readonly nonce: bigint;
  readonly protocol: `0x${string}`;
};

export type Order = {
  readonly request: Request;
  readonly swapperSignature: `0x${string}`;
  readonly swapper: `0x${string}`;
  readonly filler: `0x${string}`;
};

const outputAbiParameters = parseAbiParameters("bytes32 typehash,address token,uint256 amount,address recipient");
const requestAbiParameters = parseAbiParameters(
  "bytes32 typehash,address tokenIn,uint256 amountIn,bytes32 outputsHash,uint256 deadline,uint256 nonce,address protocol",
);
const orderAbiParameters = parseAbiParameters(
  "bytes32 typehash,bytes32 requestHash,bytes32 swapperSignatureHash,address swapper,address filler",
);

/**
 * @dev Hashes an indexed Reactor order with the same layout as the onchain contract.
 * @param order The Reactor order.
 * @returns The `orderHash` join key.
 */
export function hashOrder(order: Order): `0x${string}` {
  const outputHashes = order.request.outputs.map((output) =>
    keccak256(
      encodeAbiParameters(outputAbiParameters, [OUTPUT_TYPEHASH, output.token, output.amount, output.recipient]),
    ),
  );
  const outputsHash = keccak256(`0x${outputHashes.map((hash) => hash.slice(2)).join("")}`);
  const requestHash = keccak256(
    encodeAbiParameters(requestAbiParameters, [
      REQUEST_TYPEHASH,
      order.request.tokenIn,
      order.request.amountIn,
      outputsHash,
      order.request.deadline,
      order.request.nonce,
      order.request.protocol,
    ]),
  );

  return keccak256(
    encodeAbiParameters(orderAbiParameters, [
      ORDER_TYPEHASH,
      requestHash,
      keccak256(order.swapperSignature),
      order.swapper,
      order.filler,
    ]),
  );
}
