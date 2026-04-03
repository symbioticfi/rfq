import deployment from "../generated/deployment.json";
import type { Token } from "../types/token";

function tokenLogoUri(address: string) {
  if (address === "0x0000000000000000000000000000000000000000") {
    return "https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/ethereum/info/logo.png";
  }

  return `https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/ethereum/assets/${address}/logo.png`;
}

function dedupeTokens(tokens: ReadonlyArray<Token>) {
  const merged = new Map<string, Token>();

  for (const token of tokens) {
    merged.set(token.address.toLowerCase(), token);
  }

  return Array.from(merged.values());
}

export const TOKENS: ReadonlyArray<Token> = dedupeTokens(
  [...deployment.tokens.input, ...deployment.tokens.output].map((token) => ({
    ...token,
    logoURI: tokenLogoUri(token.address),
  })),
);
