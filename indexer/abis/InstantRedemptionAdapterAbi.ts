import { parseAbi } from "viem";

export const InstantRedemptionAdapterAbi = parseAbi([
  "event SetFiller(address indexed vault, address indexed marketMaker, address indexed filler, bool isAuthorized)",
  "event InvalidateNonce(address indexed vault, address indexed tokenToRedeem, uint256 indexed nonce)",
]);
