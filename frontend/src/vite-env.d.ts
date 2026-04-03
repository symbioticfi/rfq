/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_API_URL: string;
  readonly VITE_DEPLOYMENT_ENV?: "local" | "hoodi" | "mainnet";
  readonly VITE_PRIVY_APP_ID: string;
  readonly VITE_WALLET_CHAIN_NAME?: string;
  readonly VITE_WALLET_RPC_URL?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}

declare module "*.module.css" {
  const classes: Record<string, string>;
  export default classes;
}

declare module "ethereum-blockies-base64" {
  export default function makeBlockie(address: string): string;
}
