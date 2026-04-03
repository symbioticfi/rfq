/** Calculate minimum received given an amount and slippage in basis points. */
export function calcMinReceived(amountOut: string, slippageBps: number): string {
  const out = parseFloat(amountOut);
  if (Number.isNaN(out) || out === 0) {
    return "0";
  }

  const factor = 1 - slippageBps / 10_000;

  return (out * factor).toString();
}
