import { access, mkdir, writeFile } from "node:fs/promises";
import { constants as fsConstants } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const PACKAGE_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const OUTPUT_PATH = resolve(PACKAGE_ROOT, "src/data/uniswap-mainnet-token-list.json");
const SOURCE_URL = "https://raw.githubusercontent.com/Uniswap/default-token-list/main/src/tokens/mainnet.json";

function normalizeToken(token) {
  if (!token || typeof token !== "object") {
    throw new Error("invalid token entry");
  }

  const { address, symbol, name, decimals, logoURI } = token;
  if (
    typeof address !== "string" ||
    typeof symbol !== "string" ||
    typeof name !== "string" ||
    typeof decimals !== "number"
  ) {
    throw new Error(`invalid token shape for ${JSON.stringify(token)}`);
  }

  return {
    address,
    symbol,
    name,
    decimals,
    ...(typeof logoURI === "string" && logoURI.length > 0 ? { logoURI } : {}),
  };
}

async function hasLocalCache() {
  try {
    await access(OUTPUT_PATH, fsConstants.F_OK);
    return true;
  } catch {
    return false;
  }
}

async function fetchUniswapMainnetTokens() {
  const response = await fetch(SOURCE_URL, {
    headers: {
      "user-agent": "rfq-frontend-token-sync",
      accept: "application/json",
    },
  });
  if (!response.ok) {
    throw new Error(`token list fetch failed (${response.status})`);
  }

  const payload = await response.json();
  if (!Array.isArray(payload)) {
    throw new Error("unexpected Uniswap token list payload");
  }

  return payload.map(normalizeToken);
}

async function main() {
  try {
    const tokens = await fetchUniswapMainnetTokens();
    await mkdir(dirname(OUTPUT_PATH), { recursive: true });
    await writeFile(OUTPUT_PATH, `${JSON.stringify(tokens, null, 2)}\n`, "utf8");
    console.log(`synced ${tokens.length} Uniswap mainnet tokens -> ${OUTPUT_PATH}`);
  } catch (error) {
    if (await hasLocalCache()) {
      const message = error instanceof Error ? error.message : String(error);
      console.warn(`warning: could not refresh Uniswap token list, keeping local cache (${message})`);
      return;
    }

    throw error;
  }
}

await main();
