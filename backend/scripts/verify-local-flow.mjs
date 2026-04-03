import fs from "node:fs/promises";
import process from "node:process";
import { fileURLToPath } from "node:url";

import { createPublicClient, createWalletClient, erc20Abi, http, parseAbi } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { foundry } from "viem/chains";

const backendUrl = process.env.RFQ_BACKEND_URL || "http://127.0.0.1:42072";
const explicitIndexerUrl = process.env.RFQ_INDEXER_URL;
const defaultIndexerUrls = ["http://127.0.0.1:42069", "http://127.0.0.1:42070"];
const rpcUrl = process.env.RFQ_RPC_URL || "http://127.0.0.1:8545";
const defaultManifestPath = fileURLToPath(new URL("../deployments/local/addresses.json", import.meta.url));
const manifestPath =
  process.env.RFQ_DEPLOYMENT_MANIFEST || defaultManifestPath;
const walletPrivateKey =
  process.env.RFQ_TEST_WALLET_PRIVATE_KEY || "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
const inputAmount = process.env.RFQ_TEST_AMOUNT_WEI || (23n * 10n ** 18n).toString();

const terminalStatuses = new Set(["filled", "expired", "error", "cancelled", "unverified", "insufficient-funds"]);

function log(stage, payload) {
  console.log(JSON.stringify({ stage, ...payload }));
}

function fail(message, details) {
  console.error(JSON.stringify({ stage: "error", message, details }));
  process.exit(1);
}

async function postJson(path, body) {
  const response = await fetch(`${backendUrl}${path}`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
  const text = await response.text();
  return {
    response,
    data: text ? JSON.parse(text) : null,
  };
}

async function getJson(url) {
  const response = await fetch(url);
  const text = await response.text();
  return {
    response,
    data: text ? JSON.parse(text) : null,
  };
}

async function queryIndexer(txHash) {
  const indexerUrl = await resolveIndexerUrl();
  const response = await fetch(`${indexerUrl}/graphql`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
    },
    body: JSON.stringify({
      query: `
                query LatestFills {
                    reactorFills(limit: 10, orderBy: "blockNumber", orderDirection: "desc") {
                        items {
                            txHash
                            orderHash
                            blockNumber
                        }
                    }
                }
            `,
    }),
  });

  const text = await response.text();
  const data = text ? JSON.parse(text) : null;
  if (!response.ok || !data?.data?.reactorFills?.items) {
    fail("Indexer GraphQL query failed", { status: response.status, data });
  }

  return data.data.reactorFills.items.find((item) => item.txHash?.toLowerCase() === txHash.toLowerCase()) ?? null;
}

let resolvedIndexerUrlPromise;

async function resolveIndexerUrl() {
  if (!resolvedIndexerUrlPromise) {
    resolvedIndexerUrlPromise = resolveIndexerUrlOnce();
  }

  return resolvedIndexerUrlPromise;
}

async function resolveIndexerUrlOnce() {
  const candidates = explicitIndexerUrl ? [explicitIndexerUrl] : defaultIndexerUrls;

  for (const candidate of candidates) {
    try {
      const response = await fetch(`${candidate}/graphql`, {
        method: "POST",
        headers: {
          "content-type": "application/json",
        },
        body: JSON.stringify({
          query: "{ __typename }",
        }),
      });
      const text = await response.text();
      const data = text ? JSON.parse(text) : null;

      if (response.ok && data?.data?.__typename === "Query") {
        log("indexer-target", { indexerUrl: candidate });
        return candidate;
      }
    } catch {}
  }

  fail("Could not find a healthy indexer GraphQL endpoint", { candidates });
}

async function main() {
  const manifest = JSON.parse(await fs.readFile(manifestPath, "utf8"));
  const account = privateKeyToAccount(walletPrivateKey);
  const inputToken = manifest.tokens.defaultInput;
  const outputToken = manifest.tokens.defaultOutput;

  const publicClient = createPublicClient({
    chain: foundry,
    transport: http(rpcUrl),
  });
  const walletClient = createWalletClient({
    account,
    chain: foundry,
    transport: http(rpcUrl),
  });

  const balanceBefore = await publicClient.readContract({
    address: inputToken,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [account.address],
  });
  log("balance-before", {
    wallet: account.address,
    inputToken,
    inputBalance: balanceBefore.toString(),
  });

  const funding = await postJson("/dev/fund", {
    walletAddress: account.address,
  });
  log("fund", {
    status: funding.response.status,
    data: funding.data,
  });
  if (!funding.response.ok) {
    fail("Local funding failed", funding.data);
  }

  const balanceAfter = await publicClient.readContract({
    address: inputToken,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [account.address],
  });
  log("balance-after", {
    wallet: account.address,
    inputBalance: balanceAfter.toString(),
  });
  if (balanceAfter === 0n) {
    fail("Wallet still has zero input balance after local funding", {
      wallet: account.address,
      inputToken,
    });
  }

  const approval = await postJson("/check_approval", {
    walletAddress: account.address,
    chainId: manifest.chain.id,
    token: inputToken,
    amount: inputAmount,
  });
  log("check-approval", {
    status: approval.response.status,
    hasApproval: Boolean(approval.data?.approval),
    data: approval.data,
  });
  if (!approval.response.ok) {
    fail("Approval bootstrap failed", approval.data);
  }

  if (approval.data.approval) {
    const approvalHash = await walletClient.sendTransaction({
      to: approval.data.approval.to,
      data: approval.data.approval.data,
      value: BigInt(approval.data.approval.value),
    });
    const approvalReceipt = await publicClient.waitForTransactionReceipt({
      hash: approvalHash,
    });
    log("approval-submitted", {
      txHash: approvalHash,
      receiptStatus: approvalReceipt.status,
    });
    if (approvalReceipt.status !== "success") {
      fail("Approval transaction reverted", { txHash: approvalHash });
    }
  }

  const quoteRequest = {
    tokenInChainId: manifest.chain.id,
    tokenOutChainId: manifest.chain.id,
    tokenIn: inputToken,
    tokenOut: outputToken,
    type: "EXACT_INPUT",
    amount: inputAmount,
    swapper: account.address,
    slippageTolerance: 0.5,
    routingPreference: "BEST_PRICE",
    permitAmount: "EXACT",
    outputs: [{ token: outputToken, recipient: account.address }],
  };
  const quote = await postJson("/quote", quoteRequest);
  log("quote", {
    status: quote.response.status,
    data: quote.data,
  });
  if (!quote.response.ok || !quote.data?.quote) {
    fail("Quote request failed", {
      status: quote.response.status,
      data: quote.data,
    });
  }

  const signature = await account.signTypedData({
    domain: quote.data.permitData.domain,
    types: quote.data.permitData.types,
    primaryType: "PermitWitnessTransferFrom",
    message: quote.data.permitData.value,
  });
  log("signed", { signature });

  const orderCreation = await postJson("/order", {
    quote: quote.data.quote,
    signature,
  });
  log("order-created", {
    status: orderCreation.response.status,
    data: orderCreation.data,
  });
  if (!orderCreation.response.ok || !orderCreation.data?.orderId) {
    fail("Order submission failed", {
      status: orderCreation.response.status,
      data: orderCreation.data,
    });
  }

  const orderId = orderCreation.data.orderId;
  const startedAt = Date.now();
  let currentOrder = null;

  while (Date.now() - startedAt < 90_000) {
    const polled = await getJson(`${backendUrl}/orders?orderId=${orderId}`);
    currentOrder = polled.data?.orders?.[0] ?? null;
    log("order-poll", {
      status: polled.response.status,
      orderStatus: currentOrder?.orderStatus ?? null,
      txHash: currentOrder?.txHash ?? null,
      settledAmounts: currentOrder?.settledAmounts?.length ?? 0,
    });

    if (!polled.response.ok) {
      fail("Order polling failed", {
        status: polled.response.status,
        data: polled.data,
      });
    }

    if (currentOrder && terminalStatuses.has(currentOrder.orderStatus)) {
      break;
    }

    await new Promise((resolve) => setTimeout(resolve, 3_000));
  }

  if (!currentOrder) {
    fail("Order never became visible through /orders", { orderId });
  }
  if (currentOrder.orderStatus !== "filled") {
    fail("Order did not fill successfully", currentOrder);
  }
  if (!currentOrder.txHash) {
    fail("Filled order did not expose a transaction hash", currentOrder);
  }

  const indexedFill = await queryIndexer(currentOrder.txHash);
  log("indexer", {
    foundFill: Boolean(indexedFill),
    fill: indexedFill,
  });
  if (!indexedFill) {
    fail("Indexer did not expose the fill transaction", {
      txHash: currentOrder.txHash,
      orderId,
    });
  }

  log("success", {
    orderId,
    txHash: currentOrder.txHash,
    inputAmount: currentOrder.input.amount,
    outputAmount: currentOrder.outputs[0]?.amount ?? null,
  });
}

main().catch((error) => {
  fail("Unhandled local verification error", {
    message: error instanceof Error ? error.message : String(error),
    stack: error instanceof Error ? error.stack : undefined,
  });
});
