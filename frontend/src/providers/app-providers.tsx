import { PrivyProvider } from "@privy-io/react-auth";
import { WagmiProvider } from "@privy-io/wagmi";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { ReactNode } from "react";
import { Toaster } from "sonner";
import { WagmiProvider as WagmiProviderCore } from "wagmi";

import { IS_PRIVY_CONFIGURED, PRIVY_APP_ID, privyConfig } from "./privy-config";
import { ThemeProvider, useTheme } from "./theme-provider";
import { privyWagmiConfig, readonlyWagmiConfig } from "./wagmi-config";
import { InjectedWalletProvider, PrivyWalletProvider } from "./wallet-provider";

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 10_000,
      refetchOnWindowFocus: false,
    },
  },
});

function CoreProviders({ children }: { readonly children: ReactNode }) {
  const { resolvedTheme } = useTheme();

  return (
    <QueryClientProvider client={queryClient}>
      {children}
      <Toaster
        position="bottom-right"
        theme={resolvedTheme}
        toastOptions={{
          style: {
            fontFamily: "var(--font-mono)",
            background: "var(--color-surface)",
            border: "1px solid var(--color-border)",
            color: "var(--color-text-primary)",
          },
        }}
      />
    </QueryClientProvider>
  );
}

function AppProvidersInner({ children }: { readonly children: ReactNode }) {
  const { resolvedTheme } = useTheme();
  const themedPrivyConfig = {
    ...privyConfig,
    appearance: {
      ...privyConfig.appearance,
      theme: resolvedTheme,
    },
  };

  if (!IS_PRIVY_CONFIGURED) {
    return (
      <CoreProviders>
        <WagmiProviderCore config={readonlyWagmiConfig}>
          <InjectedWalletProvider>{children}</InjectedWalletProvider>
        </WagmiProviderCore>
      </CoreProviders>
    );
  }

  return (
    <PrivyProvider appId={PRIVY_APP_ID} config={themedPrivyConfig}>
      <CoreProviders>
        <WagmiProvider config={privyWagmiConfig}>
          <PrivyWalletProvider>{children}</PrivyWalletProvider>
        </WagmiProvider>
      </CoreProviders>
    </PrivyProvider>
  );
}

export function AppProviders({ children }: { readonly children: ReactNode }) {
  return (
    <ThemeProvider>
      <AppProvidersInner>{children}</AppProvidersInner>
    </ThemeProvider>
  );
}
