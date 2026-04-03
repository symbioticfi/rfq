/** Format price impact basis points as a percentage string. */
export function formatPriceImpact(bps: number | undefined): string {
  if (bps === undefined || bps === 0) {
    return "0%";
  }

  const pct = bps / 100;
  const sign = pct > 0 ? "-" : "+";

  return `${sign}${Math.abs(pct).toFixed(2)}%`;
}

/** Determine severity of price impact for styling.
 *  >= -1.00% → neutral, otherwise red. */
export function priceImpactSeverity(bps: number | undefined): "neutral" | "negative" {
  if (bps === undefined) {
    return "neutral";
  }

  // bps > 0 means user loses value; 100 bps = 1%
  if (bps <= 100) {
    return "neutral";
  }

  return "negative";
}
