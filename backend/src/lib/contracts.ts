import { parseAbi } from "viem";

export const permit2Abi = parseAbi([
  "function allowance(address owner, address spender) view returns (uint160 amount, uint48 expiration, uint48 nonce)",
]);

export const registryAbi = parseAbi([
  "function totalEntities() view returns (uint256)",
  "function entity(uint256 index) view returns (address)",
]);

export const vaultAbi = parseAbi(["function collateral() view returns (address)"]);

export const instantRedemptionAdapterAbi = parseAbi([
  "function VAULT_FACTORY() view returns (address)",
  "function getMaxAssets(address vault) view returns (uint256)",
  "function getMaxRate(address vault, address tokenToRedeem) view returns (uint256)",
  "function getAmountOut(address tokenIn, address tokenOut, uint256 amountIn) view returns (uint256)",
  "function isPaused(address vault) view returns (bool)",
  "function isUsedNonce(address vault, address tokenToRedeem, uint256 nonce) view returns (bool)",
  "function marketMaker(address vault) view returns (address)",
  "function minDiscount(address vault, address tokenToRedeem) view returns (uint256)",
  "function isFiller(address marketMaker, address filler) view returns (bool)",
]);

export const curatorRegistryAbi = parseAbi(["function getCurator(address vault) view returns (address)"]);
