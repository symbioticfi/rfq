import { useMemo, useState } from "react";

import type { Token } from "../types/token";

function dedupeTokens(tokens: ReadonlyArray<Token>) {
  const seen = new Set<string>();

  return tokens.filter((token) => {
    const key = token.address.toLowerCase();
    if (seen.has(key)) {
      return false;
    }

    seen.add(key);

    return true;
  });
}

export function useTokenList(sourceTokens: ReadonlyArray<Token>) {
  const [query, setQuery] = useState("");

  const filtered = useMemo<ReadonlyArray<Token>>(() => {
    const tokens = dedupeTokens(sourceTokens);

    if (!query.trim()) {
      return tokens;
    }

    const q = query.toLowerCase().trim();

    return tokens.filter(
      (t) =>
        t.symbol.toLowerCase().includes(q) || t.name.toLowerCase().includes(q) || t.address.toLowerCase().includes(q),
    );
  }, [query, sourceTokens]);

  return { query, setQuery, tokens: filtered };
}
