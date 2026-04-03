import { parseAbi, parseAbiParameters } from "viem";

export const erc20Abi = parseAbi([
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function decimals() view returns (uint8)",
]);

export const vaultAbi = parseAbi(["function collateral() view returns (address)"]);

export const curatorRegistryAbi = parseAbi(["function getCurator(address vault) view returns (address)"]);

export const instantRedemptionAdapterAbi = parseAbi([
  "function isPaused(address vault) view returns (bool)",
  "function getMaxAssets(address vault) view returns (uint256)",
  "function getMaxRate(address vault, address tokenIn) view returns (uint256)",
  "function getAmountOut(address tokenIn, address tokenOut, uint256 amountIn) view returns (uint256)",
  "function marketMaker(address vault) view returns (address)",
  "function isFiller(address marketMaker, address filler) view returns (bool)",
]);

export const reactorOrderEncodingParameters = parseAbiParameters(
  "((address tokenIn,uint256 amountIn,(address token,uint256 amount,address recipient)[] outputs,uint256 deadline,uint256 nonce,address protocol) request,bytes swapperSignature,address swapper,address filler)",
);

export const executorCallEncodingParameters = parseAbiParameters("(address target,uint256 value,bytes data)[]");

export const executorFillMixedParameters = parseAbiParameters(
  "((address tokenIn,uint256 amountIn,(address token,uint256 amount,address recipient)[] outputs,uint256 deadline,uint256 nonce,address protocol) request,bytes swapperSignature,address swapper,address filler) order, bytes protocolSignature, (address recipient,address vault,address tokenIn,uint256 amountIn,uint256 amountOut)[] swapInputs, (((address vault,address tokenToRedeem,uint256 discount,address signer,address protocol,uint256 nonce,uint48 deadline) discount,bytes signerSignature,uint48 protocolDeadline) discountSwap, bytes protocolSignature, address recipient, uint256 amountIn, uint256 amountOut)[] discountSwapInputs, bytes executorData",
);
