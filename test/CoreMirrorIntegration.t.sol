// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.28;

import {Executor} from "../src/Executor.sol";
import {Reactor} from "../src/Reactor.sol";
import {IExecutor} from "../src/interfaces/IExecutor.sol";
import {
    IInstantRedemptionAdapter as LocalInstantRedemptionAdapter
} from "../src/interfaces/IInstantRedemptionAdapter.sol";
import {IReactor, ORDER_TYPEHASH, OUTPUT_TYPEHASH, REQUEST_TYPEHASH} from "../src/interfaces/IReactor.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {
    DISCOUNT_PRECISION as CORE_DISCOUNT_PRECISION,
    DISCOUNT_SWAP_TYPEHASH as CORE_DISCOUNT_SWAP_TYPEHASH,
    DISCOUNT_TYPEHASH as CORE_DISCOUNT_TYPEHASH,
    IInstantRedemptionAdapter as CoreInstantRedemptionAdapter,
    SIGNED_SWAP_TYPEHASH as CORE_SIGNED_SWAP_TYPEHASH
} from "@symbioticfi/core/src/interfaces/vault/adapters/IInstantRedemptionAdapter.sol";

import {Test} from "forge-std/Test.sol";

contract CoreMirrorIntegrationTest is Test {
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    uint256 internal constant PROTOCOL_PRIVATE_KEY = 0xA11CE;
    uint256 internal constant SWAPPER_PRIVATE_KEY = 0xBEEF;

    address internal filler = makeAddr("filler");
    address internal protocol = vm.addr(PROTOCOL_PRIVATE_KEY);
    address internal swapper = vm.addr(SWAPPER_PRIVATE_KEY);
    address internal vault0 = makeAddr("vault0");
    address internal vault1 = makeAddr("vault1");
    address internal vault0Account = makeAddr("vault0Account");
    address internal vault1Account = makeAddr("vault1Account");

    CoreMirrorAdapterMock internal adapter;
    IntegrationAdapterFactory internal adapterFactory;
    IntegrationERC20 internal outputToken;
    IntegrationERC20 internal rwa;
    Executor internal executor;
    Reactor internal reactor;

    function setUp() public {
        adapter = new CoreMirrorAdapterMock();
        adapterFactory = new IntegrationAdapterFactory();
        adapterFactory.setEntity(address(adapter), true);
        reactor = new Reactor(address(adapterFactory));
        executor = new Executor(address(reactor), address(this), _callers(filler));

        rwa = new IntegrationERC20("RWA", "RWA");
        outputToken = new IntegrationERC20("USD", "USD");

        adapter.setAccount(vault0, address(rwa), vault0Account);
        adapter.setAccount(vault1, address(rwa), vault1Account);

        rwa.mint(swapper, 100 ether);
        vm.prank(swapper);
        rwa.approve(address(reactor), type(uint256).max);
    }

    function testCoreMirrorConstantsMatchExpectedAdapterSchema() public pure {
        assertEq(CORE_DISCOUNT_PRECISION, 1_000_000);
        assertEq(
            CORE_SIGNED_SWAP_TYPEHASH,
            keccak256(
                "SignedSwap(address recipient,address vault,address tokenIn,uint256 amountIn,uint256 amountOut,address caller,address signer,uint256 nonce,uint256 deadline)"
            )
        );
        assertEq(
            CORE_DISCOUNT_TYPEHASH,
            keccak256(
                "Discount(address vault,address tokenToRedeem,uint256 discount,address signer,address protocol,uint256 nonce,uint48 deadline)"
            )
        );
        assertEq(
            CORE_DISCOUNT_SWAP_TYPEHASH,
            keccak256(
                "DiscountSwap(Discount discount,bytes signerSignature,uint48 protocolDeadline)"
                "Discount(address vault,address tokenToRedeem,uint256 discount,address signer,address protocol,uint256 nonce,uint48 deadline)"
            )
        );
    }

    function testLocalAndCoreMirrorStructEncodingsMatch() public view {
        LocalInstantRedemptionAdapter.Swap memory localSwap = _localSwap(vault0, 11 ether, 10 ether);
        CoreInstantRedemptionAdapter.Swap memory coreSwap = CoreInstantRedemptionAdapter.Swap({
            recipient: localSwap.recipient,
            vault: localSwap.vault,
            tokenIn: localSwap.tokenIn,
            amountIn: localSwap.amountIn,
            amountOut: localSwap.amountOut
        });

        LocalInstantRedemptionAdapter.SignedSwap memory localSignedSwap = LocalInstantRedemptionAdapter.SignedSwap({
            recipient: filler,
            vault: vault0,
            tokenIn: address(rwa),
            amountIn: 11 ether,
            amountOut: 10 ether,
            caller: address(executor),
            signer: protocol,
            nonce: 77,
            deadline: block.timestamp + 1 days
        });
        CoreInstantRedemptionAdapter.SignedSwap memory coreSignedSwap = CoreInstantRedemptionAdapter.SignedSwap({
            recipient: localSignedSwap.recipient,
            vault: localSignedSwap.vault,
            tokenIn: localSignedSwap.tokenIn,
            amountIn: localSignedSwap.amountIn,
            amountOut: localSignedSwap.amountOut,
            caller: localSignedSwap.caller,
            signer: localSignedSwap.signer,
            nonce: localSignedSwap.nonce,
            deadline: localSignedSwap.deadline
        });

        LocalInstantRedemptionAdapter.Discount memory localDiscount = _localDiscount(vault1);
        CoreInstantRedemptionAdapter.Discount memory coreDiscount = CoreInstantRedemptionAdapter.Discount({
            vault: localDiscount.vault,
            tokenToRedeem: localDiscount.tokenToRedeem,
            discount: localDiscount.discount,
            signer: localDiscount.signer,
            protocol: localDiscount.protocol,
            nonce: localDiscount.nonce,
            deadline: localDiscount.deadline
        });

        LocalInstantRedemptionAdapter.DiscountSwap memory localDiscountSwap = LocalInstantRedemptionAdapter.DiscountSwap({
            discount: localDiscount, signerSignature: hex"1234", protocolDeadline: uint48(block.timestamp + 90)
        });
        CoreInstantRedemptionAdapter.DiscountSwap memory coreDiscountSwap = CoreInstantRedemptionAdapter.DiscountSwap({
            discount: coreDiscount,
            signerSignature: localDiscountSwap.signerSignature,
            protocolDeadline: localDiscountSwap.protocolDeadline
        });

        assertEq(keccak256(abi.encode(localSwap)), keccak256(abi.encode(coreSwap)));
        assertEq(keccak256(abi.encode(localSignedSwap)), keccak256(abi.encode(coreSignedSwap)));
        assertEq(keccak256(abi.encode(localDiscount)), keccak256(abi.encode(coreDiscount)));
        assertEq(keccak256(abi.encode(localDiscountSwap)), keccak256(abi.encode(coreDiscountSwap)));
    }

    function testCoreMirrorAdapterHandlesDirectSwapFill() public {
        outputToken.mint(address(executor), 5 ether);

        IReactor.Output[] memory outputs = new IReactor.Output[](1);
        outputs[0] = IReactor.Output({token: address(outputToken), amount: 5 ether, recipient: swapper});

        IExecutor.Call[] memory calls = new IExecutor.Call[](0);
        IReactor.SwapInput memory swap = _swapInput(vault0, 5 ether, 5 ether);
        IReactor.Order memory order = _order(outputs, 5 ether);

        vm.prank(filler);
        executor.fill(order, _signOrder(order), swap, abi.encode(calls));

        assertEq(rwa.balanceOf(vault0Account), 5 ether);
        assertEq(outputToken.balanceOf(swapper), 5 ether);
        assertEq(adapter.swapCount(), 1);
        assertEq(adapter.discountSwapCount(), 0);
        assertEq(adapter.lastRecipient(), filler);
        assertEq(adapter.lastAmountOut(), 5 ether);
    }

    function testCoreMirrorAdapterHandlesMixedDirectAndDiscountSwapFill() public {
        outputToken.mint(address(executor), 10 ether);

        IReactor.Output[] memory outputs = new IReactor.Output[](1);
        outputs[0] = IReactor.Output({token: address(outputToken), amount: 10 ether, recipient: swapper});

        IExecutor.Call[] memory calls = new IExecutor.Call[](0);
        IReactor.SwapInput[] memory swapInputs = new IReactor.SwapInput[](1);
        swapInputs[0] = _swapInput(vault0, 4 ether, 4 ether);

        IReactor.DiscountSwapInput[] memory discountSwapInputs = new IReactor.DiscountSwapInput[](1);
        discountSwapInputs[0] = _discountSwapInput(vault1, 6 ether, 6 ether);

        IReactor.Order memory order = _order(outputs, 10 ether);

        vm.prank(filler);
        executor.fill(order, _signOrder(order), swapInputs, discountSwapInputs, abi.encode(calls));

        assertEq(rwa.balanceOf(vault0Account), 4 ether);
        assertEq(rwa.balanceOf(vault1Account), 6 ether);
        assertEq(outputToken.balanceOf(swapper), 10 ether);
        assertEq(adapter.swapCount(), 1);
        assertEq(adapter.discountSwapCount(), 1);
        assertEq(adapter.lastRecipient(), filler);
        assertEq(adapter.lastAmountOut(), 6 ether);
    }

    function testCoreMirrorAdapterHandlesLocalSignedSwapSelector() public {
        rwa.mint(address(adapter), 3 ether);

        LocalInstantRedemptionAdapter.SignedSwap memory signedSwap = LocalInstantRedemptionAdapter.SignedSwap({
            recipient: filler,
            vault: vault0,
            tokenIn: address(rwa),
            amountIn: 3 ether,
            amountOut: 3 ether,
            caller: address(executor),
            signer: protocol,
            nonce: 101,
            deadline: block.timestamp + 1 days
        });

        LocalInstantRedemptionAdapter(address(adapter)).swap(signedSwap, hex"c0de");

        assertEq(rwa.balanceOf(vault0Account), 3 ether);
        assertEq(adapter.signedSwapCount(), 1);
        assertEq(adapter.lastRecipient(), filler);
        assertEq(adapter.lastAmountOut(), 3 ether);
    }

    function _callers(address caller) internal pure returns (address[] memory callers_) {
        callers_ = new address[](1);
        callers_[0] = caller;
    }

    function _order(IReactor.Output[] memory outputs, uint256 amountIn) internal view returns (IReactor.Order memory) {
        IReactor.Request memory request = IReactor.Request({
            tokenIn: address(rwa),
            amountIn: amountIn,
            outputs: outputs,
            deadline: block.timestamp + 1 days,
            nonce: 1,
            protocol: protocol
        });
        return IReactor.Order({
            request: request, swapperSignature: _signRequest(request), swapper: swapper, filler: address(executor)
        });
    }

    function _signOrder(IReactor.Order memory order) internal view returns (bytes memory) {
        bytes32 digest = keccak256(
            abi.encodePacked(
                hex"1901",
                keccak256(
                    abi.encode(
                        DOMAIN_TYPEHASH,
                        keccak256(bytes("Reactor")),
                        keccak256(bytes("1")),
                        block.chainid,
                        address(reactor)
                    )
                ),
                _hashOrder(order)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PROTOCOL_PRIVATE_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signRequest(IReactor.Request memory request) internal view returns (bytes memory) {
        bytes32 digest = keccak256(
            abi.encodePacked(
                hex"1901",
                keccak256(
                    abi.encode(
                        DOMAIN_TYPEHASH,
                        keccak256(bytes("Reactor")),
                        keccak256(bytes("1")),
                        block.chainid,
                        address(reactor)
                    )
                ),
                _hashRequest(request)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SWAPPER_PRIVATE_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function _hashOrder(IReactor.Order memory order) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                _hashRequest(order.request),
                keccak256(order.swapperSignature),
                order.swapper,
                order.filler
            )
        );
    }

    function _hashRequest(IReactor.Request memory request) internal pure returns (bytes32) {
        bytes32[] memory outputHashes = new bytes32[](request.outputs.length);
        for (uint256 i; i < request.outputs.length; ++i) {
            outputHashes[i] = keccak256(abi.encode(OUTPUT_TYPEHASH, request.outputs[i]));
        }

        return keccak256(
            abi.encode(
                REQUEST_TYPEHASH,
                request.tokenIn,
                request.amountIn,
                keccak256(abi.encodePacked(outputHashes)),
                request.deadline,
                request.nonce,
                request.protocol
            )
        );
    }

    function _localSwap(address vault, uint256 amountIn, uint256 amountOut)
        internal
        view
        returns (LocalInstantRedemptionAdapter.Swap memory)
    {
        return LocalInstantRedemptionAdapter.Swap({
            recipient: filler, vault: vault, tokenIn: address(rwa), amountIn: amountIn, amountOut: amountOut
        });
    }

    function _swapInput(address vault, uint256 amountIn, uint256 amountOut)
        internal
        view
        returns (IReactor.SwapInput memory)
    {
        return IReactor.SwapInput({adapter: address(adapter), swap: _localSwap(vault, amountIn, amountOut)});
    }

    function _localDiscount(address vault) internal view returns (LocalInstantRedemptionAdapter.Discount memory) {
        return LocalInstantRedemptionAdapter.Discount({
            vault: vault,
            tokenToRedeem: address(rwa),
            discount: 50_000,
            signer: protocol,
            protocol: protocol,
            nonce: 2,
            deadline: uint48(block.timestamp + 1 days)
        });
    }

    function _discountSwapInput(address vault, uint256 amountIn, uint256 amountOut)
        internal
        view
        returns (IReactor.DiscountSwapInput memory)
    {
        return IReactor.DiscountSwapInput({
            adapter: address(adapter),
            discountSwap: LocalInstantRedemptionAdapter.DiscountSwap({
                discount: _localDiscount(vault),
                signerSignature: hex"1234",
                protocolDeadline: uint48(block.timestamp + 90)
            }),
            protocolSignature: hex"5678",
            recipient: filler,
            amountIn: amountIn,
            amountOut: amountOut
        });
    }
}

contract IntegrationAdapterFactory {
    mapping(address adapter => bool status) public isEntity;

    function setEntity(address adapter, bool status) public {
        isEntity[adapter] = status;
    }
}

contract CoreMirrorAdapterMock {
    mapping(address vault => mapping(address token => address account)) internal _accounts;
    uint256 public swapCount;
    uint256 public signedSwapCount;
    uint256 public discountSwapCount;
    address public lastRecipient;
    uint256 public lastAmountOut;

    function setAccount(address vault, address token, address account) public {
        _accounts[vault][token] = account;
    }

    function getAccount(address vault, address token) public view returns (address) {
        return _accounts[vault][token];
    }

    function swap(CoreInstantRedemptionAdapter.Swap calldata swap_) public {
        _transferToAccount(swap_.vault, swap_.tokenIn, swap_.amountIn);
        lastRecipient = swap_.recipient;
        lastAmountOut = swap_.amountOut;
        ++swapCount;
    }

    function swap(CoreInstantRedemptionAdapter.SignedSwap calldata signedSwap, bytes calldata) public {
        _transferToAccount(signedSwap.vault, signedSwap.tokenIn, signedSwap.amountIn);
        lastRecipient = signedSwap.recipient;
        lastAmountOut = signedSwap.amountOut;
        ++signedSwapCount;
    }

    function swap(
        CoreInstantRedemptionAdapter.DiscountSwap calldata discountSwap,
        bytes calldata,
        address recipient,
        uint256 amountIn,
        uint256 amountOut
    ) public {
        _transferToAccount(discountSwap.discount.vault, discountSwap.discount.tokenToRedeem, amountIn);
        lastRecipient = recipient;
        lastAmountOut = amountOut;
        ++discountSwapCount;
    }

    function _transferToAccount(address vault, address token, uint256 amount) internal {
        address account = _accounts[vault][token];
        require(account != address(0), "missing account");
        require(IERC20(token).balanceOf(address(this)) >= amount, "missing rwa");
        IERC20(token).transfer(account, amount);
    }
}

contract IntegrationERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}
