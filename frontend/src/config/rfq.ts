import deployment from "../generated/deployment.json";
import type { Token } from "../types/token";

export const NATIVE_TOKEN_ADDRESS = "0x0000000000000000000000000000000000000000";
export const LEGACY_NATIVE_TOKEN_ADDRESS = NATIVE_TOKEN_ADDRESS;
export const PREVIEW_SWAPPER_ADDRESS = "0x000000000000000000000000000000000000dEaD";
export const RFQ_DEPLOYMENT_ENV = deployment.environment;
export const IS_LOCAL_DEPLOYMENT = deployment.environment === "local";
export const IS_HOODI_DEPLOYMENT = deployment.environment === "hoodi";

export function getTokenLogoUri(address: string) {
  if (address === NATIVE_TOKEN_ADDRESS) {
    return "https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/ethereum/info/logo.png";
  }

  return `https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/ethereum/assets/${address}/logo.png`;
}

function dedupeTokens(tokens: ReadonlyArray<Token>) {
  const result: Token[] = [];
  const seen = new Set<string>();

  for (const token of tokens) {
    const key = token.address.toLowerCase();
    if (seen.has(key)) {
      continue;
    }

    seen.add(key);
    result.push(token);
  }

  return result;
}

function toToken(token: (typeof deployment.tokens.input)[number] | (typeof deployment.tokens.output)[number]): Token {
  return {
    ...token,
    logoURI: getTokenLogoUri(token.address),
  };
}

export const RFQ_INPUT_TOKENS = dedupeTokens(deployment.tokens.input.map(toToken));
export const RFQ_OUTPUT_TOKENS = dedupeTokens(deployment.tokens.output.map(toToken));

export const DEFAULT_INPUT_TOKEN =
  RFQ_INPUT_TOKENS.find((token) => token.address.toLowerCase() === deployment.tokens.defaultInput?.toLowerCase()) ??
  RFQ_INPUT_TOKENS[0] ??
  null;

export const DEFAULT_OUTPUT_TOKEN =
  RFQ_OUTPUT_TOKENS.find((token) => token.address.toLowerCase() === deployment.tokens.defaultOutput?.toLowerCase()) ??
  RFQ_OUTPUT_TOKENS[0] ??
  null;

export const DEFAULT_SLIPPAGE_BPS = 50;
