import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";
import process from "node:process";

const workspaceDir = resolve(fileURLToPath(new URL("../..", import.meta.url)));
const dockerComposePath = resolve(workspaceDir, "docker-compose.local.yml");
const mode = process.argv[2] === "hoodi" ? "hoodi" : "local";
const ports = [8545, 42072, 42073, 42069, 5173];
const managedProcessPatterns = [
  "pnpm local:dev",
  "pnpm hoodi:dev",
  "node ./scripts/local/dev.mjs local",
  "node ./scripts/local/dev.mjs hoodi",
  "integration/script/DeployRfqStack.s.sol:DeployRfqStack",
  "rfq/integration/script/DeployRfqStack.s.sol:DeployRfqStack",
  "pnpm --filter @symbiotic/rfq-backend dev",
  "pnpm --filter @symbiotic/rfq-filler dev",
  "pnpm --filter @symbiotic/rfq-indexer dev",
  "pnpm --filter @symbiotic/rfq-frontend dev",
  "react-router dev",
  "ponder dev",
  "anvil --host 127.0.0.1 --allow-origin * --port 8545",
];

function runCommand(command, args, options = {}) {
  return new Promise((resolvePromise, rejectPromise) => {
    const child = spawn(command, args, {
      cwd: options.cwd || workspaceDir,
      stdio: options.stdio || ["ignore", "pipe", "pipe"],
      env: { ...process.env, ...options.env },
      shell: false,
    });

    let stdout = "";
    let stderr = "";
    if (child.stdout) {
      child.stdout.on("data", (chunk) => {
        stdout += chunk.toString();
      });
    }
    if (child.stderr) {
      child.stderr.on("data", (chunk) => {
        stderr += chunk.toString();
      });
    }

    child.on("exit", (code) => {
      if (code === 0) {
        resolvePromise({ stdout, stderr });
        return;
      }
      rejectPromise(new Error(`${command} ${args.join(" ")} failed with exit code ${code ?? "unknown"}\n${stderr}`));
    });
    child.on("error", rejectPromise);
  });
}

async function listListeningPids(port) {
  try {
    const { stdout } = await runCommand("lsof", ["-ti", `tcp:${port}`, "-sTCP:LISTEN"]);
    return stdout
      .split("\n")
      .map((line) => line.trim())
      .filter(Boolean)
      .map((value) => Number(value))
      .filter((value) => Number.isInteger(value) && value > 0);
  } catch {
    return [];
  }
}

async function listManagedPids() {
  try {
    const { stdout } = await runCommand("ps", ["-Ao", "pid=,command="]);
    return stdout
      .split("\n")
      .map((line) => line.trim())
      .filter(Boolean)
      .flatMap((line) => {
        const match = line.match(/^(\d+)\s+(.*)$/);
        if (!match) {
          return [];
        }

        const [, pidText, command] = match;
        if (!managedProcessPatterns.some((pattern) => command.includes(pattern))) {
          return [];
        }

        const pid = Number(pidText);
        return Number.isInteger(pid) && pid > 0 ? [pid] : [];
      });
  } catch {
    return [];
  }
}

function sleep(ms) {
  return new Promise((resolvePromise) => {
    setTimeout(resolvePromise, ms);
  });
}

function isAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function terminatePid(pid) {
  if (!isAlive(pid)) {
    return;
  }

  try {
    process.kill(pid, "SIGTERM");
  } catch {
    return;
  }

  for (let attempt = 0; attempt < 10; attempt += 1) {
    if (!isAlive(pid)) {
      return;
    }
    await sleep(200);
  }

  try {
    process.kill(pid, "SIGKILL");
  } catch {
    // ignore
  }
}

async function stopInfra() {
  try {
    await runCommand("docker", ["compose", "-f", dockerComposePath, "down", "-v"], {
      stdio: "inherit",
    });
  } catch {
    // Ignore infra shutdown failures so process cleanup still succeeds.
  }
}

async function main() {
  const pids = new Set();

  for (const port of ports) {
    const portPids = await listListeningPids(port);
    for (const pid of portPids) {
      pids.add(pid);
    }
  }

  const managedPids = await listManagedPids();
  for (const pid of managedPids) {
    pids.add(pid);
  }

  await Promise.all([...pids].map((pid) => terminatePid(pid)));
  await stopInfra();

  // eslint-disable-next-line no-console
  console.log(`Stopped ${mode} RFQ dev processes.`);
}

await main();
