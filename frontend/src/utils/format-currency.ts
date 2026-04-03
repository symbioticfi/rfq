/** Format a number as a USD string. */
export function formatUSD(value: number): string {
  if (Number.isNaN(value) || value === 0) {
    return "$0.00";
  }

  if (Math.abs(value) < 0.01) {
    return "<$0.01";
  }

  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  }).format(value);
}
