// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SyncDepositModeAssertion_v0_5_0} from "../../src/SyncDepositModeAssertion_v0.5.0.a.sol";
import {CredibleTest} from "credible-std/CredibleTest.sol";
import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {BeaconProxyFactory, InitStruct as BeaconProxyInitStruct} from "@src/protocol-v1/BeaconProxyFactory.sol";
import {FeeRegistry} from "@src/protocol-v1/FeeRegistry.sol";
import {VaultHelper} from "@test/v0.5.0/VaultHelper.sol";

import {IERC20Metadata, IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

using SafeERC20 for IERC20;
using Math for uint256;

/// @title MockERC20
/// @notice Simple mock ERC20 token for testing
contract MockERC20 is ERC20 {
    uint8 private _decimals;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _decimals = decimals_;
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title MockWETH
/// @notice Mock WETH (18 decimals)
contract MockWETH is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH", 18) {}

    receive() external payable {
        _mint(msg.sender, msg.value);
    }

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(
        uint256 amount
    ) external {
        _burn(msg.sender, amount);
        payable(msg.sender).transfer(amount);
    }
}

/// @title FuzzSyncDepositShareCalculation
/// @notice Fuzz tests for SyncDepositMode share calculation arithmetic
/// @dev Focuses on Invariant 4.B - testing share pricing formula:
///      shares = (assets * (totalSupply + decimalsOffset)) / (totalAssets + 1)
///
///      Critical edge cases:
///      - Zero totalSupply (first deposit)
///      - Extreme ratios (totalSupply >> totalAssets or vice versa)
///      - Various decimal configurations (0, 6, 8, 18)
///      - Rounding and precision loss
///      - Sequential deposits with state accumulation
contract FuzzSyncDepositShareCalculation is CredibleTest, Test {
    // ============ Mock Tokens ============
    MockERC20 public mockAsset;
    MockWETH public mockWETH;

    // ============ Protocol Contracts ============
    VaultHelper public vault;
    FeeRegistry public feeRegistry;
    BeaconProxyFactory public factory;

    // ============ Test Users ============
    VmSafe.Wallet public user1 = vm.createWallet("user1");
    VmSafe.Wallet public safe = vm.createWallet("safe");
    VmSafe.Wallet public valuationManager = vm.createWallet("valuationManager");
    VmSafe.Wallet public admin = vm.createWallet("admin");
    VmSafe.Wallet public feeReceiver = vm.createWallet("feeReceiver");
    VmSafe.Wallet public dao = vm.createWallet("dao");
    VmSafe.Wallet public whitelistManager = vm.createWallet("whitelistManager");

    /// @notice Setup vault with specific token decimals
    function setupVaultWithDecimals(
        uint8 tokenDecimals
    ) internal {
        // Deploy mock tokens
        mockAsset = new MockERC20("Mock Token", "MTK", tokenDecimals);
        mockWETH = new MockWETH();

        // Initialize fee registry
        feeRegistry = new FeeRegistry(false);
        feeRegistry.initialize(dao.addr, dao.addr);

        // Deploy vault implementation
        address implementation = address(new VaultHelper(false));

        // Deploy factory
        factory = new BeaconProxyFactory(address(feeRegistry), implementation, dao.addr, address(mockWETH));

        // Prepare initialization struct
        BeaconProxyInitStruct memory initStruct = BeaconProxyInitStruct({
            underlying: address(mockAsset),
            name: "Test Vault",
            symbol: "TVAULT",
            safe: safe.addr,
            whitelistManager: whitelistManager.addr,
            valuationManager: valuationManager.addr,
            admin: admin.addr,
            feeReceiver: feeReceiver.addr,
            managementRate: 0,
            performanceRate: 0,
            rateUpdateCooldown: 1 days,
            enableWhitelist: true
        });

        // Deploy vault
        vault = VaultHelper(implementation);
        vault.initialize(abi.encode(initStruct), address(feeRegistry), address(mockWETH));

        // Whitelist essential addresses and user
        address[] memory whitelist = new address[](6);
        whitelist[0] = feeReceiver.addr;
        whitelist[1] = dao.addr;
        whitelist[2] = safe.addr;
        whitelist[3] = vault.pendingSilo();
        whitelist[4] = address(feeRegistry);
        whitelist[5] = user1.addr;
        vm.prank(whitelistManager.addr);
        vault.addToWhitelist(whitelist);

        // Enable sync deposit mode
        vm.prank(safe.addr);
        vault.updateTotalAssetsLifespan(1000);

        // Settle to set expiration timestamp
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(0);
        vm.prank(safe.addr);
        vault.settleDeposit(0);
    }

    /// @notice Helper to scale amount based on token decimals
    function scaleAmount(uint256 baseAmount, uint8 decimals) internal pure returns (uint256) {
        if (decimals >= 6) {
            return baseAmount * (10 ** (decimals - 6));
        } else {
            return baseAmount / (10 ** (6 - decimals));
        }
    }

    // ==================== Fuzz Test: Share Calculation with Varying Decimals ====================

    /// @notice Fuzz test: syncDeposit share calculation with different token decimals
    /// @dev Tests the share pricing formula across edge cases
    function testFuzz_ShareCalculationWithDecimals(uint8 decimals, uint256 depositAmount, uint256 seed) public {
        // Bound inputs to valid ranges
        decimals = uint8(bound(decimals, 0, 18));

        // Constrain decimals to realistic values (0, 6, 8, 18)
        if (decimals > 0 && decimals < 6) decimals = 6;
        else if (decimals > 6 && decimals < 8) decimals = 8;
        else if (decimals > 8 && decimals < 18) decimals = 18;

        // Scale deposit amount based on decimals (minimum 1e6 base units to avoid dust/rounding to zero)
        uint256 baseAmount = bound(depositAmount, 1e6, 1e12);
        uint256 scaledAmount = scaleAmount(baseAmount, decimals);

        // Setup vault with chosen decimals
        setupVaultWithDecimals(decimals);

        // Give user enough tokens
        uint256 userBalance = scaledAmount * 10; // 10x the deposit amount
        mockAsset.mint(user1.addr, userBalance);
        vm.prank(user1.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        // Verify NAV is valid
        require(vault.isTotalAssetsValid(), "NAV should be valid");

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionSyncDepositAccounting.selector
        });

        // Execute first syncDeposit - this tests the assertion
        vm.prank(user1.addr);
        uint256 shares = vault.syncDeposit(scaledAmount, user1.addr, address(0));

        // Basic sanity checks
        assertGt(shares, 0, "Shares should be minted");
        assertEq(vault.totalAssets(), scaledAmount, "Total assets should match deposit");
        assertEq(vault.balanceOf(user1.addr), shares, "User should receive shares");
    }

    // ==================== Fuzz Test: First Deposit (Zero Supply) ====================

    /// @notice Fuzz test: First deposit when totalSupply == 0
    /// @dev Critical edge case: shares = assets * decimalsOffset
    function testFuzz_FirstDepositZeroSupply(uint8 decimals, uint256 depositAmount) public {
        // Bound inputs
        decimals = uint8(bound(decimals, 0, 18));
        if (decimals > 0 && decimals < 6) decimals = 6;
        else if (decimals > 6 && decimals < 8) decimals = 8;
        else if (decimals > 8 && decimals < 18) decimals = 18;

        uint256 baseAmount = bound(depositAmount, 1e6, 1e12);
        uint256 scaledAmount = scaleAmount(baseAmount, decimals);

        setupVaultWithDecimals(decimals);

        mockAsset.mint(user1.addr, scaledAmount * 10);
        vm.prank(user1.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        // Verify vault is empty (zero supply case)
        assertEq(vault.totalSupply(), 0, "Total supply should be zero");
        assertEq(vault.totalAssets(), 0, "Total assets should be zero");

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionSyncDepositAccounting.selector
        });

        // Execute deposit
        vm.prank(user1.addr);
        uint256 shares = vault.syncDeposit(scaledAmount, user1.addr, address(0));

        // For first deposit: shares = assets * 10^(18 - decimals)
        uint256 expectedShares = scaledAmount * (10 ** (18 - decimals));

        assertEq(shares, expectedShares, "First deposit shares should equal assets * decimalsOffset");
        assertEq(vault.totalSupply(), expectedShares, "Total supply should match shares");
    }

    // ==================== Fuzz Test: Sequential Deposits ====================

    /// @notice Fuzz test: Two sequential deposits with different amounts
    /// @dev Tests share calculation with non-zero totalSupply
    function testFuzz_SequentialDeposits(uint8 decimals, uint256 firstDeposit, uint256 secondDeposit) public {
        // Bound inputs
        decimals = uint8(bound(decimals, 0, 18));
        if (decimals > 0 && decimals < 6) decimals = 6;
        else if (decimals > 6 && decimals < 8) decimals = 8;
        else if (decimals > 8 && decimals < 18) decimals = 18;

        uint256 firstAmount = scaleAmount(bound(firstDeposit, 1e6, 1e11), decimals);
        uint256 secondAmount = scaleAmount(bound(secondDeposit, 1e6, 1e11), decimals);

        setupVaultWithDecimals(decimals);

        uint256 totalNeeded = firstAmount + secondAmount;
        mockAsset.mint(user1.addr, totalNeeded * 2);
        vm.prank(user1.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        // First deposit (no assertion)
        vm.prank(user1.addr);
        uint256 shares1 = vault.syncDeposit(firstAmount, user1.addr, address(0));

        // Second deposit with assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionSyncDepositAccounting.selector
        });

        vm.prank(user1.addr);
        uint256 shares2 = vault.syncDeposit(secondAmount, user1.addr, address(0));

        // Verify total state
        assertEq(vault.totalAssets(), firstAmount + secondAmount, "Total assets should sum both deposits");
        assertEq(vault.totalSupply(), shares1 + shares2, "Total supply should sum both share amounts");
        assertGt(shares1, 0, "First deposit shares should be non-zero");
        assertGt(shares2, 0, "Second deposit shares should be non-zero");
    }

    // ==================== Fuzz Test: Extreme Ratios ====================

    /// @notice Fuzz test: Extreme totalSupply/totalAssets ratios
    /// @dev Tests precision loss and rounding with skewed ratios
    function testFuzz_ExtremeRatios(
        uint8 decimals,
        uint256 initialDeposit,
        uint256 subsequentDeposit,
        bool highSupplyRatio
    ) public {
        // Bound inputs
        decimals = uint8(bound(decimals, 6, 18)); // Only 6 and 18 for simplicity
        if (decimals > 6 && decimals < 18) decimals = 18;

        // Create extreme ratio scenarios
        uint256 firstAmount;
        uint256 secondAmount;

        if (highSupplyRatio) {
            // High supply relative to assets: deposit large then small
            firstAmount = scaleAmount(bound(initialDeposit, 1e9, 1e11), decimals);
            secondAmount = scaleAmount(bound(subsequentDeposit, 1, 1e6), decimals);
        } else {
            // Low supply relative to assets: deposit small then large
            firstAmount = scaleAmount(bound(initialDeposit, 1, 1e6), decimals);
            secondAmount = scaleAmount(bound(subsequentDeposit, 1e9, 1e11), decimals);
        }

        setupVaultWithDecimals(decimals);

        uint256 totalNeeded = firstAmount + secondAmount;
        mockAsset.mint(user1.addr, totalNeeded * 2);
        vm.prank(user1.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        // First deposit
        vm.prank(user1.addr);
        vault.syncDeposit(firstAmount, user1.addr, address(0));

        // Second deposit with assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionSyncDepositAccounting.selector
        });

        vm.prank(user1.addr);
        uint256 shares2 = vault.syncDeposit(secondAmount, user1.addr, address(0));

        // Basic sanity: shares should be non-zero even with extreme ratios
        assertGt(shares2, 0, "Shares should be minted even with extreme ratios");
    }
}
