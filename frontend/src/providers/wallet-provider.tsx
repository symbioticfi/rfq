import { type ConnectedWallet, useLinkAccount, useLogin, usePrivy, useWallets } from "@privy-io/react-auth";
import { useSetActiveWallet } from "@privy-io/wagmi";
import { createContext, type ReactNode, useContext, useEffect, useRef } from "react";
import { toast } from "sonner";
import {
  type Connector,
  useConnect,
  useConnection,
  useConnections,
  useConnectors,
  useDisconnect,
  useSwitchConnection,
} from "wagmi";

import { appChainId } from "./chain-config";

type WalletListItem = {
  readonly address: string;
  readonly shortAddress: string;
  readonly isActive: boolean;
};

type WalletContextValue = {
  readonly activateWallet: (address: string) => void | Promise<void>;
  readonly address: string | undefined;
  readonly otherWallets: readonly WalletListItem[];
  readonly shortAddress: string | null;
  readonly isConnected: boolean;
  readonly login: () => void | Promise<void>;
  readonly switchWallet: () => void | Promise<void>;
  readonly logout: () => void | Promise<void>;
  readonly ready: boolean;
};

const disabledWalletValue: WalletContextValue = {
  activateWallet: () => undefined,
  address: undefined,
  otherWallets: [],
  shortAddress: null,
  isConnected: false,
  login: () => undefined,
  switchWallet: () => undefined,
  logout: () => undefined,
  ready: false,
};

const WalletContext = createContext<WalletContextValue>(disabledWalletValue);

function formatShortAddress(address: string | undefined) {
  return address ? `${address.slice(0, 6)}...${address.slice(-4)}` : null;
}

function getWalletListItems(wallets: readonly ConnectedWallet[], activeAddress: string | undefined) {
  const seenAddresses = new Set<string>();
  const normalizedActiveAddress = activeAddress?.toLowerCase();
  const items: WalletListItem[] = [];

  for (const wallet of wallets) {
    const normalizedWalletAddress = wallet.address.toLowerCase();

    if (seenAddresses.has(normalizedWalletAddress)) {
      continue;
    }

    seenAddresses.add(normalizedWalletAddress);

    const shortAddress = formatShortAddress(wallet.address);

    if (!shortAddress) {
      continue;
    }

    items.push({
      address: wallet.address,
      shortAddress,
      isActive: normalizedWalletAddress === normalizedActiveAddress,
    });
  }

  return items;
}

type FallbackConnection = {
  readonly accounts: readonly string[];
  readonly connector: {
    readonly uid: string;
  };
};

function getWalletListItemsFromConnections(
  connections: readonly FallbackConnection[],
  activeAddress: string | undefined,
) {
  const seenAddresses = new Set<string>();
  const normalizedActiveAddress = activeAddress?.toLowerCase();
  const items: WalletListItem[] = [];

  for (const connection of connections) {
    const walletAddress = connection.accounts[0];

    if (!walletAddress) {
      continue;
    }

    const normalizedWalletAddress = walletAddress.toLowerCase();

    if (seenAddresses.has(normalizedWalletAddress)) {
      continue;
    }

    seenAddresses.add(normalizedWalletAddress);

    const shortAddress = formatShortAddress(walletAddress);

    if (!shortAddress) {
      continue;
    }

    items.push({
      address: walletAddress,
      shortAddress,
      isActive: normalizedWalletAddress === normalizedActiveAddress,
    });
  }

  return items;
}

function hasWalletAddress(account: unknown): account is { readonly address: string; readonly type: string } {
  return (
    typeof account === "object" &&
    account !== null &&
    "type" in account &&
    "address" in account &&
    typeof account.type === "string" &&
    account.type === "wallet" &&
    typeof account.address === "string"
  );
}

async function waitForConnectedWallet(
  getWallets: () => ConnectedWallet[],
  address: string,
  retries = 30,
  delayMs = 100,
) {
  const normalizedAddress = address.toLowerCase();

  for (let attempt = 0; attempt < retries; attempt += 1) {
    const wallet = getWallets().find((candidate) => candidate.address.toLowerCase() === normalizedAddress);

    if (wallet) {
      return wallet;
    }

    await new Promise((resolve) => window.setTimeout(resolve, delayMs));
  }

  throw new Error(`Privy wallet ${address} was not available for activation`);
}

function isProviderNotFoundError(error: unknown) {
  return error instanceof Error && error.name === "ProviderNotFoundError";
}

export function PrivyWalletProvider({ children }: { readonly children: ReactNode }) {
  const account = useConnection();
  const { ready, authenticated, logout: privyLogout } = usePrivy();
  const { ready: walletsReady, wallets } = useWallets();
  const walletsRef = useRef(wallets);
  const { setActiveWallet } = useSetActiveWallet();

  useEffect(() => {
    walletsRef.current = wallets;
  }, [wallets]);

  const activateWalletByAddress = async (walletAddress: string) => {
    const connectedWallet = await waitForConnectedWallet(() => walletsRef.current, walletAddress);
    await setActiveWallet(connectedWallet);
  };

  const { login } = useLogin({
    onComplete: ({ loginAccount }) => {
      if (hasWalletAddress(loginAccount)) {
        void activateWalletByAddress(loginAccount.address);
      }
    },
  });
  const { linkWallet } = useLinkAccount({
    onSuccess: ({ linkedAccount }) => {
      if (hasWalletAddress(linkedAccount)) {
        void activateWalletByAddress(linkedAccount.address);
      }
    },
  });

  const address = account.address;
  const otherWallets = getWalletListItems(wallets, address).filter((wallet) => !wallet.isActive);
  const shortAddress = formatShortAddress(address);

  const value: WalletContextValue = {
    activateWallet: async (nextAddress) => {
      const connectedWallet = walletsRef.current.find(
        (wallet) => wallet.address.toLowerCase() === nextAddress.toLowerCase(),
      );

      if (!connectedWallet) {
        return;
      }

      await setActiveWallet(connectedWallet);
    },
    address,
    otherWallets,
    shortAddress,
    isConnected: authenticated && account.isConnected && Boolean(address),
    login: async () => {
      if (authenticated) {
        const firstWallet = walletsRef.current[0];

        if (firstWallet) {
          await setActiveWallet(firstWallet);
          return;
        }

        await linkWallet();
        return;
      }

      await login();
    },
    switchWallet: () => linkWallet(),
    logout: async () => privyLogout(),
    ready: ready && walletsReady && account.status !== "connecting",
  };

  return <WalletContext.Provider value={value}>{children}</WalletContext.Provider>;
}

export function InjectedWalletProvider({ children }: { readonly children: ReactNode }) {
  const account = useConnection();
  const connections = useConnections();
  const connectors = useConnectors();
  const { mutateAsync: connectMutationAsync } = useConnect();
  const { mutateAsync: disconnectMutationAsync } = useDisconnect();
  const switchConnectionMutation = useSwitchConnection();

  const address = account.address;
  const shortAddress = formatShortAddress(address);
  const otherWallets = getWalletListItemsFromConnections(connections, address).filter((wallet) => !wallet.isActive);

  const connectedConnectorUids = new Set(connections.map((connection) => connection.connector.uid));
  const availableConnectors = connectors.filter((connector) => !connectedConnectorUids.has(connector.uid));
  const connectFirstAvailableConnector = async (candidates: readonly Connector[]) => {
    for (const connector of candidates) {
      try {
        const provider = await connector.getProvider({ chainId: appChainId });

        if (!provider) {
          continue;
        }

        await connectMutationAsync({ connector, chainId: appChainId });
        return;
      } catch (error) {
        if (isProviderNotFoundError(error)) {
          continue;
        }

        throw error;
      }
    }

    toast.error("No injected wallet found. Install or enable a browser wallet.");
  };

  const value: WalletContextValue = {
    activateWallet: async (nextAddress) => {
      const targetConnection = connections.find((connection) =>
        connection.accounts.some((candidateAddress) => {
          return candidateAddress.toLowerCase() === nextAddress.toLowerCase();
        }),
      );

      if (!targetConnection) {
        return;
      }

      await switchConnectionMutation.mutateAsync({ connector: targetConnection.connector });
    },
    address,
    otherWallets,
    shortAddress,
    isConnected: account.isConnected && Boolean(address),
    login: async () =>
      connectFirstAvailableConnector(availableConnectors.length > 0 ? availableConnectors : connectors),
    switchWallet: async () => {
      if (availableConnectors.length === 0) {
        return;
      }

      await connectFirstAvailableConnector(availableConnectors);
    },
    logout: async () => {
      if (account.connector) {
        await disconnectMutationAsync({ connector: account.connector });

        return;
      }

      await disconnectMutationAsync();
    },
    ready: connectors.length > 0 && !account.isConnecting && !account.isReconnecting,
  };

  return <WalletContext.Provider value={value}>{children}</WalletContext.Provider>;
}

export function useWallet() {
  return useContext(WalletContext);
}
