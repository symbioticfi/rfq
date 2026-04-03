import { Settings } from "lucide-react";
import { useEffect, useId, useMemo, useRef, useState } from "react";
import { formatUnits } from "viem";

import { DEFAULT_OUTPUT_TOKEN, RFQ_INPUT_TOKENS, RFQ_OUTPUT_TOKENS } from "../../config/rfq";
import { useActiveOrder } from "../../hooks/use-active-order";
import { useQuote } from "../../hooks/use-quote";
import { useSwapState } from "../../hooks/use-swap-state";
import { useTokenPrice } from "../../hooks/use-token-prices";
import { useWallet } from "../../hooks/use-wallet";
import type { Token } from "../../types/token";
import { formatTokenAmountAdaptive } from "../../utils/format-number";
import { TokenSelectModal } from "../token-select/token-select-modal";
import { AdvancedDetails } from "./advanced-details";
import { ConversionRate } from "./conversion-rate";
import { SettingsPopover } from "./settings-popover";
import { SwapActionButton } from "./swap-action-button";
import styles from "./swap-card.module.css";
import { SwapDirectionIndicator } from "./swap-direction-indicator";
import { TokenInput } from "./token-input";
import { TokenOutput } from "./token-output";

function mergeTokens(...groups: ReadonlyArray<ReadonlyArray<Token | null | undefined>>) {
  const merged: Token[] = [];
  const seen = new Set<string>();

  for (const group of groups) {
    for (const token of group) {
      if (!token) {
        continue;
      }

      const key = token.address.toLowerCase();
      if (seen.has(key)) {
        continue;
      }

      seen.add(key);
      merged.push(token);
    }
  }

  return merged;
}

function trimFractionalZeros(value: string) {
  if (!value.includes(".")) {
    return value;
  }

  return value.replace(/\.?0+$/, "").replace(/\.$/, "");
}

/**
 * @dev Renders the single-page RFQ swap card over the new quote/sign/order flow.
 * @returns The primary RFQ redemption card.
 */
export function SwapCard() {
  const settingsPopoverId = useId();
  const settingsButtonRef = useRef<HTMLButtonElement>(null);
  const [state, dispatch] = useSwapState();
  const [importedOutputTokens, setImportedOutputTokens] = useState<ReadonlyArray<Token>>([]);
  const { address } = useWallet();
  const { activeOrder, hasActiveOrder, persistOrder } = useActiveOrder(address);

  const sellTokens = RFQ_INPUT_TOKENS;
  const buyTokens = useMemo(
    () => mergeTokens(RFQ_OUTPUT_TOKENS, importedOutputTokens, [state.buyToken, DEFAULT_OUTPUT_TOKEN]),
    [importedOutputTokens, state.buyToken],
  );
  const resolveToken = (tokenAddress: string) =>
    mergeTokens(sellTokens, buyTokens).find((token) => token.address.toLowerCase() === tokenAddress.toLowerCase()) ??
    null;
  const pendingOrder = hasActiveOrder ? activeOrder : null;
  const pendingSellToken = pendingOrder ? resolveToken(pendingOrder.input.token) : null;
  const pendingOutput = pendingOrder ? (pendingOrder.settledAmounts[0] ?? pendingOrder.outputs[0] ?? null) : null;
  const pendingBuyToken = pendingOutput ? resolveToken(pendingOutput.token) : null;
  const pendingSellAmount =
    pendingOrder && pendingSellToken
      ? trimFractionalZeros(formatUnits(BigInt(pendingOrder.input.amount), pendingSellToken.decimals))
      : "";
  const displaySellToken = pendingSellToken ?? state.sellToken;
  const displayBuyToken = pendingBuyToken ?? state.buyToken;
  const displaySellAmount = pendingSellAmount || state.sellAmount;

  const quote = useQuote({
    sellToken: state.sellToken,
    buyToken: state.buyToken,
    sellAmount: state.sellAmount,
    slippageBps: state.slippageBps,
    paused: hasActiveOrder,
  });

  useEffect(() => {
    if (!pendingOrder) {
      return;
    }

    if (pendingSellToken && state.sellToken?.address.toLowerCase() !== pendingSellToken.address.toLowerCase()) {
      dispatch({ type: "SET_SELL_TOKEN", token: pendingSellToken });
    }

    if (pendingBuyToken && state.buyToken?.address.toLowerCase() !== pendingBuyToken.address.toLowerCase()) {
      dispatch({ type: "SET_BUY_TOKEN", token: pendingBuyToken });
    }

    if (pendingSellAmount && state.sellAmount !== pendingSellAmount) {
      dispatch({ type: "SET_SELL_AMOUNT", amount: pendingSellAmount });
    }
  }, [
    dispatch,
    pendingBuyToken,
    pendingOrder,
    pendingSellAmount,
    pendingSellToken,
    state.buyToken,
    state.sellAmount,
    state.sellToken,
  ]);

  const sellTokenPrice = useTokenPrice(displaySellToken?.address);
  const sellUsdValue =
    sellTokenPrice && displaySellAmount ? sellTokenPrice * Number.parseFloat(displaySellAmount || "0") : null;
  const displayAmountOut = pendingOutput?.amount ?? quote.data?.amountOut;

  const handleSelectToken = (token: Token) => {
    if (hasActiveOrder) {
      return;
    }

    if (state.tokenSelectSide === "sell") {
      dispatch({ type: "SET_SELL_TOKEN", token });
      return;
    }

    setImportedOutputTokens((current) => mergeTokens(current, [token]));
    dispatch({ type: "SET_BUY_TOKEN", token });
  };

  const quoteStatusMessage = hasActiveOrder
    ? "Order pending"
    : quote.isFetching
      ? "Finding the best route"
      : displayAmountOut && displayBuyToken
        ? `Estimated output ${formatTokenAmountAdaptive(displayAmountOut, displayBuyToken.decimals)} ${displayBuyToken.symbol}`
        : quote.error instanceof Error
          ? `Quote unavailable: ${quote.error.message}`
          : quote.data === null && state.sellAmount
            ? "No quote available"
            : "";

  const minAmountOut = quote.data?.orderInfo.outputs[0]?.amount;

  return (
    <>
      <div className={styles.wrapper}>
        <h1 className="srOnly">Symbiotic Swap</h1>
        <div className="srOnly" aria-live="polite" aria-atomic="true">
          {quoteStatusMessage}
        </div>
        <div className={styles.header}>
          <div />
          <div className={styles.headerActions}>
            <button
              ref={settingsButtonRef}
              className={styles.settingsButton}
              onClick={() => dispatch({ type: "TOGGLE_SETTINGS" })}
              type="button"
              aria-label="Settings"
              aria-haspopup="dialog"
              aria-expanded={state.showSettings}
              aria-controls={state.showSettings ? settingsPopoverId : undefined}
            >
              <Settings size={18} aria-hidden="true" />
            </button>
          </div>
          {state.showSettings && (
            <SettingsPopover
              id={settingsPopoverId}
              slippageBps={state.slippageBps}
              slippageMode={state.slippageMode}
              onSlippageChange={(bps, mode) => dispatch({ type: "SET_SLIPPAGE", bps, mode })}
              onClose={() => dispatch({ type: "TOGGLE_SETTINGS" })}
              triggerRef={settingsButtonRef}
            />
          )}
        </div>

        <div className={styles.body}>
          <TokenInput
            label="Sell"
            token={displaySellToken}
            amount={displaySellAmount}
            onAmountChange={(amount) => dispatch({ type: "SET_SELL_AMOUNT", amount })}
            onTokenSelect={() => dispatch({ type: "OPEN_TOKEN_SELECT", side: "sell" })}
            disabled={hasActiveOrder}
          />

          <SwapDirectionIndicator />

          <TokenOutput
            label="Buy"
            token={displayBuyToken}
            amountOut={displayAmountOut}
            referenceUsdValue={sellUsdValue}
            priceImpactBps={undefined}
            isLoading={hasActiveOrder ? false : quote.isFetching && !displayAmountOut}
            onTokenSelect={() => dispatch({ type: "OPEN_TOKEN_SELECT", side: "buy" })}
            disabled={hasActiveOrder}
          />
        </div>

        <SwapActionButton
          sellToken={displaySellToken}
          buyToken={displayBuyToken}
          sellAmount={displaySellAmount}
          quote={quote.data ?? null}
          isQuoting={quote.isFetching}
          quoteError={quote.error instanceof Error ? quote.error.message : null}
          hasActiveOrder={hasActiveOrder}
          onOrderCreated={persistOrder}
        />

        {displaySellToken && displayBuyToken && displayAmountOut && (
          <>
            <ConversionRate
              sellToken={displaySellToken}
              buyToken={displayBuyToken}
              amountOut={displayAmountOut}
              sellAmount={displaySellAmount}
              direction={state.rateDirection}
              onToggleDirection={() => dispatch({ type: "TOGGLE_RATE_DIRECTION" })}
              showAdvanced={state.showAdvanced}
              onToggleAdvanced={() => dispatch({ type: "TOGGLE_ADVANCED" })}
            />
            {state.showAdvanced && (
              <AdvancedDetails
                amountOut={displayAmountOut}
                buyToken={displayBuyToken}
                slippageBps={state.slippageBps}
                minAmountOut={minAmountOut}
              />
            )}
          </>
        )}
      </div>

      <TokenSelectModal
        open={state.tokenSelectSide !== null}
        onClose={() => dispatch({ type: "CLOSE_TOKEN_SELECT" })}
        onSelect={handleSelectToken}
        tokens={state.tokenSelectSide === "sell" ? sellTokens : buyTokens}
        allowImport={state.tokenSelectSide === "buy"}
      />
    </>
  );
}
