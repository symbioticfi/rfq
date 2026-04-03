import { defineChain } from "viem";
import { hoodi, mainnet } from "wagmi/chains";

import deployment from "../generated/deployment.json";

const configuredChainId = deployment.chain.id;
const configuredRpcUrl = import.meta.env.VITE_WALLET_RPC_URL?.trim() || deployment.chain.rpcUrl;
const configuredChainName = import.meta.env.VITE_WALLET_CHAIN_NAME?.trim() || deployment.chain.name;
const presetChain = [mainnet, hoodi].find((chain) => chain.id === configuredChainId);
const configuredRpcUrls = configuredRpcUrl
  ? [configuredRpcUrl]
  : (presetChain?.rpcUrls.default.http ?? mainnet.rpcUrls.default.http);
const configuredNativeCurrency = presetChain?.nativeCurrency ?? mainnet.nativeCurrency;
const chainContracts = presetChain?.contracts;
const configuredBlockExplorers = deployment.chain.explorerUrl
  ? {
      default: {
        name: "Explorer",
        url: deployment.chain.explorerUrl,
      },
    }
  : (presetChain?.blockExplorers ?? mainnet.blockExplorers);

export const appChain =
  presetChain && !configuredRpcUrl && configuredChainName === presetChain.name
    ? presetChain
    : defineChain({
        id: configuredChainId,
        name: configuredChainName,
        nativeCurrency: configuredNativeCurrency,
        rpcUrls: {
          default: {
            http: configuredRpcUrls,
          },
          public: {
            http: configuredRpcUrls,
          },
        },
        blockExplorers: configuredBlockExplorers,
        contracts: chainContracts,
        testnet: deployment.chain.testnet,
      });

export const appChainId = appChain.id;
export const appChainName = appChain.name;
export const appChainHasCustomRpc = Boolean(configuredRpcUrl);
