import { parseAbi } from "viem";

export const ReactorAbi = parseAbi([
  "event Fill(((address tokenIn,uint256 amountIn,(address token,uint256 amount,address recipient)[] outputs,uint256 deadline,uint256 nonce,address protocol) request,bytes swapperSignature,address swapper,address filler) order)",
]);
