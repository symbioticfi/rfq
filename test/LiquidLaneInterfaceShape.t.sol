// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.28;

import {
    DISCOUNT_PRECISION,
    DISCOUNT_SWAP_TYPEHASH,
    DISCOUNT_TYPEHASH,
    ILiquidLaneAdapter,
    SIGNED_SWAP_TYPEHASH
} from "../src/interfaces/ILiquidLaneAdapter.sol";

import {Test} from "forge-std/Test.sol";

contract LiquidLaneInterfaceShapeTest is Test {
    function testTypehashesMatchLiquidLaneAdapter() public pure {
        assertEq(DISCOUNT_PRECISION, 1_000_000);
        assertEq(
            SIGNED_SWAP_TYPEHASH,
            keccak256(
                "SignedSwap(address recipient,address tokenIn,uint256 amountIn,uint256 amountOut,address caller,address signer,uint256 nonce,uint48 deadline)"
            )
        );
        assertEq(
            DISCOUNT_TYPEHASH,
            keccak256(
                "Discount(address tokenToRedeem,uint256 discount,address signer,address protocol,uint256 nonce,uint48 deadline)"
            )
        );
        assertEq(
            DISCOUNT_SWAP_TYPEHASH,
            keccak256(
                "DiscountSwap(Discount discount,bytes signerSignature,uint48 protocolDeadline)"
                "Discount(address tokenToRedeem,uint256 discount,address signer,address protocol,uint256 nonce,uint48 deadline)"
            )
        );
    }

    function testStructsUseSingleAdapterLiquidLaneShape() public pure {
        ILiquidLaneAdapter.Swap memory swap =
            ILiquidLaneAdapter.Swap({recipient: address(0x1), tokenIn: address(0x2), amountIn: 3, amountOut: 4});
        ILiquidLaneAdapter.SignedSwap memory signedSwap = ILiquidLaneAdapter.SignedSwap({
            recipient: address(0x1),
            tokenIn: address(0x2),
            amountIn: 3,
            amountOut: 4,
            caller: address(0x5),
            signer: address(0x6),
            nonce: 7,
            deadline: 8
        });
        ILiquidLaneAdapter.Discount memory discount = ILiquidLaneAdapter.Discount({
            tokenToRedeem: address(0x2),
            discount: 50_000,
            signer: address(0x6),
            protocol: address(0x7),
            nonce: 9,
            deadline: 10
        });

        assertEq(swap.tokenIn, address(0x2));
        assertEq(signedSwap.deadline, 8);
        assertEq(discount.tokenToRedeem, address(0x2));
    }
}
