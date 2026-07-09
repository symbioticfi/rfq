// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library RfqDeployConfig {
    uint256 internal constant MAINNET_CHAIN_ID = 1;
    uint256 internal constant HOODI_CHAIN_ID = 560_048;
    uint256 internal constant SEPOLIA_CHAIN_ID = 11_155_111;

    error UnsupportedChain(uint256 chainId);

    function currentLiquidLaneAdapterFactory() internal view returns (address factory) {
        factory = liquidLaneAdapterFactory(block.chainid);
    }

    function liquidLaneAdapterFactory(uint256 chainId) internal pure returns (address factory) {
        if (chainId == MAINNET_CHAIN_ID) {
            factory = 0x9b5dbB434269e39e41b1E331C2AcE09e05A899B5;
        } else if (chainId == HOODI_CHAIN_ID) {
            factory = 0x7Ce3f158f22aC66F8Ed2973B7a10F666818301C5;
        } else if (chainId == SEPOLIA_CHAIN_ID) {
            factory = 0xE929Cf04D2A587817773E6B5cB9Bc8D01f909Faa;
        } else {
            revert UnsupportedChain(chainId);
        }
    }
}
