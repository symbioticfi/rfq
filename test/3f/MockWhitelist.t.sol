// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MockWhitelist} from "../../src/3f/MockWhitelist.sol";

import {IWhitelist} from "3f-request-whitelist/src/IWhitelist.sol";

import {Test} from "forge-std/Test.sol";

contract MockWhitelistTest is Test {
    MockWhitelist internal whitelist;

    function setUp() public {
        whitelist = new MockWhitelist();
    }

    function test_AttestsKnownAddresses() public view {
        assertTrue(whitelist.isWhitelisted(address(0)) == IWhitelist.WhitelistStatus.Whitelisted);
        assertTrue(whitelist.isWhitelisted(address(this)) == IWhitelist.WhitelistStatus.Whitelisted);
        assertTrue(whitelist.isWhitelisted(address(0xBEEF)) == IWhitelist.WhitelistStatus.Whitelisted);
    }

    function testFuzz_AttestsAnyAddress(address a) public view {
        assertTrue(whitelist.isWhitelisted(a) == IWhitelist.WhitelistStatus.Whitelisted);
    }
}
