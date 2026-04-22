// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.0;

/**
 * @title IInstantRedemptionAdapter
 * @notice Interface for the instant redemption adapter.
 */
interface IInstantRedemptionAdapter {
    /* STRUCTS */

    /**
     * @notice Direct authorized swap payload.
     * @param recipient Recipient of the collateral output.
     * @param vault Vault used for the swap.
     * @param tokenIn Token-to-redeem consumed by the swap.
     * @param amountIn Token-to-redeem amount consumed by the swap.
     * @param amountOut Collateral amount requested from the vault.
     */
    struct Swap {
        address recipient;
        address vault;
        address tokenIn;
        uint256 amountIn;
        uint256 amountOut;
    }

    /**
     * @notice Delegated swap payload signed by an authorized signer.
     * @param recipient Recipient of the collateral output.
     * @param vault Vault used for the swap.
     * @param tokenIn Token-to-redeem consumed by the swap.
     * @param amountIn Token-to-redeem amount consumed by the swap.
     * @param amountOut Collateral amount requested from the vault.
     * @param caller Caller authorized to submit the signed swap onchain.
     * @param signer Authorized market maker, filler, or curator that signed the swap.
     * @param nonce Nonce consumed for replay protection.
     * @param deadline Signed-swap expiry timestamp.
     */
    struct SignedSwap {
        address recipient;
        address vault;
        address tokenIn;
        uint256 amountIn;
        uint256 amountOut;
        address caller;
        address signer;
        uint256 nonce;
        uint256 deadline;
    }

    /**
     * @notice Reusable signed discount policy for one vault redemption pair.
     * @param vault Vault used for the swap.
     * @param tokenToRedeem Token-to-redeem consumed by the swap.
     * @param discount Discount in ppm.
     * @param signer Authorized market maker, filler, or curator that signed the discount.
     * @param protocol Protocol signer that will add the short-lived cosign.
     * @param nonce Nonce consumed for replay protection.
     * @param deadline Discount expiry timestamp.
     */
    struct Discount {
        address vault;
        address tokenToRedeem;
        uint256 discount;
        address signer;
        address protocol;
        uint256 nonce;
        uint48 deadline;
    }

    /**
     * @notice Short-lived protocol-authorized wrapper for a reusable discount.
     * @param discount Reusable signed discount policy.
     * @param signerSignature Signature over the reusable `Discount`.
     * @param protocolDeadline Fresh short-lived protocol expiry timestamp.
     */
    struct DiscountSwap {
        Discount discount;
        bytes signerSignature;
        uint48 protocolDeadline;
    }

    /* FUNCTIONS */

    /**
     * @notice Returns the redemption account for a vault and token-to-redeem pair.
     * @param vault Vault address.
     * @param tokenToRedeem Token-to-redeem address.
     * @return account Redemption account address.
     */
    function getAccount(address vault, address tokenToRedeem) external view returns (address account);

    /**
     * @notice Releases collateral for a funded vault leg.
     * @param swap Direct-caller adapter draw parameters.
     * @dev Assumes `swap.tokenIn` has already been transferred to the adapter before the call.
     */
    function swap(Swap calldata swap) external;

    /**
     * @notice Releases collateral for a delegated, signed vault leg.
     * @param signedSwap Delegated adapter draw parameters.
     * @param signature Signature consumed by the adapter.
     * @dev Assumes `signedSwap.tokenIn` has already been transferred to the adapter before the call.
     */
    function swap(SignedSwap calldata signedSwap, bytes calldata signature) external;

    /**
     * @notice Releases collateral for a discount-backed vault leg.
     * @param discountSwap Protocol-authorized reusable discount payload.
     * @param protocolSignature Protocol signature over `discountSwap`.
     * @param recipient Recipient that receives collateral from the adapter.
     * @param amountIn Token-to-redeem amount consumed by the swap.
     * @param amountOut Collateral amount requested from the adapter.
     * @dev Assumes `discountSwap.discount.tokenToRedeem` has already been transferred to the adapter before the call.
     */
    function swap(
        DiscountSwap calldata discountSwap,
        bytes calldata protocolSignature,
        address recipient,
        uint256 amountIn,
        uint256 amountOut
    ) external;
}
