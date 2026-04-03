import type { PrivyClientConfig } from "@privy-io/react-auth";
import { appChain } from "./chain-config";

export const PRIVY_APP_ID = import.meta.env.VITE_PRIVY_APP_ID || "placeholder-app-id";
export const IS_PRIVY_CONFIGURED = PRIVY_APP_ID !== "placeholder-app-id";

export const privyConfig: PrivyClientConfig = {
  defaultChain: appChain,
  supportedChains: [appChain],
  appearance: {
    theme: "dark",
    accentColor: "#C0FD5C",
    logo: "/mark.png",
    showWalletLoginFirst: true,
    walletChainType: "ethereum-only",
  },
  loginMethods: ["wallet"],
  embeddedWallets: {
    ethereum: {
      createOnLogin: "off",
    },
  },
};
