import { Button } from "../../components/button";
import { Spinner } from "../../components/spinner";
import { useExecuteSwap } from "../../hooks/use-execute-swap";
import { useTokenBalance } from "../../hooks/use-token-balances";
import { appChainId, appChainName } from "../../providers/chain-config";
import { useWallet } from "../../hooks/use-wallet";
import type { RfqQuote } from "../../types/quote";
import type { Token } from "../../types/token";
import { toast } from "sonner";
import { useChainId, useSwitchChain } from "wagmi";
import styles from "./swap-action-button.module.css";

type SwapActionButtonProps = {
  readonly sellToken: Token | null;
  readonly buyToken: Token | null;
  readonly sellAmount: string;
  readonly quote: RfqQuote | null;
  readonly isQuoting: boolean;
  readonly quoteError: string | null;
  readonly hasActiveOrder: boolean;
  readonly onOrderCreated: (orderId: string) => void;
};

type ButtonState = {
  readonly label: string;
  readonly disabled: boolean;
  readonly variant: "primary" | "secondary";
  readonly loading: boolean;
  readonly isConnect: boolean;
};

function deriveButtonState(input: {
  readonly isConnected: boolean;
  readonly sellToken: Token | null;
  readonly buyToken: Token | null;
  readonly sellAmount: string;
  readonly quote: RfqQuote | null;
  readonly isQuoting: boolean;
  readonly isSubmitting: boolean;
  readonly quoteError: string | null;
  readonly hasActiveOrder: boolean;
  readonly balanceValue: bigint | undefined;
  readonly isWrongChain: boolean;
}): ButtonState {
  if (!input.isConnected) {
    return {
      label: "Connect wallet",
      disabled: false,
      variant: "primary",
      loading: false,
      isConnect: true,
    };
  }

  if (input.hasActiveOrder) {
    return {
      label: "Pending",
      disabled: true,
      variant: "primary",
      loading: true,
      isConnect: false,
    };
  }

  if (input.isWrongChain) {
    return {
      label: `Switch to ${appChainName}`,
      disabled: false,
      variant: "primary",
      loading: false,
      isConnect: false,
    };
  }

  if (!input.sellToken || !input.buyToken) {
    return {
      label: "Select token",
      disabled: true,
      variant: "secondary",
      loading: false,
      isConnect: false,
    };
  }

  if (!input.sellAmount || Number.parseFloat(input.sellAmount) <= 0) {
    return {
      label: "Enter amount",
      disabled: true,
      variant: "secondary",
      loading: false,
      isConnect: false,
    };
  }

  if (input.isSubmitting) {
    return {
      label: "Signing",
      disabled: true,
      variant: "primary",
      loading: true,
      isConnect: false,
    };
  }

  if (input.balanceValue !== undefined) {
    try {
      const amountRaw = BigInt(input.quote?.orderInfo.amountIn ?? "0");
      if (amountRaw > input.balanceValue) {
        return {
          label: `Insufficient ${input.sellToken.symbol}`,
          disabled: true,
          variant: "secondary",
          loading: false,
          isConnect: false,
        };
      }
    } catch {
      return {
        label: "Quote unavailable",
        disabled: true,
        variant: "secondary",
        loading: false,
        isConnect: false,
      };
    }
  }

  if (input.isQuoting) {
    return {
      label: "Finding route",
      disabled: true,
      variant: "primary",
      loading: true,
      isConnect: false,
    };
  }

  if (input.quoteError) {
    return {
      label: "Quote unavailable",
      disabled: true,
      variant: "secondary",
      loading: false,
      isConnect: false,
    };
  }

  if (!input.quote) {
    return {
      label: "Quote unavailable",
      disabled: true,
      variant: "secondary",
      loading: false,
      isConnect: false,
    };
  }

  if (input.quote.isPreview) {
    return {
      label: "Connect wallet",
      disabled: false,
      variant: "primary",
      loading: false,
      isConnect: true,
    };
  }

  return {
    label: "Swap",
    disabled: false,
    variant: "primary",
    loading: false,
    isConnect: false,
  };
}

/**
 * @dev Renders the primary quote/submit CTA and drives the order-submission flow.
 * @param props Current quote state and order tracking controls.
 * @returns The primary action button.
 */
export function SwapActionButton({
  sellToken,
  buyToken,
  sellAmount,
  quote,
  isQuoting,
  quoteError,
  hasActiveOrder,
  onOrderCreated,
}: SwapActionButtonProps) {
  const { isConnected, login, ready } = useWallet();
  const activeChainId = useChainId();
  const { mutateAsync: switchChainMutationAsync } = useSwitchChain();
  const { data: balance } = useTokenBalance(sellToken);
  const executeSwap = useExecuteSwap();
  const isWrongChain = isConnected && activeChainId !== appChainId;

  const buttonState = deriveButtonState({
    isConnected,
    sellToken,
    buyToken,
    sellAmount,
    quote,
    isQuoting,
    isSubmitting: executeSwap.isPending,
    quoteError,
    hasActiveOrder,
    balanceValue: balance?.value,
    isWrongChain,
  });

  const handleClick = () => {
    if (buttonState.isConnect) {
      void login();
      return;
    }

    if (isWrongChain) {
      if (!switchChainMutationAsync) {
        toast.error(`Switch to ${appChainName}`);
        return;
      }

      void Promise.resolve(switchChainMutationAsync({ chainId: appChainId })).catch(() => {
        toast.error(`Switch to ${appChainName}`);
      });
      return;
    }

    if (!quote) {
      return;
    }

    executeSwap.mutate({
      quote,
      onOrderCreated,
    });
  };

  return (
    <div className={styles.wrapper}>
      <Button
        variant={buttonState.variant}
        fullWidth
        disabled={buttonState.disabled || (buttonState.isConnect && !ready)}
        onClick={handleClick}
        className={[styles.button, hasActiveOrder ? styles.pendingButton : ""].filter(Boolean).join(" ")}
        aria-busy={buttonState.loading}
      >
        {buttonState.loading && <Spinner size={16} />}
        {buttonState.label}
      </Button>
    </div>
  );
}
