// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.28;

import {ILiquidLaneAdapter} from "../src/interfaces/ILiquidLaneAdapter.sol";
import {SymbioticOevSolver} from "../src/oev/SymbioticOevSolver.sol";
import {Id, IMorphoLiquidateCallback, Market, MarketParams, Position} from "../src/oev/interfaces/IMorpho.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";

contract OevSymbioticSolverTest is Test {
    bytes32 internal constant AUTH_DOMAIN = keccak256("SYMBIOTIC_OEV_AUTH_V1");

    uint256 internal constant AUTH_PK = 0xA11CE;
    address internal authSigner = vm.addr(AUTH_PK);
    address internal executor = makeAddr("executor");
    address internal owner = makeAddr("owner");

    Id internal marketId = Id.wrap(bytes32(uint256(1)));
    TestToken internal loan;
    TestToken internal collateral;
    MockAdapter internal adapter;
    MockMorpho internal morpho;
    MockOracle internal oracle;
    SymbioticOevSolver internal solver;

    event LegResult(
        bytes32 indexed auctionKey,
        Id indexed marketId,
        address indexed borrower,
        uint256 code,
        uint256 seizedAssets,
        uint256 repaidAssets,
        uint256 profitLoan
    );
    event PayBidResult(bytes32 indexed auctionKey, uint256 bidAmount, bool paid);

    function setUp() public {
        loan = new TestToken("Loan", "LOAN");
        collateral = new TestToken("Collateral", "COLL");
        oracle = new MockOracle(1e36);
        adapter = new MockAdapter(loan);
        morpho = new MockMorpho(loan, collateral, oracle);
        solver = new SymbioticOevSolver(executor, address(morpho), address(adapter), authSigner, owner);

        morpho.setMarket(
            marketId,
            MarketParams({
                loanToken: address(loan),
                collateralToken: address(collateral),
                oracle: address(oracle),
                irm: address(0),
                lltv: 0.86e18
            }),
            Market({
                totalSupplyAssets: 1000e18,
                totalSupplyShares: 1000e18,
                totalBorrowAssets: 100e18,
                totalBorrowShares: 100e18,
                lastUpdate: uint128(block.timestamp),
                fee: 0
            })
        );
        collateral.mint(address(morpho), 1000e18);
        loan.mint(address(adapter), 1000e18);
        vm.deal(address(solver), 10 ether);
    }

    function testPayBidWithoutAuthorizedLiquidatePaysNothing() public {
        uint256 beforeBalance = executor.balance;

        vm.expectEmit(true, true, true, true, address(solver));
        emit PayBidResult(bytes32(0), 0.1 ether, false);
        vm.prank(executor);
        solver.payBid(0.1 ether);

        assertEq(executor.balance, beforeBalance);
    }

    function testAuthorizedLiquidatePaysBidEvenWhenLegSkips() public {
        address borrower = makeAddr("borrower");
        _position(borrower, 100e18, 100e18);
        bytes32 auctionKey = keccak256("auction-skip");

        SymbioticOevSolver.LiquidationLeg[] memory legs = new SymbioticOevSolver.LiquidationLeg[](1);
        legs[0] = _leg(borrower, 0, 250_000);

        vm.prank(executor);
        solver.liquidate(0.1 ether, authSigner, _opData(auctionKey, 0.1 ether, legs));

        uint256 beforeBalance = executor.balance;
        vm.expectEmit(true, true, true, true, address(solver));
        emit PayBidResult(auctionKey, 0.1 ether, true);
        vm.prank(executor);
        solver.payBid(0.1 ether);

        assertEq(executor.balance - beforeBalance, 0.1 ether);
    }

    function testAuctionKeyCannotReplayAuthorization() public {
        address borrower = makeAddr("borrower");
        _position(borrower, 100e18, 100e18);
        bytes32 auctionKey = keccak256("auction-replay");

        SymbioticOevSolver.LiquidationLeg[] memory legs = new SymbioticOevSolver.LiquidationLeg[](1);
        legs[0] = _leg(borrower, 0, 250_000);
        bytes memory opData = _opData(auctionKey, 0.1 ether, legs);

        vm.prank(executor);
        solver.liquidate(0.1 ether, authSigner, opData);

        vm.expectRevert(SymbioticOevSolver.InvalidAuth.selector);
        vm.prank(executor);
        solver.liquidate(0.1 ether, authSigner, opData);
    }

    function testAdapterLiquidityReducesSeizeBeforeMorphoCall() public {
        address borrower = makeAddr("borrower");
        _position(borrower, 100e18, 100e18);
        adapter.setMaxAssets(40e18);
        bytes32 auctionKey = keccak256("auction-reduce");

        SymbioticOevSolver.LiquidationLeg[] memory legs = new SymbioticOevSolver.LiquidationLeg[](1);
        legs[0] = _leg(borrower, 100e18, 1);

        vm.prank(executor);
        solver.liquidate(0.1 ether, authSigner, _opData(auctionKey, 0.1 ether, legs));

        Position memory p = morpho.position(marketId, borrower);
        assertEq(p.collateral, 60e18);
    }

    function testUnprofitableLegSkipsBeforeMorphoCall() public {
        address borrower = makeAddr("borrower");
        _position(borrower, 100e18, 100e18);
        adapter.setMaxAssets(0);
        bytes32 auctionKey = keccak256("auction-unprofitable");

        SymbioticOevSolver.LiquidationLeg[] memory legs = new SymbioticOevSolver.LiquidationLeg[](1);
        legs[0] = _leg(borrower, 100e18, 250_000);

        vm.expectEmit(true, true, true, true, address(solver));
        emit LegResult(auctionKey, marketId, borrower, _code(0, 2, 4, bytes4(0)), 0, 0, 0);
        vm.prank(executor);
        solver.liquidate(0.1 ether, authSigner, _opData(auctionKey, 0.1 ether, legs));

        Position memory p = morpho.position(marketId, borrower);
        assertEq(p.collateral, 100e18);
    }

    function testRevertedLegDoesNotBlockLaterLeg() public {
        address bad = makeAddr("bad");
        address good = makeAddr("good");
        _position(bad, 100e18, 100e18);
        _position(good, 100e18, 100e18);
        morpho.setRevertBorrower(bad, true);
        bytes32 auctionKey = keccak256("auction-revert");

        SymbioticOevSolver.LiquidationLeg[] memory legs = new SymbioticOevSolver.LiquidationLeg[](2);
        legs[0] = _leg(bad, 100e18, 1);
        legs[1] = _leg(good, 100e18, 1);

        vm.prank(executor);
        solver.liquidate(0.1 ether, authSigner, _opData(auctionKey, 0.1 ether, legs));

        assertEq(morpho.position(marketId, bad).collateral, 100e18);
        assertEq(morpho.position(marketId, good).collateral, 0);
    }

    function _position(address borrower, uint128 borrowShares, uint128 coll) internal {
        morpho.setPosition(
            marketId, borrower, Position({supplyShares: 0, borrowShares: borrowShares, collateral: coll})
        );
    }

    function _leg(address borrower, uint256 maxSeizeAssets, uint32 gasUnits)
        internal
        view
        returns (SymbioticOevSolver.LiquidationLeg memory)
    {
        return SymbioticOevSolver.LiquidationLeg({
            marketId: marketId, borrower: borrower, maxSeizeAssets: maxSeizeAssets, gasUnits: gasUnits
        });
    }

    function _opData(bytes32 auctionKey, uint256 bidAmount, SymbioticOevSolver.LiquidationLeg[] memory legs)
        internal
        view
        returns (bytes memory)
    {
        SymbioticOevSolver.Auth memory auth =
            SymbioticOevSolver.Auth({auctionKey: auctionKey, bidAmount: bidAmount, loanPerEth: 2500e6});
        bytes32 digest = keccak256(
            abi.encode(
                AUTH_DOMAIN,
                block.chainid,
                address(solver),
                executor,
                auth.auctionKey,
                auth.bidAmount,
                auth.loanPerEth,
                keccak256(abi.encode(legs))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(AUTH_PK, digest);
        bytes memory sig = abi.encodePacked(r, s, v);
        return abi.encode(SymbioticOevSolver.OperationData({auth: auth, legs: legs, authSig: sig}));
    }

    function _code(uint256 index, uint8 status, uint8 reason, bytes4 selector) internal pure returns (uint256) {
        return (uint256(uint32(selector)) << 224) | (index << 16) | (uint256(status) << 8) | reason;
    }
}

contract MockMorpho {
    TestToken internal immutable loan;
    TestToken internal immutable collateral;
    MockOracle internal immutable oracle;

    mapping(Id => MarketParams) internal params;
    mapping(Id => Market) internal markets;
    mapping(Id => mapping(address => Position)) internal positions;
    mapping(address => bool) internal revertBorrower;

    constructor(TestToken loan_, TestToken collateral_, MockOracle oracle_) {
        loan = loan_;
        collateral = collateral_;
        oracle = oracle_;
    }

    function setMarket(Id id, MarketParams memory params_, Market memory market_) external {
        params[id] = params_;
        markets[id] = market_;
    }

    function setPosition(Id id, address borrower, Position memory position_) external {
        positions[id][borrower] = position_;
    }

    function setRevertBorrower(address borrower, bool enabled) external {
        revertBorrower[borrower] = enabled;
    }

    function idToMarketParams(Id id) external view returns (MarketParams memory) {
        return params[id];
    }

    function position(Id id, address borrower) external view returns (Position memory) {
        return positions[id][borrower];
    }

    function market(Id id) external view returns (Market memory) {
        return markets[id];
    }

    function liquidate(
        MarketParams memory,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares,
        bytes calldata data
    ) external returns (uint256, uint256) {
        require(repaidShares == 0, "shares");
        if (revertBorrower[borrower]) revert("mock revert");

        Position storage p = positions[Id.wrap(bytes32(uint256(1)))][borrower];
        require(p.collateral >= seizedAssets, "collateral");
        p.collateral -= uint128(seizedAssets);
        if (p.borrowShares > seizedAssets / 2) {
            p.borrowShares -= uint128(seizedAssets / 2);
        } else {
            p.borrowShares = 0;
        }

        collateral.transfer(msg.sender, seizedAssets);
        uint256 repaidAssets = seizedAssets / 2;
        IMorphoLiquidateCallback(msg.sender).onMorphoLiquidate(repaidAssets, data);
        loan.transferFrom(msg.sender, address(this), repaidAssets);
        return (seizedAssets, repaidAssets);
    }
}

contract MockAdapter {
    TestToken internal immutable loan;
    uint256 internal maxAssets = type(uint256).max;
    uint256 internal discount;
    uint256 internal rate = 1e18;

    constructor(TestToken loan_) {
        loan = loan_;
    }

    function setMaxAssets(uint256 maxAssets_) external {
        maxAssets = maxAssets_;
    }

    function setRate(uint256 rate_) external {
        rate = rate_;
    }

    function setDiscount(uint256 discount_) external {
        discount = discount_;
    }

    function minDiscount(address) external view returns (uint256) {
        return discount;
    }

    function getMaxAssets(address) external view returns (uint256) {
        return maxAssets;
    }

    function getAmountOut(address, uint256 amountIn) external view returns (uint256) {
        return amountIn * rate / 1e18;
    }

    function swap(ILiquidLaneAdapter.Swap calldata swap_) external {
        require(swap_.amountOut <= maxAssets, "max");
        loan.transfer(swap_.recipient, swap_.amountOut);
    }

    function swap(ILiquidLaneAdapter.SignedSwap calldata, bytes calldata) external {}

    function swap(ILiquidLaneAdapter.DiscountSwap calldata, bytes calldata, address, uint256)
        external
        pure
        returns (uint256)
    {
        return 0;
    }
}

contract MockOracle {
    uint256 internal value;

    constructor(uint256 value_) {
        value = value_;
    }

    function setPrice(uint256 value_) external {
        value = value_;
    }

    function price() external view returns (uint256) {
        return value;
    }
}

contract TestToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
