import { encodeFunctionData, erc20Abi, maxUint256, parseAbi, parseEther } from "viem";

import type { BackendEnv } from "../config/env";
import type { ApprovalPayload } from "../types/domain";
import type { ApprovalCheckInput, PublicClient, WalletClient } from "./shared";
import { newUuid } from "../utils/ids";
import { getLowercasedAddress } from "../lib/reactor";

const LOCAL_ETH_TARGET = parseEther("0.1");
const LOCAL_TOKEN_TARGET = parseEther("1000000");
const mintableErc20Abi = parseAbi(["function mint(address to, uint256 amount)"]);

type LocalFaucetAsset = {
  readonly token: `0x${string}`;
  readonly symbol: string;
  readonly name: string;
  readonly decimals: number;
  readonly amount: string;
  readonly kind: "native" | "erc20";
};

export class FundingService {
  readonly #env: BackendEnv;
  readonly #publicClient: PublicClient;
  readonly #walletClient: WalletClient;

  constructor(input: {
    readonly env: BackendEnv;
    readonly publicClient: PublicClient;
    readonly walletClient: WalletClient;
  }) {
    this.#env = input.env;
    this.#publicClient = input.publicClient;
    this.#walletClient = input.walletClient;
  }

  async checkApproval(input: ApprovalCheckInput) {
    this.#assertChain(input.chainId);

    const requestId = newUuid();
    const allowance = await this.#publicClient.readContract({
      address: input.token,
      abi: erc20Abi,
      functionName: "allowance",
      args: [input.walletAddress, this.#env.permit2Address],
    });

    if (allowance >= BigInt(input.amount)) {
      return {
        requestId,
        approval: null,
        cancel: null,
      };
    }

    const approval: ApprovalPayload = {
      to: input.token,
      data: encodeFunctionData({
        abi: erc20Abi,
        functionName: "approve",
        args: [this.#env.permit2Address, maxUint256],
      }),
      value: "0",
    };

    return {
      requestId,
      approval,
      cancel: null,
    };
  }

  async fundLocalWallet(input: { readonly walletAddress: `0x${string}` }) {
    this.#assertLocalFundingEnabled();

    const inputTokens = this.#env.deployment.tokens.input.map((token) => token.address as `0x${string}`);
    const primaryToken = inputTokens[0];
    if (!primaryToken) {
      throw new Error("Local input token unavailable");
    }

    const [ethBalance, tokenBalances] = await Promise.all([
      this.#publicClient.getBalance({ address: input.walletAddress }),
      Promise.all(
        inputTokens.map((tokenAddress) =>
          this.#publicClient.readContract({
            address: tokenAddress,
            abi: erc20Abi,
            functionName: "balanceOf",
            args: [input.walletAddress],
          }),
        ),
      ),
    ]);

    let fundedEth = 0n;
    let fundedPrimaryToken = 0n;

    if (ethBalance < LOCAL_ETH_TARGET) {
      fundedEth = LOCAL_ETH_TARGET - ethBalance;
      const hash = await this.#walletClient.sendTransaction({
        account: this.#env.localFunder,
        to: input.walletAddress,
        value: fundedEth,
      });
      await this.#publicClient.waitForTransactionReceipt({ hash });
    }

    for (const [index, tokenAddress] of inputTokens.entries()) {
      const tokenBalance = tokenBalances[index];
      if (tokenBalance === undefined || tokenBalance >= LOCAL_TOKEN_TARGET) {
        continue;
      }

      const fundedTokenAmount = LOCAL_TOKEN_TARGET - tokenBalance;
      if (index === 0) {
        fundedPrimaryToken = fundedTokenAmount;
      }

      const hash = await this.#walletClient.sendTransaction({
        account: this.#env.localFunder,
        to: tokenAddress,
        data: encodeFunctionData({
          abi: mintableErc20Abi,
          functionName: "mint",
          args: [input.walletAddress, fundedTokenAmount],
        }),
      });
      await this.#publicClient.waitForTransactionReceipt({ hash });
    }

    return {
      requestId: newUuid(),
      walletAddress: input.walletAddress,
      fundedEth: fundedEth.toString(),
      fundedToken: fundedPrimaryToken.toString(),
      token: primaryToken,
    };
  }

  async describeLocalFaucet() {
    return {
      requestId: newUuid(),
      assets: this.#getLocalFaucetAssets(),
    };
  }

  async faucetLocalWallet(input: { readonly walletAddress: `0x${string}` }) {
    this.#assertFaucetFundingEnabled();

    const fundedAssets = this.#getLocalFaucetAssets();
    const nextNonce = await this.#publicClient.getTransactionCount({
      address: this.#env.localFunder.address,
      blockTag: "pending",
    });
    const hashes = await Promise.all(
      fundedAssets.map(async (asset, index) => {
        const nonce = nextNonce + index;

        if (asset.kind === "native") {
          return this.#walletClient.sendTransaction({
            account: this.#env.localFunder,
            to: input.walletAddress,
            value: BigInt(asset.amount),
            nonce,
          });
        }

        return this.#walletClient.sendTransaction({
          account: this.#env.localFunder,
          to: asset.token,
          data: encodeFunctionData({
            abi: mintableErc20Abi,
            functionName: "mint",
            args: [input.walletAddress, BigInt(asset.amount)],
          }),
          nonce,
        });
      }),
    );

    await Promise.all(hashes.map(async (hash) => this.#publicClient.waitForTransactionReceipt({ hash })));

    return {
      requestId: newUuid(),
      walletAddress: input.walletAddress,
      fundedAssets,
    };
  }

  #assertChain(chainId: number) {
    if (chainId !== this.#env.chainId) {
      throw new Error(`Unsupported chainId ${chainId}`);
    }
  }

  #assertLocalFundingEnabled() {
    if (this.#env.deploymentEnv !== "local") {
      throw new Error("Local funding unavailable");
    }
  }

  #assertFaucetFundingEnabled() {
    if (this.#env.deploymentEnv !== "local" && this.#env.deploymentEnv !== "hoodi") {
      throw new Error("Faucet unavailable");
    }
  }

  #getLocalFaucetAssets(): readonly LocalFaucetAsset[] {
    this.#assertFaucetFundingEnabled();

    const assets: LocalFaucetAsset[] = [];
    const seenTokens = new Set<string>();
    const deploymentTokens = [...this.#env.deployment.tokens.input, ...this.#env.deployment.tokens.output];

    for (const token of deploymentTokens) {
      const normalizedToken = getLowercasedAddress(token.address) as `0x${string}`;
      if (seenTokens.has(normalizedToken)) {
        continue;
      }

      seenTokens.add(normalizedToken);
      const isNative = normalizedToken === "0x0000000000000000000000000000000000000000";

      assets.push({
        token: normalizedToken,
        symbol: token.symbol,
        name: token.name,
        decimals: token.decimals,
        amount: isNative ? LOCAL_ETH_TARGET.toString() : LOCAL_TOKEN_TARGET.toString(),
        kind: isNative ? "native" : "erc20",
      });
    }

    return assets;
  }
}
