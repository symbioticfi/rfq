import { useMutation, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { type Hex, type TypedDataDomain, type TypedDataParameter } from "viem";
import { useChainId, usePublicClient, useSendTransaction, useSignTypedData } from "wagmi";

import { checkApproval, submitOrder } from "../api/client";
import { appChainId, appChainName } from "../providers/chain-config";
import type { RfqQuote } from "../types/quote";
import { useWallet } from "./use-wallet";

const TOAST_ID = "swap-execution";

type ExecuteSwapInput = {
  readonly quote: RfqQuote;
  readonly onOrderCreated: (orderId: string) => void;
};

type ExecuteSwapResult = {
  readonly orderId: string;
  readonly orderStatus: string;
};

type SignTypedDataArgs = {
  readonly account: `0x${string}`;
  readonly domain: TypedDataDomain;
  readonly types: Record<string, readonly TypedDataParameter[]>;
  readonly primaryType: "PermitWitnessTransferFrom";
  readonly message: Record<string, unknown>;
};

function isStatusError(error: unknown, status: number) {
  return typeof error === "object" && error !== null && "status" in error && error.status === status;
}

/**
 * @dev Runs the doc-defined approval, signing, and order-submission flow.
 * @returns A mutation for creating a new RFQ order.
 */
export function useExecuteSwap() {
  const queryClient = useQueryClient();
  const { address: walletAddress, isConnected } = useWallet();
  const activeChainId = useChainId();
  const publicClient = usePublicClient({ chainId: appChainId });
  const sendTransactionMutation = useSendTransaction();
  const signTypedDataMutation = useSignTypedData();

  return useMutation<ExecuteSwapResult, Error, ExecuteSwapInput>({
    mutationKey: ["submit-rfq-order"],
    mutationFn: async ({ quote, onOrderCreated }) => {
      if (!isConnected || !walletAddress) {
        throw new Error("Connect wallet");
      }

      if (quote.isPreview) {
        throw new Error("Refresh the quote with your wallet before submitting");
      }

      if (activeChainId !== appChainId) {
        throw new Error(`Switch to ${appChainName}`);
      }

      if (!publicClient) {
        throw new Error("Network client not ready");
      }

      const accountAddress = walletAddress as `0x${string}`;

      toast.loading("Checking approval…", { id: TOAST_ID });
      const approvalCheck = await checkApproval({
        walletAddress: accountAddress,
        chainId: appChainId,
        token: quote.orderInfo.tokenIn,
        amount: quote.orderInfo.amountIn,
      });

      if (approvalCheck.approval) {
        toast.loading("Approve Permit2…", { id: TOAST_ID });
        const approvalHash = await sendTransactionMutation.mutateAsync({
          account: accountAddress,
          to: approvalCheck.approval.to,
          data: approvalCheck.approval.data,
          value: BigInt(approvalCheck.approval.value),
        });

        const approvalReceipt = await publicClient.waitForTransactionReceipt({
          hash: approvalHash,
        });
        if (approvalReceipt.status !== "success") {
          throw new Error("Approval transaction reverted");
        }
      }

      const signature = await signTypedDataMutation.mutateAsync({
        account: accountAddress,
        domain: quote.permitData.domain as TypedDataDomain,
        types: quote.permitData.types as Record<string, readonly TypedDataParameter[]>,
        primaryType: "PermitWitnessTransferFrom",
        message: quote.permitData.value,
      } satisfies SignTypedDataArgs);

      toast.loading("Submitting order…", { id: TOAST_ID });

      try {
        const response = await submitOrder({
          quote: quote.quote,
          signature: signature as Hex,
        });

        onOrderCreated(response.orderId);
        toast.success("Order submitted", { id: TOAST_ID });

        return {
          orderId: response.orderId,
          orderStatus: response.orderStatus,
        };
      } catch (error) {
        if (isStatusError(error, 409)) {
          await queryClient.invalidateQueries({ queryKey: ["rfq-quote"] });
          throw new Error("Quote expired. Review the refreshed quote and sign again.", {
            cause: error,
          });
        }

        throw error instanceof Error ? error : new Error("Order submission failed");
      }
    },
    onError: (error) => {
      toast.error(error.message, { id: TOAST_ID });
    },
  });
}
