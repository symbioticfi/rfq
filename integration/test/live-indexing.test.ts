import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import net from "node:net";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";

import { createPublicClient, createWalletClient, http, parseAbi } from "viem";
import { privateKeyToAccount } from "viem/accounts";

const TEST_TIMEOUT_MS = 120_000;
const CHAIN_ID = 31_337;
const DATABASE_SCHEMA = "rfq_indexer_test";
const VIEWS_SCHEMA = "rfq_indexer_test_views";
const INTEGRATION_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const explicitProtocolDir = process.env.SYMBIOTIC_PROTOCOL_DIR?.trim();
const explicitWorkspaceDir = process.env.RFQ_WORKSPACE_DIR?.trim();
const explicitIndexerDir = process.env.RFQ_INDEXER_DIR?.trim();
const rootDirCandidates = [
  explicitProtocolDir ? resolve(explicitProtocolDir) : null,
  resolve(INTEGRATION_DIR, "submodules", "protocol"),
  resolve(INTEGRATION_DIR, "../.."),
].filter((value) => value !== null);
const ROOT_DIR = rootDirCandidates.find((candidate) => existsSync(candidate));
if (!ROOT_DIR) {
  throw new Error(`Could not locate the protocol root. Set SYMBIOTIC_PROTOCOL_DIR explicitly for ${INTEGRATION_DIR}.`);
}
const indexerDirCandidates = [
  explicitIndexerDir ? resolve(explicitIndexerDir) : null,
  explicitWorkspaceDir ? resolve(explicitWorkspaceDir, "indexer") : null,
  resolve(INTEGRATION_DIR, "submodules", "rfq-indexer"),
  resolve(INTEGRATION_DIR, "submodules", "rfq", "indexer"),
  resolve(INTEGRATION_DIR, "..", "indexer"),
].filter((value) => value !== null);
const INDEXER_DIR = indexerDirCandidates.find((candidate) => existsSync(candidate));
if (!INDEXER_DIR) {
  throw new Error(`Could not locate the RFQ indexer. Set RFQ_INDEXER_DIR explicitly for ${INTEGRATION_DIR}.`);
}
const FIXTURE_CONTRACT = resolve(INTEGRATION_DIR, "test/fixtures/ReactorEventEmitter.sol");
const INDEXER_DEPLOYMENT_PATH = resolve(INDEXER_DIR, "deployments/local/addresses.json");
const INDEXER_GENERATED_DEPLOYMENT_PATH = resolve(INDEXER_DIR, "src/generated/deployment.ts");
const workspaceDirCandidates = [
  explicitWorkspaceDir ? resolve(explicitWorkspaceDir) : null,
  resolve(INTEGRATION_DIR, "submodules", "rfq"),
  resolve(INTEGRATION_DIR, ".."),
].filter((value) => value !== null);
const RFQ_WORKSPACE_DIR = workspaceDirCandidates.find((candidate) => existsSync(candidate));
if (!RFQ_WORKSPACE_DIR) {
  throw new Error(`Could not locate the RFQ workspace. Set RFQ_WORKSPACE_DIR explicitly for ${INTEGRATION_DIR}.`);
}
const SYNC_DEPLOYMENT_SCRIPT = resolve(RFQ_WORKSPACE_DIR, "scripts", "sync-service-deployment.mjs");

const emitterAbi = parseAbi([
  "function emitFill(((address tokenIn,uint256 amountIn,(address token,uint256 amount,address recipient)[] outputs,uint256 deadline,uint256 nonce,address protocol) request,bytes swapperSignature,address swapper,address filler) order)",
]);

type SpawnedProcess = {
  readonly process: ReturnType<typeof spawn>;
  readonly stdout: string[];
  readonly stderr: string[];
  error: Error | null;
};

async function reserveFreePort() {
  return new Promise<number>((resolvePromise, rejectPromise) => {
    const server = net.createServer();
    server.unref();
    server.on("error", rejectPromise);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (!address || typeof address === "string") {
        server.close(() => rejectPromise(new Error("Could not reserve a free port")));
        return;
      }

      const { port } = address;
      server.close((error) => {
        if (error) {
          rejectPromise(error);
          return;
        }
        resolvePromise(port);
      });
    });
  });
}

function spawnLoggedProcess(
  command: string,
  args: readonly string[],
  options: {
    readonly cwd: string;
    readonly env?: NodeJS.ProcessEnv;
  },
): SpawnedProcess {
  const child = spawn(command, args, {
    cwd: options.cwd,
    env: options.env,
    stdio: ["ignore", "pipe", "pipe"],
  });
  const stdout: string[] = [];
  const stderr: string[] = [];
  const spawned: SpawnedProcess = { process: child, stdout, stderr, error: null };

  child.stdout.on("data", (chunk) => {
    stdout.push(String(chunk));
  });
  child.stderr.on("data", (chunk) => {
    stderr.push(String(chunk));
  });
  child.on("error", (error) => {
    spawned.error = error;
  });

  return spawned;
}

async function stopProcess(spawned: SpawnedProcess | null) {
  if (!spawned || spawned.process.exitCode !== null) {
    return;
  }

  await new Promise<void>((resolve) => {
    const done = () => resolve();
    spawned.process.once("exit", done);
    spawned.process.kill("SIGTERM");
    setTimeout(() => {
      if (spawned.process.exitCode === null) {
        spawned.process.kill("SIGKILL");
      }
    }, 2_000);
  });
}

async function runCommand(
  command: string,
  args: readonly string[],
  options: { readonly cwd: string; readonly env?: NodeJS.ProcessEnv },
) {
  const spawned = spawnLoggedProcess(command, args, options);

  const exitCode = await new Promise<number>((resolve) => {
    spawned.process.once("exit", (code) => resolve(code ?? 1));
  });

  if (exitCode !== 0) {
    throw new Error(
      `${command} ${args.join(" ")} failed\nstdout:\n${spawned.stdout.join("")}\nstderr:\n${spawned.stderr.join("")}`,
    );
  }
}

async function waitForHttpOrExit(url: string, timeoutMs: number, spawned: SpawnedProcess) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if (spawned.error) {
      throw new Error(`Process failed before API was ready: ${spawned.error.message}`);
    }
    if (spawned.process.exitCode !== null) {
      throw new Error(`Process exited before API was ready with code ${spawned.process.exitCode}`);
    }

    try {
      const response = await fetch(url);
      if (response.ok) {
        return;
      }
    } catch {}

    await new Promise((resolvePromise) => setTimeout(resolvePromise, 250));
  }

  throw new Error(`Timed out waiting for ${url}`);
}

async function waitForRpc(url: string, timeoutMs: number) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const response = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_chainId", params: [] }),
      });
      if (response.ok) {
        return;
      }
    } catch {}

    await new Promise((resolvePromise) => setTimeout(resolvePromise, 250));
  }

  throw new Error(`Timed out waiting for RPC ${url}`);
}

async function waitForTransaction(client: ReturnType<typeof createPublicClient>, hash: `0x${string}`) {
  const receipt = await client.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") {
    throw new Error(`Transaction ${hash} reverted`);
  }
  return receipt;
}

async function buildEmitterArtifact(tempDir: string) {
  const outDir = join(tempDir, "out");
  await mkdir(outDir, { recursive: true });

  const build = spawnLoggedProcess(
    "forge",
    ["build", "--root", ROOT_DIR, "--contracts", FIXTURE_CONTRACT, "--out", outDir, "--skip", "test"],
    { cwd: ROOT_DIR, env: process.env },
  );
  const exitCode = await new Promise<number>((resolve) => {
    build.process.once("exit", (code) => resolve(code ?? 1));
  });

  if (exitCode !== 0) {
    throw new Error(`forge build failed\nstdout:\n${build.stdout.join("")}\nstderr:\n${build.stderr.join("")}`);
  }

  const artifactPath = join(outDir, "ReactorEventEmitter.sol", "ReactorEventEmitter.json");
  const artifact = JSON.parse(await readFile(artifactPath, "utf8")) as {
    readonly bytecode: {
      readonly object: `0x${string}` | string;
    };
  };

  return artifact.bytecode.object as `0x${string}`;
}

async function graphqlRequest<T>(port: number, query: string) {
  const response = await fetch(`http://127.0.0.1:${port}/graphql`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ query }),
  });
  if (!response.ok) {
    throw new Error(`GraphQL request failed with ${response.status}: ${await response.text()}`);
  }

  return (await response.json()) as T;
}

describe("live Ponder + Anvil indexing", () => {
  it(
    "indexes Reactor Fill(Order) from a live chain and exposes it over the running API",
    async () => {
      const anvilPort = await reserveFreePort();
      const ponderPort = await reserveFreePort();
      const tempDir = await mkdtemp(join(tmpdir(), "rfq-indexer-live-"));
      const anvil = spawnLoggedProcess(
        "anvil",
        ["--port", String(anvilPort), "--chain-id", String(CHAIN_ID), "--silent"],
        { cwd: ROOT_DIR, env: process.env },
      );
      let ponder: SpawnedProcess | null = null;
      const originalDeployment = await readFile(INDEXER_DEPLOYMENT_PATH, "utf8");
      const originalGeneratedDeployment = await readFile(INDEXER_GENERATED_DEPLOYMENT_PATH, "utf8");

      try {
        await waitForRpc(`http://127.0.0.1:${anvilPort}`, 10_000);

        const bytecode = await buildEmitterArtifact(tempDir);
        const account = privateKeyToAccount("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80");
        const publicClient = createPublicClient({
          chain: {
            id: CHAIN_ID,
            name: "anvil",
            nativeCurrency: { decimals: 18, name: "Ether", symbol: "ETH" },
            rpcUrls: { default: { http: [`http://127.0.0.1:${anvilPort}`] } },
          },
          transport: http(`http://127.0.0.1:${anvilPort}`),
        });
        const walletClient = createWalletClient({
          account,
          chain: {
            id: CHAIN_ID,
            name: "anvil",
            nativeCurrency: { decimals: 18, name: "Ether", symbol: "ETH" },
            rpcUrls: { default: { http: [`http://127.0.0.1:${anvilPort}`] } },
          },
          transport: http(`http://127.0.0.1:${anvilPort}`),
        });

        const deployHash = await walletClient.deployContract({
          abi: emitterAbi,
          bytecode,
          args: [],
        });
        const deployReceipt = await waitForTransaction(publicClient, deployHash);
        const emitterAddress = deployReceipt.contractAddress;
        if (!emitterAddress) {
          throw new Error("Missing deployed contract address");
        }

        const pgliteDir = join(tempDir, "pglite");
        await mkdir(pgliteDir, { recursive: true });
        await writeFile(
          INDEXER_DEPLOYMENT_PATH,
          JSON.stringify(
            {
              version: 1,
              environment: "local",
              deployed: true,
              chain: {
                id: CHAIN_ID,
                name: "Anvil",
                rpcUrl: `http://127.0.0.1:${anvilPort}`,
                testnet: true,
                startBlock: Number(deployReceipt.blockNumber),
                explorerUrl: "",
              },
              contracts: {
                permit2: emitterAddress,
                instantRedemptionAdapter: emitterAddress,
                reactor: emitterAddress,
                executor: emitterAddress,
                mockSwapRouter: emitterAddress,
                vaultFactory: emitterAddress,
              },
            },
            null,
            2,
          ),
        );
        await runCommand(process.execPath, [SYNC_DEPLOYMENT_SCRIPT, "indexer"], {
          cwd: ROOT_DIR,
          env: {
            ...process.env,
            RFQ_DEPLOYMENT_ENV: "local",
          },
        });
        ponder = spawnLoggedProcess(
          "pnpm",
          [
            "exec",
            "ponder",
            "start",
            "--schema",
            DATABASE_SCHEMA,
            "--views-schema",
            VIEWS_SCHEMA,
            "--port",
            String(ponderPort),
            "--hostname",
            "127.0.0.1",
          ],
          {
            cwd: INDEXER_DIR,
            env: {
              ...process.env,
              PORT: String(ponderPort),
              PONDER_LOG_LEVEL: "debug",
              RFQ_INDEXER_START_BLOCK: String(deployReceipt.blockNumber),
              RFQ_INDEXER_PGLITE_DIR: pgliteDir,
              RFQ_RPC_URLS: `http://127.0.0.1:${anvilPort}`,
            },
          },
        );

        try {
          await waitForHttpOrExit(`http://127.0.0.1:${ponderPort}/health`, 60_000, ponder);
        } catch (error) {
          throw new Error(
            `Timed out waiting for Ponder API\nponder stdout:\n${ponder.stdout.join("")}\nponder stderr:\n${ponder.stderr.join("")}\n${error instanceof Error ? error.message : String(error)}`,
          );
        }

        const order = {
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
        } as const;

        const emitHash = await walletClient.writeContract({
          address: emitterAddress,
          abi: emitterAbi,
          functionName: "emitFill",
          args: [order],
        });
        await waitForTransaction(publicClient, emitHash);

        const introspection = await graphqlRequest<{
          readonly data: {
            readonly __schema: {
              readonly queryType: {
                readonly fields: readonly { readonly name: string }[];
              };
            };
          };
        }>(ponderPort, "{ __schema { queryType { fields { name } } } }");
        const fillField =
          introspection.data.__schema.queryType.fields.find((field) => field.name === "reactorFills")?.name ??
          "reactorFills";

        const start = Date.now();
        while (Date.now() - start < 20_000) {
          try {
            const result = await graphqlRequest<{
              readonly data?: Record<string, { readonly items: readonly Record<string, unknown>[] }>;
            }>(
              ponderPort,
              `{ ${fillField}(limit: 10) { items { id orderHash txHash tokenIn amountIn deadline filler swapper } } }`,
            );
            const items = result.data?.[fillField]?.items ?? [];
            if (items.length > 0) {
              expect(items[0]).toMatchObject({
                id: expect.stringContaining(`${CHAIN_ID}:`),
                txHash: emitHash,
                tokenIn: order.request.tokenIn,
                amountIn: order.request.amountIn.toString(),
                deadline: order.request.deadline.toString(),
                filler: order.filler,
                swapper: order.swapper,
              });
              return;
            }
          } catch {
            // The GraphQL server can trail the health endpoint briefly under parallel workspace load.
          }

          await new Promise((resolvePromise) => setTimeout(resolvePromise, 250));
        }

        throw new Error(
          `Timed out waiting for indexed fill\nponder stdout:\n${ponder.stdout.join("")}\nponder stderr:\n${ponder.stderr.join("")}`,
        );
      } finally {
        await stopProcess(ponder);
        await stopProcess(anvil);
        await writeFile(INDEXER_DEPLOYMENT_PATH, originalDeployment);
        await writeFile(INDEXER_GENERATED_DEPLOYMENT_PATH, originalGeneratedDeployment);
        await rm(tempDir, { recursive: true, force: true });
      }
    },
    TEST_TIMEOUT_MS,
  );
});
