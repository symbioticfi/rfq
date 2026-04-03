import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useMemo, useRef, useState } from "react";
import { toast } from "sonner";

import { getTrackedOrder } from "../api/client";
import { RFQ_OUTPUT_TOKENS } from "../config/rfq";
import { appChainId } from "../providers/chain-config";
import type { TrackedOrder } from "../types/quote";
import { formatTokenAmountAdaptive } from "../utils/format-number";

type PersistedActiveOrder = {
  readonly chainId: number;
  readonly orderId: string;
  readonly order?: TrackedOrder;
  readonly walletAddress: string;
};

const STORAGE_PREFIX = "rfq-active-order";

function getStorageKey(walletAddress: string) {
  return `${STORAGE_PREFIX}:${appChainId}:${walletAddress.toLowerCase()}`;
}

function isTerminal(order: TrackedOrder | null) {
  return order?.orderStatus === "filled" || order?.orderStatus === "expired" || order?.displayStatus === "Failed";
}

const outputTokensByAddress = new Map(
  RFQ_OUTPUT_TOKENS.map((token) => [token.address.toLowerCase(), token] as const),
);

function getPrimaryOutput(order: TrackedOrder) {
  return order.settledAmounts[0] ?? order.outputs[0] ?? null;
}

function formatFilledOrderMessage(order: TrackedOrder) {
  const output = getPrimaryOutput(order);
  if (!output) {
    return "Order filled";
  }

  const token = outputTokensByAddress.get(output.token.toLowerCase());
  if (!token) {
    return "Order filled";
  }

  return `Order filled: received ${formatTokenAmountAdaptive(output.amount, token.decimals)} ${token.symbol}`;
}

/**
 * @dev Persists and polls a single active order for the connected wallet.
 * @param walletAddress The connected wallet address.
 * @returns Active order state and persistence controls.
 */
export function useActiveOrder(walletAddress: string | undefined) {
  const queryClient = useQueryClient();
  const [persistedOrderId, setPersistedOrderId] = useState<string | null>(null);
  const [persistedOrderSnapshot, setPersistedOrderSnapshot] = useState<TrackedOrder | null>(null);
  const lastSeenOrderStateRef = useRef<{
    readonly orderId: string;
    readonly displayStatus: TrackedOrder["displayStatus"];
  } | null>(null);

  useEffect(() => {
    if (!walletAddress || typeof window === "undefined") {
      setPersistedOrderId(null);
      setPersistedOrderSnapshot(null);
      return;
    }

    const raw = window.localStorage.getItem(getStorageKey(walletAddress));
    if (!raw) {
      setPersistedOrderId(null);
      setPersistedOrderSnapshot(null);
      return;
    }

    try {
      const parsed = JSON.parse(raw) as PersistedActiveOrder;
      if (parsed.chainId === appChainId && parsed.walletAddress.toLowerCase() === walletAddress.toLowerCase()) {
        setPersistedOrderId(parsed.orderId);
        setPersistedOrderSnapshot(parsed.order ?? null);
        return;
      }
    } catch {
      window.localStorage.removeItem(getStorageKey(walletAddress));
    }

    setPersistedOrderId(null);
    setPersistedOrderSnapshot(null);
  }, [walletAddress]);

  const query = useQuery({
    queryKey: ["active-order", appChainId, walletAddress, persistedOrderId],
    enabled: Boolean(walletAddress && persistedOrderId),
    queryFn: async () => {
      if (!persistedOrderId) {
        return null;
      }

      return getTrackedOrder(persistedOrderId);
    },
    refetchInterval: (queryResult) => {
      const order = queryResult.state.data ?? persistedOrderSnapshot;

      return isTerminal(order) ? false : 3_000;
    },
    staleTime: 0,
  });

  const activeOrder = query.data ?? persistedOrderSnapshot;

  useEffect(() => {
    if (!walletAddress || typeof window === "undefined") {
      return;
    }

    const order = activeOrder;
    if (!order || !isTerminal(order)) {
      return;
    }

    window.localStorage.removeItem(getStorageKey(walletAddress));
    setPersistedOrderId(null);
    setPersistedOrderSnapshot(null);
  }, [activeOrder, walletAddress]);

  useEffect(() => {
    if (!walletAddress || typeof window === "undefined") {
      return;
    }

    const order = query.data ?? null;
    if (!order || isTerminal(order)) {
      return;
    }

    window.localStorage.setItem(
      getStorageKey(walletAddress),
      JSON.stringify({
        chainId: appChainId,
        orderId: order.orderId,
        order,
        walletAddress,
      } satisfies PersistedActiveOrder),
    );
    setPersistedOrderSnapshot(order);
  }, [query.data, walletAddress]);

  useEffect(() => {
    const order = activeOrder;
    if (!order) {
      lastSeenOrderStateRef.current = null;
      return;
    }

    const current = lastSeenOrderStateRef.current;
    if (current && current.orderId === order.orderId && current.displayStatus !== order.displayStatus) {
      if (order.displayStatus === "Filled") {
        toast.success(formatFilledOrderMessage(order));
        if (walletAddress) {
          void queryClient.invalidateQueries({
            queryKey: ["token-balance", appChainId, walletAddress],
          });
        }
      } else if (order.displayStatus === "Expired") {
        toast.error("Order expired");
      }
    }

    lastSeenOrderStateRef.current = {
      orderId: order.orderId,
      displayStatus: order.displayStatus,
    };
  }, [activeOrder, queryClient, walletAddress]);

  const persistOrder = useMemo(
    () => (orderId: string) => {
      if (!walletAddress || typeof window === "undefined") {
        return;
      }

      window.localStorage.setItem(
        getStorageKey(walletAddress),
        JSON.stringify({
          chainId: appChainId,
          orderId,
          walletAddress,
        } satisfies PersistedActiveOrder),
      );
      setPersistedOrderId(orderId);
      setPersistedOrderSnapshot(null);
    },
    [walletAddress],
  );

  const clearOrder = useMemo(
    () => () => {
      if (walletAddress && typeof window !== "undefined") {
        window.localStorage.removeItem(getStorageKey(walletAddress));
      }

      setPersistedOrderId(null);
      setPersistedOrderSnapshot(null);
    },
    [walletAddress],
  );

  return {
    ...query,
    activeOrder,
    activeOrderId: persistedOrderId,
    hasActiveOrder: Boolean(activeOrder && !isTerminal(activeOrder)),
    persistOrder,
    clearOrder,
  };
}
