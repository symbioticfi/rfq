import {
  encodeAbiParameters,
  getAddress,
  hashTypedData,
  keccak256,
  padHex,
  parseAbiParameters,
  toHex,
  verifyTypedData,
} from "viem";

import type { OrderOutput, PermitData } from "../types/domain";

export const NATIVE = "0x0000000000000000000000000000000000000000";
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

export type ReactorOutput = {
  readonly token: `0x${string}`;
  readonly amount: bigint;
  readonly recipient: `0x${string}`;
};

export type ReactorRequest = {
  readonly tokenIn: `0x${string}`;
  readonly amountIn: bigint;
  readonly outputs: readonly ReactorOutput[];
  readonly deadline: bigint;
  readonly nonce: bigint;
  readonly protocol: `0x${string}`;
};

export type ReactorOrder = {
  readonly request: ReactorRequest;
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
const orderEncodingParameters = parseAbiParameters(
  "((address tokenIn,uint256 amountIn,(address token,uint256 amount,address recipient)[] outputs,uint256 deadline,uint256 nonce,address protocol) request,bytes swapperSignature,address swapper,address filler)",
);

export function getLowercasedAddress<T extends string | null | undefined>(value: T): T {
  if (typeof value !== "string" || !value.startsWith("0x")) {
    return value;
  }

  return getAddress(value).toLowerCase() as T;
}

/**
 * @dev Hashes a single Reactor output.
 * @param output The Reactor output.
 * @returns The EIP-712 struct hash of the output.
 */
export function hashOutput(output: ReactorOutput): `0x${string}` {
  return keccak256(
    encodeAbiParameters(outputAbiParameters, [OUTPUT_TYPEHASH, output.token, output.amount, output.recipient]),
  );
}

/**
 * @dev Hashes a Reactor request using the same layout as the onchain Reactor.
 * @param request The Reactor request.
 * @returns The EIP-712 struct hash of the request.
 */
export function hashRequest(request: ReactorRequest): `0x${string}` {
  const outputHashes = request.outputs.map(hashOutput);
  const outputsHash = keccak256(`0x${outputHashes.map((hash) => hash.slice(2)).join("")}`);

  return keccak256(
    encodeAbiParameters(requestAbiParameters, [
      REQUEST_TYPEHASH,
      request.tokenIn,
      request.amountIn,
      outputsHash,
      request.deadline,
      request.nonce,
      request.protocol,
    ]),
  );
}

/**
 * @dev Hashes a Reactor order using the same layout as the onchain Reactor.
 * @param order The Reactor order.
 * @returns The EIP-712 struct hash of the order.
 */
export function hashOrder(order: ReactorOrder): `0x${string}` {
  return keccak256(
    encodeAbiParameters(orderAbiParameters, [
      ORDER_TYPEHASH,
      hashRequest(order.request),
      keccak256(order.swapperSignature),
      order.swapper,
      order.filler,
    ]),
  );
}

/**
 * @dev Encodes a Reactor order for backend delivery to solvers.
 * @param order The Reactor order.
 * @returns ABI-encoded order bytes.
 */
export function encodeOrder(order: ReactorOrder): `0x${string}` {
  return encodeAbiParameters(orderEncodingParameters, [
    {
      request: {
        tokenIn: order.request.tokenIn,
        amountIn: order.request.amountIn,
        outputs: order.request.outputs,
        deadline: order.request.deadline,
        nonce: order.request.nonce,
        protocol: order.request.protocol,
      },
      swapperSignature: order.swapperSignature,
      swapper: order.swapper,
      filler: order.filler,
    },
  ]);
}

/**
 * @dev Builds Permit2 witness typed data for a Reactor request.
 * @param input The request + Permit2 context.
 * @returns EIP-712 typed data payload compatible with Permit2 witness signing.
 */
export function buildPermitData(input: {
  readonly permit2: `0x${string}`;
  readonly reactor: `0x${string}`;
  readonly chainId: number;
  readonly request: ReactorRequest;
}): PermitData {
  return {
    domain: {
      name: "Permit2",
      chainId: input.chainId,
      verifyingContract: input.permit2,
    },
    types: {
      TokenPermissions: [
        { name: "token", type: "address" },
        { name: "amount", type: "uint256" },
      ],
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
      PermitWitnessTransferFrom: [
        { name: "permitted", type: "TokenPermissions" },
        { name: "spender", type: "address" },
        { name: "nonce", type: "uint256" },
        { name: "deadline", type: "uint256" },
        { name: "witness", type: "Request" },
      ],
    },
    value: {
      permitted: {
        token: input.request.tokenIn,
        amount: input.request.amountIn.toString(),
      },
      spender: input.reactor,
      nonce: input.request.nonce.toString(),
      deadline: input.request.deadline.toString(),
      witness: {
        tokenIn: input.request.tokenIn,
        amountIn: input.request.amountIn.toString(),
        outputs: input.request.outputs.map((output) => ({
          token: output.token,
          amount: output.amount.toString(),
          recipient: output.recipient,
        })),
        deadline: input.request.deadline.toString(),
        nonce: input.request.nonce.toString(),
        protocol: input.request.protocol,
      },
    },
  };
}

/**
 * @dev Verifies a Permit2 witness signature against the expected swapper.
 * @param address The expected swapper.
 * @param permitData The typed data previously returned by `buildPermitData`.
 * @param signature The submitted swapper signature.
 * @returns Whether the signature is valid.
 */
export async function verifyPermitSignature(
  address: `0x${string}`,
  permitData: PermitData,
  signature: `0x${string}`,
): Promise<boolean> {
  const verify = verifyTypedData as (input: {
    readonly address: `0x${string}`;
    readonly domain: Record<string, unknown>;
    readonly types: Record<string, ReadonlyArray<Record<string, string>>>;
    readonly primaryType: string;
    readonly message: Record<string, unknown>;
    readonly signature: `0x${string}`;
  }) => Promise<boolean>;

  return verify({
    address,
    domain: permitData.domain,
    types: permitData.types,
    primaryType: "PermitWitnessTransferFrom",
    message: permitData.value,
    signature,
  });
}

/**
 * @dev Converts public output obligations into Reactor output structs.
 * @param outputs Public order outputs.
 * @returns Reactor output structs with bigint amounts.
 */
export function toReactorOutputs(outputs: readonly OrderOutput[]): ReactorOutput[] {
  return outputs.map((output) => ({
    token: getAddress(output.token),
    amount: BigInt(output.amount),
    recipient: getAddress(output.recipient),
  }));
}

/**
 * @dev Builds a 32-byte nonce hex string from a bigint.
 * @param nonce The nonce value.
 * @returns The padded hex nonce string.
 */
export function toNonceHex(nonce: bigint): `0x${string}` {
  return padHex(toHex(nonce), { size: 32 });
}
