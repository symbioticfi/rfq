// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IPermit2
 * @notice Minimal Permit2 interface used by the Reactor.
 */
interface IPermit2 {
    /* STRUCTS */

    /**
     * @notice Token and amount details for a signature-based transfer.
     * @param token ERC20 token address.
     * @param amount Maximum amount that can be spent.
     */
    struct TokenPermissions {
        address token;
        uint256 amount;
    }

    /**
     * @notice Signed permit for a single token transfer.
     * @param permitted Token and amount authorized for transfer.
     * @param nonce Unique signature nonce.
     * @param deadline Permit deadline.
     */
    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }

    /**
     * @notice Requested recipient and amount for a signature-based transfer.
     * @param to Recipient address.
     * @param requestedAmount Requested transfer amount.
     */
    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }

    /* FUNCTIONS */

    /**
     * @notice Transfers a token using a signed permit message and witness data.
     * @param permit Permit data signed by the owner.
     * @param transferDetails Requested transfer details.
     * @param owner Owner of the tokens to transfer.
     * @param witness Additional signed witness data.
     * @param witnessTypeString EIP-712 witness type string.
     * @param signature Signature to verify.
     */
    function permitWitnessTransferFrom(
        PermitTransferFrom memory permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata signature
    ) external;
}
