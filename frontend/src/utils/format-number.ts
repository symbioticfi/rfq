/**
 * Format a number string with commas and limited decimal places.
 * Never mutates the input.
 */
export function formatNumber(value: string | number, maxDecimals = 6): string {
  const num = typeof value === "string" ? parseFloat(value) : value;
  if (Number.isNaN(num)) {
    return "0";
  }

  if (num === 0) {
    return "0";
  }

  const fixed = num.toFixed(maxDecimals);
  // Remove trailing zeros after decimal
  const trimmed = fixed.replace(/\.?0+$/, "");
  // Add commas to integer part
  const [intPart, decPart] = trimmed.split(".");
  const withCommas = intPart.replace(/\B(?=(\d{3})+(?!\d))/g, ",");

  return decPart ? `${withCommas}.${decPart}` : withCommas;
}

/**
 * Adaptive decimal formatting: larger numbers get fewer decimals.
 *   >= 1,000,000 → 0 decimals
 *   >= 10,000   → 2 decimals
 *   >= 100      → 3 decimals
 *   >= 1        → 4 decimals
 *   >= 0.01     → 5 decimals
 *   < 0.01      → 6 decimals
 */
export function formatNumberAdaptive(value: string | number): string {
  const num = typeof value === "string" ? parseFloat(value) : value;
  if (Number.isNaN(num) || num === 0) {
    return "0";
  }

  const abs = Math.abs(num);
  let decimals: number;
  if (abs >= 1_000_000) {
    decimals = 0;
  } else if (abs >= 10_000) {
    decimals = 2;
  } else if (abs >= 100) {
    decimals = 3;
  } else if (abs >= 1) {
    decimals = 4;
  } else if (abs >= 0.01) {
    decimals = 5;
  } else {
    decimals = 6;
  }

  return formatNumber(num, decimals);
}

/**
 * Format a raw token amount (in smallest units) to human-readable.
 */
export function formatTokenAmount(raw: string, decimals: number, maxDisplay = 6): string {
  if (!raw || raw === "0") {
    return "0";
  }

  const value = Number(raw) / 10 ** decimals;

  return formatNumber(value, maxDisplay);
}

/**
 * Format a raw token amount with adaptive decimals.
 */
export function formatTokenAmountAdaptive(raw: string, decimals: number): string {
  if (!raw || raw === "0") {
    return "0";
  }

  const value = Number(raw) / 10 ** decimals;

  return formatNumberAdaptive(value);
}

/**
 * Add commas to a raw numeric string while preserving the exact
 * decimal part the user typed (including trailing dots and zeros).
 */
export function addCommasToInput(raw: string): string {
  if (!raw) {
    return "";
  }

  const dotIdx = raw.indexOf(".");
  const intPart = dotIdx === -1 ? raw : raw.slice(0, dotIdx);
  const decPart = dotIdx === -1 ? "" : raw.slice(dotIdx); // includes the dot
  const withCommas = intPart.replace(/\B(?=(\d{3})+(?!\d))/g, ",");

  return withCommas + decPart;
}

/**
 * Strip commas from a formatted string to get the raw numeric value.
 */
export function stripCommas(formatted: string): string {
  return formatted.replace(/,/g, "");
}
