// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.28;

import {Account} from "@symbioticfi/core/src/contracts/vault/adapters/ir_adapter/Account.sol";
import {IAccount} from "@symbioticfi/core/src/interfaces/vault/adapters/ir_adapter/IAccount.sol";
import {AggregatorV3Interface} from "@symbioticfi/core/src/interfaces/vault/adapters/ir_adapter/oracles/AggregatorV3Interface.sol";
import {IVaultV2} from "@symbioticfi/core/src/interfaces/vault/IVaultV2.sol";
import {AaveV3ReserveData} from "@symbioticfi/core/src/interfaces/vault/adapters/aave_v3_adapter/IAaveV3AdapterDependencies.sol";
import {NATIVE} from "@symbioticfi/reactor/interfaces/IReactor.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SafeTransferLib as SafeERC20} from "@solady/src/utils/SafeTransferLib.sol";

interface IMintableERC20 {
    /// @notice Mints tokens to a recipient.
    /// @param to The recipient.
    /// @param amount The minted amount.
    function mint(address to, uint256 amount) external;
}

interface ILocalAdapterBound {
    /// @notice Returns the adapter authorized to operate the local account.
    /// @return adapter_ The bound adapter address.
    function adapter() external view returns (address adapter_);
}

/// @notice Minimal owner-gated helper base for local/staging-only contracts.
abstract contract LocalOwned {
    error NotOwner();

    address public immutable owner;

    /// @notice Stores the owner.
    /// @param owner_ The authorized owner.
    constructor(address owner_) {
        owner = owner_;
    }

    /// @notice Restricts mutating helpers to the configured owner.
    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert NotOwner();
        }
        _;
    }
}

/// @notice Local mintable ERC20 used for synthetic RFQ assets in local and Hoodi environments.
contract LocalMintableERC20 is ERC20, LocalOwned {
    uint8 internal immutable _decimals;
    mapping(address caller => bool enabled) public authorizedCallers;
    mapping(address adapter => bool enabled) public authorizedAdapters;

    /// @notice Creates the token.
    /// @param name_ The token name.
    /// @param symbol_ The token symbol.
    /// @param decimals_ The token decimals.
    constructor(string memory name_, string memory symbol_, uint8 decimals_, address owner_)
        ERC20(name_, symbol_)
        LocalOwned(owner_)
    {
        _decimals = decimals_;
    }

    /// @notice Returns the token decimals.
    /// @return decimalsValue The token decimals.
    function decimals() public view override returns (uint8 decimalsValue) {
        decimalsValue = _decimals;
    }

    /// @notice Grants or revokes direct mint permissions for a caller such as the local router.
    /// @param caller The authorized caller.
    /// @param enabled Whether the caller is authorized.
    function setAuthorizedCaller(address caller, bool enabled) external onlyOwner {
        authorizedCallers[caller] = enabled;
    }

    /// @notice Grants or revokes mint permissions for local adapter-bound account instances.
    /// @param adapter The adapter allowed to control mint-capable accounts.
    /// @param enabled Whether the adapter is authorized.
    function setAuthorizedAdapter(address adapter, bool enabled) external onlyOwner {
        authorizedAdapters[adapter] = enabled;
    }

    /// @notice Mints new tokens.
    /// @param to The recipient.
    /// @param amount The minted amount.
    function mint(address to, uint256 amount) external {
        if (!_isAuthorizedMinter(msg.sender)) {
            revert NotOwner();
        }
        _mint(to, amount);
    }

    function _isAuthorizedMinter(address caller) internal view returns (bool) {
        if (caller == owner || authorizedCallers[caller]) {
            return true;
        }

        (bool success, bytes memory data) = caller.staticcall(abi.encodeCall(ILocalAdapterBound.adapter, ()));
        if (!success || data.length != 32) {
            return false;
        }

        return authorizedAdapters[abi.decode(data, (address))];
    }
}

/// @notice Minimal local Chainlink-compatible feed used behind the real Chainlink oracle contract.
contract LocalAggregatorV3 is AggregatorV3Interface, LocalOwned {
    uint8 internal immutable feedDecimals;
    string internal feedDescription;
    uint80 internal roundId;
    int256 internal answer;
    uint256 internal updatedAt;
    uint80 internal answeredInRound;

    /// @notice Creates the local aggregator with one initialized round.
    /// @param decimals_ Feed answer decimals.
    /// @param description_ Human-readable feed description.
    /// @param initialAnswer Initial feed answer.
    constructor(uint8 decimals_, string memory description_, int256 initialAnswer, address owner_) LocalOwned(owner_) {
        feedDecimals = decimals_;
        feedDescription = description_;
        roundId = 1;
        answer = initialAnswer;
        updatedAt = block.timestamp;
        answeredInRound = roundId;
    }

    /// @inheritdoc AggregatorV3Interface
    function decimals() external view returns (uint8) {
        return feedDecimals;
    }

    /// @inheritdoc AggregatorV3Interface
    function description() external view returns (string memory) {
        return feedDescription;
    }

    /// @inheritdoc AggregatorV3Interface
    function version() external pure returns (uint256) {
        return 1;
    }

    /// @inheritdoc AggregatorV3Interface
    function getRoundData(uint80 queriedRoundId) external view returns (uint80, int256, uint256, uint256, uint80) {
        require(queriedRoundId == roundId, "round");
        return (roundId, answer, updatedAt, updatedAt, answeredInRound);
    }

    /// @inheritdoc AggregatorV3Interface
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, answeredInRound);
    }

    /// @notice Updates the latest round answer.
    /// @param newAnswer New feed answer.
    function setAnswer(int256 newAnswer) external onlyOwner {
        roundId += 1;
        answer = newAnswer;
        updatedAt = block.timestamp;
        answeredInRound = roundId;
    }
}

/// @notice Immediate-settlement account used only for local synthetic RWA flows.
contract ImmediateSettlementAccount is Account {
    using SafeERC20 for address;

    uint256 public principalOutstanding;

    /// @notice Creates the account implementation.
    /// @param adapter The bound adapter.
    /// @param tokenToRedeem The managed token-to-redeem.
    constructor(address adapter, address tokenToRedeem) Account(adapter, tokenToRedeem) {}

    /// @notice Exposes the bound adapter for local-token mint authorization.
    /// @return adapter_ The bound adapter.
    function adapter() external view returns (address adapter_) {
        adapter_ = ADAPTER;
    }

    /// @inheritdoc IAccount
    function redeem(uint256 amountToRedeem, uint256 amountSpent) external onlyAdapter {
        amountToRedeem;

        address collateral = IVaultV2(VAULT).collateral();
        principalOutstanding += amountSpent;
        IMintableERC20(collateral).mint(address(this), amountSpent);

        if (IERC20(collateral).allowance(address(this), ADAPTER) < type(uint256).max / 2) {
            collateral.safeApproveWithRetry(ADAPTER, type(uint256).max);
        }
    }

    /// @inheritdoc IAccount
    function deallocatable() external view returns (uint256 amount) {
        amount = principalOutstanding;
    }

    /// @inheritdoc IAccount
    function skimmable() external view returns (uint256 amount) {
        uint256 collateralBalance = IERC20(IVaultV2(VAULT).collateral()).balanceOf(address(this));
        amount = collateralBalance > principalOutstanding ? collateralBalance - principalOutstanding : 0;
    }

    /// @inheritdoc IAccount
    function deallocate() external returns (uint256 deallocated, uint256 skimmed) {
        address collateral = IVaultV2(VAULT).collateral();
        uint256 collateralBalance = IERC20(collateral).balanceOf(address(this));

        deallocated = principalOutstanding > collateralBalance ? collateralBalance : principalOutstanding;
        skimmed = collateralBalance - deallocated;
        principalOutstanding -= deallocated;

        if (IERC20(collateral).allowance(address(this), ADAPTER) < deallocated + skimmed) {
            collateral.safeApproveWithRetry(ADAPTER, type(uint256).max);
        }
    }
}

/// @notice Deterministic onchain second-leg router used by the filler mock provider.
contract LocalSwapRouter is LocalOwned {
    using SafeERC20 for address;

    uint256 internal constant RATE_SCALE = 1e18;

    mapping(address tokenIn => mapping(address tokenOut => uint256 rate)) public rates;

    /// @notice Stores the owner that controls synthetic pricing.
    /// @param owner_ The authorized owner.
    constructor(address owner_) LocalOwned(owner_) {}

    /// @notice Sets the deterministic rate for a token pair.
    /// @param tokenIn The input token.
    /// @param tokenOut The output token, or `NATIVE` for ETH.
    /// @param rate The pair rate scaled by `1e18`.
    function setRate(address tokenIn, address tokenOut, uint256 rate) external onlyOwner {
        rates[tokenIn][tokenOut] = rate;
    }

    /// @notice Returns the deterministic output amount for a token pair.
    /// @param tokenIn The input token.
    /// @param tokenOut The output token, or `NATIVE` for ETH.
    /// @param amountIn The input amount.
    /// @return amountOut The deterministic output amount.
    function getAmountOut(address tokenIn, address tokenOut, uint256 amountIn) public view returns (uint256 amountOut) {
        uint256 rate = rates[tokenIn][tokenOut];
        require(rate != 0, "rate");

        amountOut = amountIn * rate / RATE_SCALE;
    }

    /// @notice Swaps ERC20 `tokenIn` into ERC20 `tokenOut`.
    /// @param tokenIn The input token.
    /// @param tokenOut The output token.
    /// @param amountIn The input amount.
    /// @param minAmountOut The minimum acceptable output.
    /// @param recipient The output recipient.
    /// @return amountOut The deterministic output amount.
    function swapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external returns (uint256 amountOut) {
        tokenIn.safeTransferFrom(msg.sender, address(this), amountIn);
        amountOut = getAmountOut(tokenIn, tokenOut, amountIn);
        require(amountOut >= minAmountOut, "slippage");

        IMintableERC20(tokenOut).mint(recipient, amountOut);
    }

    /// @notice Swaps ERC20 `tokenIn` into native ETH.
    /// @param tokenIn The input token.
    /// @param amountIn The input amount.
    /// @param minAmountOut The minimum acceptable output.
    /// @param recipient The ETH recipient.
    /// @return amountOut The deterministic output amount.
    function swapExactInputToNative(address tokenIn, uint256 amountIn, uint256 minAmountOut, address recipient)
        external
        returns (uint256 amountOut)
    {
        tokenIn.safeTransferFrom(msg.sender, address(this), amountIn);
        amountOut = getAmountOut(tokenIn, NATIVE, amountIn);
        require(amountOut >= minAmountOut, "slippage");
        SafeERC20.safeTransferETH(recipient, amountOut);
    }

    /// @dev Accepts ETH funding for native output swaps.
    receive() external payable {}
}

/// @notice Minimal Morpho Vault V2 factory used only for local and staging adapter validation.
contract MockMorphoVaultFactory is LocalOwned {
    mapping(address vault => bool status) public isVaultV2;

    /// @notice Stores the owner.
    /// @param owner_ The authorized owner.
    constructor(address owner_) LocalOwned(owner_) {}

    /// @notice Stores whether a vault address should be treated as a Morpho Vault V2.
    /// @param vault The vault to update.
    /// @param status Whether the vault should be treated as valid.
    function setVault(address vault, bool status) external onlyOwner {
        isVaultV2[vault] = status;
    }
}

/// @notice Minimal Morpho Vault V2-compatible ERC4626 mock used by the Morpho adapter.
contract MockMorphoVaultV2 is LocalOwned {
    IERC20 public immutable asset;
    address public immutable adapterRegistry;
    address public liquidityAdapter;

    uint256 public totalShares;
    mapping(address account => uint256 shares) internal sharesOf;

    /// @notice Stores the collateral asset and expected adapter registry.
    /// @param asset_ The vault asset.
    /// @param adapterRegistry_ The adapter registry the adapter validates against.
    /// @param owner_ The authorized owner.
    constructor(address asset_, address adapterRegistry_, address owner_) LocalOwned(owner_) {
        asset = IERC20(asset_);
        adapterRegistry = adapterRegistry_;
    }

    /// @notice Sets a mocked Morpho liquidity adapter.
    /// @param newLiquidityAdapter The mocked liquidity adapter.
    function setLiquidityAdapter(address newLiquidityAdapter) external onlyOwner {
        liquidityAdapter = newLiquidityAdapter;
    }

    /// @notice Deposits collateral and mints proportional shares.
    /// @param assets The collateral amount.
    /// @param receiver The share receiver.
    /// @return shares The minted shares.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        uint256 totalAssetsBefore = asset.balanceOf(address(this));
        asset.transferFrom(msg.sender, address(this), assets);

        if (totalShares == 0 || totalAssetsBefore == 0) {
            shares = assets;
        } else {
            shares = assets * totalShares / totalAssetsBefore;
        }

        sharesOf[receiver] += shares;
        totalShares += shares;
    }

    /// @notice Withdraws collateral by burning proportional shares.
    /// @param assets The collateral amount to withdraw.
    /// @param receiver The withdrawal recipient.
    /// @param owner_ The share owner.
    /// @return shares The burned shares.
    function withdraw(uint256 assets, address receiver, address owner_) external returns (uint256 shares) {
        uint256 totalAssets = asset.balanceOf(address(this));
        if (totalAssets == 0 || totalShares == 0) {
            return 0;
        }

        shares = assets * totalShares / totalAssets;
        if (shares > sharesOf[owner_]) {
            shares = sharesOf[owner_];
            assets = shares * totalAssets / totalShares;
        }

        sharesOf[owner_] -= shares;
        totalShares -= shares;
        asset.transfer(receiver, assets);
    }

    /// @notice Returns the share balance of an account.
    /// @param account The account to query.
    /// @return shares The share balance.
    function balanceOf(address account) external view returns (uint256 shares) {
        shares = sharesOf[account];
    }

    /// @notice Returns the collateral value represented by a share amount.
    /// @param shares The share amount to redeem.
    /// @return assets The equivalent collateral amount.
    function previewRedeem(uint256 shares) external view returns (uint256 assets) {
        if (totalShares == 0) {
            return 0;
        }

        assets = shares * asset.balanceOf(address(this)) / totalShares;
    }

    /// @notice Funds the vault with synthetic yield.
    /// @param amount The additional collateral amount.
    function donateYield(uint256 amount) external {
        asset.transferFrom(msg.sender, address(this), amount);
    }

    /// @notice Marks the adapter-registry setter as abdicated, matching Morpho adapter validation.
    /// @param selector The queried selector.
    /// @return status Always true.
    function abdicated(bytes4 selector) external pure returns (bool status) {
        selector;
        return true;
    }

    /// @notice Stubbed to satisfy the Morpho Vault V2 interface shape.
    /// @param newAdapterRegistry The ignored adapter registry.
    function setAdapterRegistry(address newAdapterRegistry) external pure {
        newAdapterRegistry;
    }
}

/// @notice Minimal mocked Aave aToken used by the Aave V3 adapter.
contract MockAaveAToken is ERC20, LocalOwned {
    address public immutable UNDERLYING_ASSET_ADDRESS;
    address public pool;

    /// @notice Stores the underlying asset and owner.
    /// @param underlyingAsset The reserve asset.
    /// @param name_ The token name.
    /// @param symbol_ The token symbol.
    /// @param owner_ The authorized owner.
    constructor(address underlyingAsset, string memory name_, string memory symbol_, address owner_)
        ERC20(name_, symbol_)
        LocalOwned(owner_)
    {
        UNDERLYING_ASSET_ADDRESS = underlyingAsset;
    }

    /// @notice Sets the pool allowed to mint, burn, and release underlying.
    /// @param newPool The Aave pool.
    function setPool(address newPool) external onlyOwner {
        pool = newPool;
    }

    /// @notice Mints new aTokens.
    /// @param account The share owner.
    /// @param amount The minted amount.
    function mint(address account, uint256 amount) external {
        if (msg.sender != pool) {
            revert NotOwner();
        }

        _mint(account, amount);
    }

    /// @notice Burns aTokens.
    /// @param account The share owner.
    /// @param amount The burned amount.
    function burn(address account, uint256 amount) external {
        if (msg.sender != pool) {
            revert NotOwner();
        }

        _burn(account, amount);
    }

    /// @notice Transfers underlying reserve assets out of the reserve.
    /// @param to The recipient.
    /// @param amount The transferred amount.
    function transferUnderlying(address to, uint256 amount) external {
        if (msg.sender != pool) {
            revert NotOwner();
        }

        IERC20(UNDERLYING_ASSET_ADDRESS).transfer(to, amount);
    }
}

/// @notice Minimal multi-reserve Aave V3-style pool used by the Aave adapter.
contract MockAavePool is LocalOwned {
    struct ReserveConfig {
        bool listed;
        address aToken;
        bool revertOnSupply;
        bool revertOnWithdraw;
    }

    mapping(address asset => ReserveConfig config) internal reserves;

    /// @notice Stores the owner.
    /// @param owner_ The authorized owner.
    constructor(address owner_) LocalOwned(owner_) {}

    /// @notice Registers a reserve asset and its corresponding mocked aToken.
    /// @param asset The reserve asset.
    /// @param aToken The mocked aToken.
    function setReserve(address asset, address aToken) external onlyOwner {
        reserves[asset].listed = true;
        reserves[asset].aToken = aToken;
    }

    /// @notice Toggles mocked supply failures for a reserve.
    /// @param asset The reserve asset.
    /// @param value Whether supply should revert.
    function setRevertOnSupply(address asset, bool value) external onlyOwner {
        reserves[asset].revertOnSupply = value;
    }

    /// @notice Toggles mocked withdrawal failures for a reserve.
    /// @param asset The reserve asset.
    /// @param value Whether withdraw should revert.
    function setRevertOnWithdraw(address asset, bool value) external onlyOwner {
        reserves[asset].revertOnWithdraw = value;
    }

    /// @notice Returns reserve metadata in the shape expected by the Aave adapter.
    /// @param asset The queried reserve asset.
    /// @return reserveData The mocked reserve data.
    function getReserveData(address asset) external view returns (AaveV3ReserveData memory reserveData) {
        ReserveConfig storage reserve = reserves[asset];
        reserveData.aTokenAddress = reserve.listed ? reserve.aToken : address(0);
    }

    /// @notice Supplies reserve assets into the mocked pool.
    /// @param asset The reserve asset.
    /// @param amount The supplied amount.
    /// @param onBehalfOf The aToken recipient.
    /// @param referralCode The ignored referral code.
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external {
        referralCode;

        ReserveConfig storage reserve = reserves[asset];
        require(reserve.listed, "invalid asset");
        require(!reserve.revertOnSupply, "supply failed");

        IERC20(asset).transferFrom(msg.sender, reserve.aToken, amount);
        MockAaveAToken(reserve.aToken).mint(onBehalfOf, amount);
    }

    /// @notice Withdraws reserve assets from the mocked pool.
    /// @param asset The reserve asset.
    /// @param amount The requested amount.
    /// @param to The withdrawal recipient.
    /// @return withdrawn The actual withdrawn amount.
    function withdraw(address asset, uint256 amount, address to) external returns (uint256 withdrawn) {
        ReserveConfig storage reserve = reserves[asset];
        require(reserve.listed, "invalid asset");
        require(!reserve.revertOnWithdraw, "withdraw failed");

        uint256 balance = IERC20(reserve.aToken).balanceOf(msg.sender);
        uint256 liquidity = IERC20(asset).balanceOf(reserve.aToken);
        withdrawn = amount > balance ? balance : amount;
        withdrawn = withdrawn > liquidity ? liquidity : withdrawn;
        if (withdrawn > 0) {
            MockAaveAToken(reserve.aToken).burn(msg.sender, withdrawn);
            MockAaveAToken(reserve.aToken).transferUnderlying(to, withdrawn);
        }
    }

    /// @notice Adds synthetic yield to a reserve and credits aToken shares to an account.
    /// @param asset The reserve asset.
    /// @param account The aToken holder receiving the yield.
    /// @param amount The additional amount.
    function accrueYield(address asset, address account, uint256 amount) external {
        ReserveConfig storage reserve = reserves[asset];
        require(reserve.listed, "invalid asset");

        IERC20(asset).transferFrom(msg.sender, reserve.aToken, amount);
        MockAaveAToken(reserve.aToken).mint(account, amount);
    }
}
