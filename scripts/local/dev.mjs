import { spawn } from "node:child_process";
import { access, readFile, rm } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";
import net from "node:net";
import process from "node:process";

const workspaceDir = resolve(fileURLToPath(new URL("../..", import.meta.url)));
const repoRoot = workspaceDir;
const protocolRoot = resolve(process.env.SYMBIOTIC_PROTOCOL_DIR || resolve(workspaceDir, ".."));
const dockerComposePath = resolve(workspaceDir, "docker-compose.local.yml");
const deploymentsDir = resolve(workspaceDir, "deployments");

async function loadEnvFile(filePath) {
  try {
    const contents = await readFile(filePath, "utf8");

    for (const rawLine of contents.split(/\r?\n/u)) {
      const line = rawLine.trim();
      if (!line || line.startsWith("#")) {
        continue;
      }

      const separatorIndex = line.indexOf("=");
      if (separatorIndex === -1) {
        continue;
      }

      const key = line.slice(0, separatorIndex).trim();
      const rawValue = line.slice(separatorIndex + 1).trim();
      const value =
        (rawValue.startsWith(`"`) && rawValue.endsWith(`"`)) || (rawValue.startsWith(`'`) && rawValue.endsWith(`'`))
          ? rawValue.slice(1, -1)
          : rawValue;

      if (process.env[key] === undefined) {
        process.env[key] = value;
      }
    }
  } catch {
    // optional file
  }
}

await loadEnvFile(resolve(workspaceDir, ".env"));
await loadEnvFile(resolve(workspaceDir, ".env.local"));

const mode = process.argv[2] === "hoodi" ? "hoodi" : "local";

const postgresPort = 55432;
const anvilPort = 8545;
const anvilHost = "127.0.0.1";
const protocolDatabaseUrl = `postgres://postgres:postgres@${anvilHost}:${postgresPort}/rfq_protocol`;
const backendUrl = "http://127.0.0.1:42072";
const fillerUrl = "http://127.0.0.1:42073";
const frontendUrl = "http://127.0.0.1:5173";
const indexerUrl = "http://127.0.0.1:42069";

const solverSharedSecret = process.env.RFQ_SOLVER_SHARED_SECRET || "local-rfq-shared-secret";
const defaultDeployerPrivateKey = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
const defaultProtocolSignerPrivateKey = "0x59c6995e998f97a5a0044966f09453816aaf9b34d9ccf5a9da9b8d0d4f3b3c9f";
const defaultFillerCallerPrivateKey = "0x5de4111afa1a4b94908f83103e8d6eaf95b78f3046c8c4b7aa90bf34e66b4a79";

const hoodiRpcUrl = process.env.RFQ_DEPLOYMENT_RPC_URL || "https://0xrpc.io/hoodi";
const hoodiRpcUrls =
  process.env.RFQ_RPC_URLS ||
  ["https://0xrpc.io/hoodi", "https://ethereum-hoodi.gateway.tatum.io", "https://rpc.hoodi.ethpandaops.io"].join(",");
const localRpcUrl = `http://${anvilHost}:${anvilPort}`;

const children = [];

function getModeConfig() {
  if (mode === "hoodi") {
    return {
      deploymentEnv: "hoodi",
      rpcUrl: hoodiRpcUrl,
      rpcUrlsEnv: hoodiRpcUrls,
      fillerRpcUrl: process.env.RFQ_FILLER_RPC_URL,
      frontendRpcUrl: process.env.VITE_WALLET_RPC_URL || "https://0xrpc.io/hoodi",
      walletChainName: "Hoodi",
      solverTimeoutMs: process.env.RFQ_SOLVER_TIMEOUT_MS || "1000",
      protocolSignerPrivateKey: requireEnv("RFQ_PROTOCOL_SIGNER_PRIVATE_KEY"),
      fillerCallerPrivateKey: requireEnv("RFQ_FILLER_CALLER_PRIVATE_KEY"),
      deployerPrivateKey: process.env.RFQ_DEPLOYER_PRIVATE_KEY || defaultDeployerPrivateKey,
      requiredFreePorts: [
        { port: 42072, host: "127.0.0.1", label: "backend" },
        { port: 42073, host: "127.0.0.1", label: "filler" },
        { port: 42069, host: "127.0.0.1", label: "indexer" },
        { port: 5173, host: "127.0.0.1", label: "frontend" },
      ],
    };
  }

  return {
    deploymentEnv: "local",
    rpcUrl: localRpcUrl,
    rpcUrlsEnv: localRpcUrl,
    fillerRpcUrl: localRpcUrl,
    frontendRpcUrl: localRpcUrl,
    walletChainName: "Anvil",
    solverTimeoutMs: process.env.RFQ_SOLVER_TIMEOUT_MS || "1000",
    protocolSignerPrivateKey: process.env.RFQ_PROTOCOL_SIGNER_PRIVATE_KEY || defaultProtocolSignerPrivateKey,
    fillerCallerPrivateKey: process.env.RFQ_FILLER_CALLER_PRIVATE_KEY || defaultFillerCallerPrivateKey,
    deployerPrivateKey: process.env.RFQ_DEPLOYER_PRIVATE_KEY || defaultDeployerPrivateKey,
    requiredFreePorts: [
      { port: anvilPort, host: anvilHost, label: "anvil RPC" },
      { port: 42072, host: "127.0.0.1", label: "backend" },
      { port: 42073, host: "127.0.0.1", label: "filler" },
      { port: 42069, host: "127.0.0.1", label: "indexer" },
      { port: 5173, host: "127.0.0.1", label: "frontend" },
    ],
  };
}

function requireEnv(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`${name} is required for ${mode}:dev`);
  }
  return value;
}

function spawnCommand(command, args, options = {}) {
  const child = spawn(command, args, {
    cwd: options.cwd || workspaceDir,
    stdio: "inherit",
    env: { ...process.env, ...options.env },
    shell: false,
  });
  children.push(child);
  return child;
}

function crashIfExitedEarly(child, label) {
  return new Promise((resolvePromise, rejectPromise) => {
    let settled = false;

    const onExit = (code, signal) => {
      if (settled) {
        return;
      }
      settled = true;
      rejectPromise(
        new Error(`${label} exited before startup completed (code=${code ?? "null"}, signal=${signal ?? "null"})`),
      );
    };

    child.once("exit", onExit);
    resolvePromise(() => {
      if (settled) {
        return;
      }
      settled = true;
      child.off("exit", onExit);
    });
  });
}

async function runCommand(command, args, options = {}) {
  await new Promise((resolvePromise, rejectPromise) => {
    const child = spawn(command, args, {
      cwd: options.cwd || workspaceDir,
      stdio: "inherit",
      env: { ...process.env, ...options.env },
      shell: false,
    });

    child.on("exit", (code) => {
      if (code === 0) {
        resolvePromise();
        return;
      }
      rejectPromise(new Error(`${command} ${args.join(" ")} failed with exit code ${code ?? "unknown"}`));
    });
    child.on("error", rejectPromise);
  });
}

async function runCommandWithOutput(command, args, options = {}) {
  return new Promise((resolvePromise, rejectPromise) => {
    const child = spawn(command, args, {
      cwd: options.cwd || workspaceDir,
      stdio: ["ignore", "pipe", "pipe"],
      env: { ...process.env, ...options.env },
      shell: false,
    });

    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });

    child.on("exit", (code) => {
      if (code === 0) {
        resolvePromise(stdout.trim());
        return;
      }
      rejectPromise(
        new Error(`${command} ${args.join(" ")} failed with exit code ${code ?? "unknown"}\n${stderr.trim()}`),
      );
    });
    child.on("error", rejectPromise);
  });
}

function canConnect(port, host) {
  return new Promise((resolvePromise) => {
    const socket = net.createConnection({ port, host });
    socket.once("connect", () => {
      socket.destroy();
      resolvePromise(true);
    });
    socket.once("error", () => {
      socket.destroy();
      resolvePromise(false);
    });
  });
}

async function assertPortFree(port, host, label) {
  if (await canConnect(port, host)) {
    throw new Error(`${label} is already running on ${host}:${port}. Run "pnpm ${mode}:stop" and try again.`);
  }
}

function waitForPort(port, host, timeoutMs = 30_000) {
  return new Promise((resolvePromise, rejectPromise) => {
    const startedAt = Date.now();

    const attempt = () => {
      const socket = net.createConnection({ port, host });
      socket.once("connect", () => {
        socket.end();
        resolvePromise();
      });
      socket.once("error", () => {
        socket.destroy();
        if (Date.now() - startedAt >= timeoutMs) {
          rejectPromise(new Error(`Timed out waiting for ${host}:${port}`));
          return;
        }
        setTimeout(attempt, 250);
      });
    };

    attempt();
  });
}

async function waitForService(child, label, port, host, timeoutMs = 30_000) {
  const releaseExitGuard = await crashIfExitedEarly(child, label);
  try {
    await waitForPort(port, host, timeoutMs);
  } finally {
    releaseExitGuard();
  }
}

async function waitForHttpOk(url, timeoutMs = 30_000) {
  const startedAt = Date.now();

  while (Date.now() - startedAt < timeoutMs) {
    try {
      const response = await fetch(url);
      if (response.ok) {
        return;
      }
    } catch {
      // Retry until timeout.
    }

    await new Promise((resolvePromise) => {
      setTimeout(resolvePromise, 250);
    });
  }

  throw new Error(`Timed out waiting for ${url}`);
}

async function assertRequiredPortsFree(requiredFreePorts) {
  for (const { port, host, label } of requiredFreePorts) {
    await assertPortFree(port, host, label);
  }
}

async function ensureExecutable(name) {
  try {
    await access(`/usr/local/bin/${name}`);
  } catch {
    // no-op, best-effort only
  }
}

async function resolveLocalPermit2Address(deployerPrivateKey) {
  if (process.env.RFQ_PERMIT2_ADDRESS) {
    return process.env.RFQ_PERMIT2_ADDRESS;
  }

  const output = await runCommandWithOutput(
    "forge",
    ["create", "src/Permit2.sol:Permit2", "--broadcast", "--rpc-url", localRpcUrl, "--private-key", deployerPrivateKey],
    { cwd: resolve(protocolRoot, "lib/permit2") },
  );
  const match = output.match(/Deployed to:\s*(0x[a-fA-F0-9]{40})/);
  if (!match) {
    throw new Error(`Failed to parse Permit2 deployment address from forge output:\n${output}`);
  }

  return match[1];
}

async function resetLocalDeployArtifacts() {
  await rm(resolve(workspaceDir, "broadcast/integration/script/DeployRfqStack.s.sol/31337"), {
    recursive: true,
    force: true,
  });
  await rm(resolve(workspaceDir, "cache/integration/script/DeployRfqStack.s.sol"), {
    recursive: true,
    force: true,
  });
  await rm(resolve(repoRoot, "broadcast/DeployRfqStack.s.sol/31337"), { recursive: true, force: true });
  await rm(resolve(repoRoot, "cache/DeployRfqStack.s.sol"), { recursive: true, force: true });
  await rm(resolve(protocolRoot, "broadcast/rfq/integration/script/DeployRfqStack.s.sol/31337"), {
    recursive: true,
    force: true,
  });
  await rm(resolve(protocolRoot, "cache/rfq/integration/script/DeployRfqStack.s.sol"), {
    recursive: true,
    force: true,
  });
}

async function readManifest(deploymentEnv) {
  return JSON.parse(await readFile(resolve(deploymentsDir, deploymentEnv, "addresses.json"), "utf8"));
}

async function assertLocalManifestAddressesHaveCode() {
  const manifest = await readManifest("local");
  const addresses = [
    ["Permit2", manifest.contracts.permit2],
    ["InstantRedemptionAdapter", manifest.contracts.instantRedemptionAdapter],
    ["Reactor", manifest.contracts.reactor],
    ["Executor", manifest.contracts.executor],
    ["MockSwapRouter", manifest.contracts.mockSwapRouter],
    ["Default input token", manifest.tokens.defaultInput],
    ["Default output token", manifest.tokens.defaultOutput],
    ...manifest.vaults.map((vault, index) => [`Vault ${index + 1}`, vault.address]),
  ];

  for (const [label, address] of addresses) {
    const code = await runCommandWithOutput("cast", ["code", address, "--rpc-url", localRpcUrl], { cwd: repoRoot });
    if (!code || code === "0x") {
      throw new Error(`${label} at ${address} has no code on ${localRpcUrl}. The local deploy is inconsistent.`);
    }
  }

  return manifest;
}

async function resetLocalIndexerSchemas() {
  await runCommand(
    "pnpm",
    [
      "--filter",
      "@symbiotic/rfq-backend",
      "exec",
      "tsx",
      "-e",
      [
        'import pg from "pg";',
        "(async () => {",
        `  const client = new pg.Client({ connectionString: ${JSON.stringify(protocolDatabaseUrl)} });`,
        "  await client.connect();",
        '  await client.query("drop schema if exists rfq_indexer_views cascade");',
        '  await client.query("drop schema if exists rfq_indexer cascade");',
        '  await client.query("create schema rfq_indexer");',
        '  await client.query("create schema rfq_indexer_views");',
        "  await client.end();",
        "})();",
      ].join(" "),
    ],
    { cwd: repoRoot },
  );
}

async function syncFrontendDeployment(deploymentEnv) {
  if (deploymentEnv === "local") {
    await runCommand("node", ["./scripts/sync-local-service-deployments.mjs"], {
      cwd: workspaceDir,
    });
  }

  const syncEnv = {
    ...process.env,
    RFQ_DEPLOYMENT_ENV: deploymentEnv,
    RFQ_FILLER_DEPLOYMENT_ENV: deploymentEnv,
    VITE_DEPLOYMENT_ENV: deploymentEnv,
  };

  for (const service of ["backend", "filler", "indexer", "frontend"]) {
    await runCommand("node", ["./scripts/sync-service-deployment.mjs", service], {
      cwd: workspaceDir,
      env: syncEnv,
    });
  }
}

async function startAnvilIfNeeded(config) {
  if (config.deploymentEnv !== "local") {
    return null;
  }

  const anvil = spawnCommand(
    "anvil",
    [
      "--host",
      anvilHost,
      "--allow-origin",
      "*",
      "--port",
      String(anvilPort),
      "--chain-id",
      "31337",
      "--disable-code-size-limit",
    ],
    { env: process.env },
  );
  anvil.on("exit", (code) => {
    if (code && code !== 0) {
      process.exitCode = code;
    }
  });

  await waitForPort(anvilPort, anvilHost);
  return anvil;
}

async function deployLocalStack(config) {
  const permit2Address = await resolveLocalPermit2Address(config.deployerPrivateKey);
  await resetLocalDeployArtifacts();

  await runCommand(
    "forge",
    [
      "script",
      "integration/script/DeployRfqStack.s.sol:DeployRfqStack",
      "--rpc-url",
      localRpcUrl,
      "--broadcast",
      "--skip-simulation",
      "--slow",
      "--non-interactive",
      "--disable-code-size-limit",
    ],
    {
      env: {
        ...process.env,
        RFQ_DEPLOYMENT_ENV: "local",
        RFQ_DEPLOYMENT_RPC_URL: localRpcUrl,
        RFQ_DEPLOYER_PRIVATE_KEY: config.deployerPrivateKey,
        RFQ_PROTOCOL_SIGNER_PRIVATE_KEY: config.protocolSignerPrivateKey,
        RFQ_FILLER_CALLER_PRIVATE_KEY: config.fillerCallerPrivateKey,
        RFQ_PERMIT2_ADDRESS: permit2Address,
        INTEGRATION_DEPLOYMENTS_DIR: deploymentsDir,
        SYMBIOTIC_PROTOCOL_DIR: protocolRoot,
      },
      cwd: workspaceDir,
    },
  );

  return assertLocalManifestAddressesHaveCode();
}

async function main() {
  const config = getModeConfig();

  await ensureExecutable("anvil");
  await assertRequiredPortsFree(config.requiredFreePorts);

  await runCommand("docker", ["compose", "-f", dockerComposePath, "up", "-d"]);
  await waitForPort(postgresPort, anvilHost);

  await startAnvilIfNeeded(config);

  await runCommand("pnpm", ["--filter", "@symbiotic/rfq-backend", "db:migrate"], {
    env: { RFQ_DATABASE_URL: protocolDatabaseUrl },
  });

  const manifest =
    config.deploymentEnv === "local" ? await deployLocalStack(config) : await readManifest(config.deploymentEnv);

  await syncFrontendDeployment(config.deploymentEnv);

  await runCommand("pnpm", ["--filter", "@symbiotic/rfq-backend", "seed:solver"], {
    env: {
      RFQ_DEPLOYMENT_ENV: config.deploymentEnv,
      RFQ_DATABASE_URL: protocolDatabaseUrl,
      RFQ_PROTOCOL_SIGNER_PRIVATE_KEY: config.protocolSignerPrivateKey,
      RFQ_SOLVER_SHARED_SECRET: solverSharedSecret,
      RFQ_RPC_URLS: config.rpcUrlsEnv,
      RFQ_SOLVER_ENDPOINT_URL: fillerUrl,
      RFQ_SOLVER_NOTIFY_URL: `${fillerUrl}/notify`,
      RFQ_SOLVER_FILLER_ADDRESS: manifest.contracts.executor,
    },
  });

  const backend = spawnCommand("pnpm", ["--filter", "@symbiotic/rfq-backend", "dev"], {
    env: {
      RFQ_DEPLOYMENT_ENV: config.deploymentEnv,
      RFQ_DATABASE_URL: protocolDatabaseUrl,
      RFQ_LOCAL_FUNDER_PRIVATE_KEY: config.deployerPrivateKey,
      RFQ_PROTOCOL_SIGNER_PRIVATE_KEY: config.protocolSignerPrivateKey,
      RFQ_SOLVER_SHARED_SECRET: solverSharedSecret,
      RFQ_SOLVER_TIMEOUT_MS: config.solverTimeoutMs,
      RFQ_RPC_URLS: config.rpcUrlsEnv,
    },
  });
  await resetLocalIndexerSchemas();
  const indexer = spawnCommand("pnpm", ["--filter", "@symbiotic/rfq-indexer", "dev"], {
    env: {
      RFQ_DATABASE_URL: protocolDatabaseUrl,
      RFQ_RPC_URLS: config.rpcUrl,
    },
  });
  const filler = spawnCommand("pnpm", ["--filter", "@symbiotic/rfq-filler", "dev"], {
    env: {
      RFQ_FILLER_DEPLOYMENT_ENV: config.deploymentEnv,
      RFQ_FILLER_BACKEND_URL: backendUrl,
      RFQ_FILLER_BACKEND_SHARED_SECRET: solverSharedSecret,
      RFQ_FILLER_EXECUTOR_ADDRESS: manifest.contracts.executor,
      RFQ_FILLER_CALLER_PRIVATE_KEY: config.fillerCallerPrivateKey,
      RFQ_FILLER_DISCOUNT_PERCENT: process.env.RFQ_FILLER_DISCOUNT_PERCENT ?? "10",
      ...(config.fillerRpcUrl ? { RFQ_FILLER_RPC_URL: config.fillerRpcUrl } : {}),
    },
  });
  const frontend = spawnCommand(
    "pnpm",
    ["--filter", "@symbiotic/rfq-frontend", "exec", "react-router", "dev", "--host", "127.0.0.1"],
    {
      env: {
        VITE_DEPLOYMENT_ENV: config.deploymentEnv,
        VITE_API_URL: backendUrl,
        VITE_WALLET_RPC_URL: config.frontendRpcUrl,
        VITE_WALLET_CHAIN_NAME: config.walletChainName,
      },
    },
  );

  await waitForService(backend, "backend", 42072, "127.0.0.1");
  await waitForService(indexer, "indexer", 42069, "127.0.0.1");
  await waitForService(filler, "filler", 42073, "127.0.0.1");
  await waitForService(frontend, "frontend", 5173, "127.0.0.1");
  await waitForHttpOk(`${backendUrl}/health`);
  await waitForHttpOk(`${fillerUrl}/health`);
  await waitForHttpOk(`${indexerUrl}/ready`);
  await waitForHttpOk(frontendUrl);

  // eslint-disable-next-line no-console
  console.log(
    `${config.walletChainName} RFQ stack is running.\nFrontend: ${frontendUrl}\nBackend: ${backendUrl}\nFiller: ${fillerUrl}\nIndexer: ${indexerUrl}`,
  );
}

function shutdown(signal) {
  for (const child of children) {
    if (!child.killed) {
      child.kill(signal);
    }
  }
}

process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));

main().catch((error) => {
  // eslint-disable-next-line no-console
  console.error(error);
  shutdown("SIGTERM");
  process.exit(1);
});
