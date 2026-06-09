// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.0;

/// @dev Precision used for discount values expressed in ppm.
uint256 constant DISCOUNT_PRECISION = 10 ** 6;

/// @dev EIP-712 typehash for signed adapter swap legs.
bytes32 constant SIGNED_SWAP_TYPEHASH = keccak256(
    "SignedSwap(address recipient,address tokenIn,uint256 amountIn,uint256 amountOut,address caller,address signer,uint256 nonce,uint48 deadline)"
);

/// @dev EIP-712 typehash for reusable signed discount policies.
bytes32 constant DISCOUNT_TYPEHASH = keccak256(
    "Discount(address tokenToRedeem,uint256 discount,address signer,address protocol,uint256 nonce,uint48 deadline)"
);

/// @dev EIP-712 typehash for protocol-wrapped discount swaps.
bytes32 constant DISCOUNT_SWAP_TYPEHASH = keccak256(
    "DiscountSwap(Discount discount,bytes signerSignature,uint48 protocolDeadline)"
    "Discount(address tokenToRedeem,uint256 discount,address signer,address protocol,uint256 nonce,uint48 deadline)"
);

/**
 * @title ILiquidLaneAdapter
 * @notice Interface for the LiquidLane adapter, bound to a single vault.
 */
interface ILiquidLaneAdapter {
    /* STRUCTS */

    /**
     * @notice Direct authorized swap payload.
     * @param recipient Recipient of the vault-asset output.
     * @param tokenIn Token-to-redeem consumed by the swap.
     * @param amountIn Token-to-redeem amount consumed by the swap.
     * @param amountOut Vault-asset amount requested from the vault.
     */
    struct Swap {
        address recipient;
        address tokenIn;
        uint256 amountIn;
        uint256 amountOut;
    }

    /**
     * @notice Delegated swap payload signed by an authorized signer.
     * @param recipient Recipient of the vault-asset output.
     * @param tokenIn Token-to-redeem consumed by the swap.
     * @param amountIn Token-to-redeem amount consumed by the swap.
     * @param amountOut Vault-asset amount requested from the vault.
     * @param caller Caller authorized to submit the signed swap onchain.
     * @param signer Authorized market maker, filler, or curator that signed the swap.
     * @param nonce Nonce consumed for replay protection.
     * @param deadline Signed-swap expiry timestamp.
     */
    struct SignedSwap {
        address recipient;
        address tokenIn;
        uint256 amountIn;
        uint256 amountOut;
        address caller;
        address signer;
        uint256 nonce;
        uint48 deadline;
    }

    /**
     * @notice Reusable signed discount policy for one redemption pair.
     * @param tokenToRedeem Token-to-redeem consumed by the swap.
     * @param discount Discount in ppm.
     * @param signer Authorized market maker, filler, or curator that signed the discount.
     * @param protocol Protocol signer that will add the short-lived cosign.
     * @param nonce Nonce consumed for replay protection.
     * @param deadline Discount expiry timestamp.
     */
    struct Discount {
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
     * @notice Releases collateral for a funded direct adapter leg.
     * @param swap Direct-caller adapter draw parameters.
     * @dev Assumes `swap.tokenIn` has already been transferred to the adapter before the call.
     */
    function swap(Swap calldata swap) external;

    /**
     * @notice Releases collateral for a delegated, signed adapter leg.
     * @param signedSwap Delegated adapter draw parameters.
     * @param signature Signature consumed by the adapter.
     * @dev Assumes `signedSwap.tokenIn` has already been transferred to the adapter before the call.
     */
    function swap(SignedSwap calldata signedSwap, bytes calldata signature) external;

    /**
     * @notice Releases collateral for a discount-backed adapter leg.
     * @param discountSwap Protocol-authorized reusable discount payload.
     * @param protocolSignature Protocol signature over `discountSwap`.
     * @param recipient Recipient that receives collateral from the adapter.
     * @param amountIn Token-to-redeem amount consumed by the swap.
     * @return amountOut Collateral amount released by the adapter.
     * @dev Assumes `discountSwap.discount.tokenToRedeem` has already been transferred to the adapter before the call.
     */
    function swap(
        DiscountSwap calldata discountSwap,
        bytes calldata protocolSignature,
        address recipient,
        uint256 amountIn
    ) external returns (uint256 amountOut);
}
