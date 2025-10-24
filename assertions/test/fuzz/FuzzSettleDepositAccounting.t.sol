// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TotalAssetsAccountingAssertion_v0_5_0} from "../../src/TotalAssetsAccountingAssertion_v0.5.0.a.sol";
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

/// @title FuzzSettleDepositAccounting
/// @notice Fuzz tests for settleDeposit totalAssets accounting
/// @dev Focuses on Invariant 1.A - testing accounting formula:
///      totalAssets_final = newNAV + pendingAssets
///
///      Critical scenarios:
///      - Empty vault (NAV = 0) with pending deposits
///      - Non-empty vault (NAV > 0) with pending deposits
///      - Sequential settlements with state accumulation
///      - Zero pending deposits (NAV update only)
///      - Extreme value combinations
contract FuzzSettleDepositAccounting is CredibleTest, Test {
    // ============ Mock Tokens ============
    MockERC20 public mockAsset;
    MockWETH public mockWETH;

    // ============ Protocol Contracts ============
    VaultHelper public vault;
    FeeRegistry public feeRegistry;
    BeaconProxyFactory public factory;

    // ============ Test Users ============
    VmSafe.Wallet public user1 = vm.createWallet("user1");
    VmSafe.Wallet public user2 = vm.createWallet("user2");
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

        // Whitelist essential addresses and users
        address[] memory whitelist = new address[](7);
        whitelist[0] = feeReceiver.addr;
        whitelist[1] = dao.addr;
        whitelist[2] = safe.addr;
        whitelist[3] = vault.pendingSilo();
        whitelist[4] = address(feeRegistry);
        whitelist[5] = user1.addr;
        whitelist[6] = user2.addr;
        vm.prank(whitelistManager.addr);
        vault.addToWhitelist(whitelist);
    }

    /// @notice Helper to scale amount based on token decimals
    function scaleAmount(uint256 baseAmount, uint8 decimals) internal pure returns (uint256) {
        if (decimals >= 6) {
            return baseAmount * (10 ** (decimals - 6));
        } else {
            return baseAmount / (10 ** (6 - decimals));
        }
    }

    // ==================== Fuzz Test 1: Empty Vault with Pending Deposits ====================

    /// @notice Fuzz test: settleDeposit accounting when vault is empty (NAV = 0)
    /// @dev Tests the formula: totalAssets = 0 + pendingAssets
    function testFuzz_EmptyVaultSettleDeposit(uint8 decimals, uint256 pendingAmount) public {
        // Bound inputs to valid ranges (6, 18 only - excluding 0 for simplicity)
        decimals = uint8(bound(decimals, 6, 18));

        // Constrain decimals to realistic values (6, 18)
        if (decimals > 6 && decimals < 18) decimals = 18;

        // Scale pending amount (minimum 1e6 base units to avoid dust)
        uint256 baseAmount = bound(pendingAmount, 1e6, 1e11);
        uint256 scaledPending = scaleAmount(baseAmount, decimals);

        // Setup vault with chosen decimals
        setupVaultWithDecimals(decimals);

        // Give user enough tokens
        mockAsset.mint(user1.addr, scaledPending * 2);
        vm.prank(user1.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        // User requests deposit (goes to Silo)
        vm.prank(user1.addr);
        vault.requestDeposit(scaledPending, user1.addr, user1.addr);

        // Verify vault is empty before settlement
        assertEq(vault.totalAssets(), 0, "Vault should be empty before settlement");

        // Settle: NAV = 0 (empty vault), pending = scaledPending
        // Must call updateNewTotalAssets BEFORE registering assertion (triggers epoch change)
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(0);

        // Safe approves vault (required before settlement)
        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSettleDepositAccounting.selector
        });

        vm.prank(safe.addr);
        vault.settleDeposit(0);

        // Verify: totalAssets = 0 + scaledPending
        assertEq(vault.totalAssets(), scaledPending, "totalAssets should equal pending deposits");
    }

    // ==================== Fuzz Test 2: Non-Empty Vault with Pending Deposits ====================

    /// @notice Fuzz test: settleDeposit accounting when vault has existing NAV
    /// @dev Tests the formula: totalAssets = existingNAV + pendingAssets
    function testFuzz_NonEmptyVaultSettleDeposit(uint8 decimals, uint256 existingNAV, uint256 pendingAmount) public {
        // Bound inputs (6, 18 only)
        decimals = uint8(bound(decimals, 6, 18));
        if (decimals > 6 && decimals < 18) decimals = 18;

        // Bound existing NAV and pending (avoid overflow)
        uint256 baseNAV = bound(existingNAV, 1e6, 1e11);
        uint256 basePending = bound(pendingAmount, 1e6, 1e11);

        uint256 scaledNAV = scaleAmount(baseNAV, decimals);
        uint256 scaledPending = scaleAmount(basePending, decimals);

        setupVaultWithDecimals(decimals);

        // Give Safe the NAV amount (simulating existing investments)
        mockAsset.mint(safe.addr, scaledNAV);

        // Give user tokens for deposit
        mockAsset.mint(user1.addr, scaledPending * 2);
        vm.prank(user1.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        // User requests deposit
        vm.prank(user1.addr);
        vault.requestDeposit(scaledPending, user1.addr, user1.addr);

        // Settle: NAV = scaledNAV (existing portfolio value), pending = scaledPending
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(scaledNAV);

        // Safe approves vault
        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSettleDepositAccounting.selector
        });

        vm.prank(safe.addr);
        vault.settleDeposit(scaledNAV);

        // Verify: totalAssets = scaledNAV + scaledPending
        assertEq(vault.totalAssets(), scaledNAV + scaledPending, "totalAssets should equal NAV + pending");
    }

    // ==================== Fuzz Test 3: Sequential Settlements ====================

    /// @notice Fuzz test: Multiple sequential deposit/settlement cycles
    /// @dev Tests accounting accumulation across multiple settlements
    function testFuzz_SequentialSettlements(
        uint8 decimals,
        uint256 firstDeposit,
        uint256 secondDeposit,
        uint256 navGrowth
    ) public {
        // Bound inputs (6, 18 only)
        decimals = uint8(bound(decimals, 6, 18));
        if (decimals > 6 && decimals < 18) decimals = 18;

        uint256 baseFirst = bound(firstDeposit, 1e6, 1e10);
        uint256 baseSecond = bound(secondDeposit, 1e6, 1e10);
        uint256 baseGrowth = bound(navGrowth, 0, 1e10); // NAV can grow between settlements

        uint256 scaledFirst = scaleAmount(baseFirst, decimals);
        uint256 scaledSecond = scaleAmount(baseSecond, decimals);
        uint256 scaledGrowth = scaleAmount(baseGrowth, decimals);

        setupVaultWithDecimals(decimals);

        // Fund users
        mockAsset.mint(user1.addr, scaledFirst * 2);
        mockAsset.mint(user2.addr, scaledSecond * 2);
        vm.prank(user1.addr);
        mockAsset.approve(address(vault), type(uint256).max);
        vm.prank(user2.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        // First cycle: user1 deposits
        vm.prank(user1.addr);
        vault.requestDeposit(scaledFirst, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(0);

        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSettleDepositAccounting.selector
        });

        vm.prank(safe.addr);
        vault.settleDeposit(0);

        uint256 expectedAfterFirst = scaledFirst;
        assertEq(vault.totalAssets(), expectedAfterFirst, "First settlement: totalAssets should equal first deposit");

        // Simulate NAV growth (Safe generates returns)
        uint256 navAfterGrowth = expectedAfterFirst + scaledGrowth;

        // Second cycle: user2 deposits
        vm.prank(user2.addr);
        vault.requestDeposit(scaledSecond, user2.addr, user2.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(navAfterGrowth);

        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSettleDepositAccounting.selector
        });

        vm.prank(safe.addr);
        vault.settleDeposit(navAfterGrowth);

        uint256 expectedAfterSecond = navAfterGrowth + scaledSecond;
        assertEq(
            vault.totalAssets(), expectedAfterSecond, "Second settlement: totalAssets should equal NAV + second deposit"
        );
    }

    // ==================== Fuzz Test 4: Zero Pending Deposits ====================

    /// @notice Fuzz test: settleDeposit with no pending deposits (NAV update only)
    /// @dev Tests edge case: totalAssets = newNAV + 0
    function testFuzz_ZeroPendingDeposits(uint8 decimals, uint256 navValue) public {
        // Bound inputs (6, 18 only)
        decimals = uint8(bound(decimals, 6, 18));
        if (decimals > 6 && decimals < 18) decimals = 18;

        uint256 baseNAV = bound(navValue, 0, 1e12);
        uint256 scaledNAV = scaleAmount(baseNAV, decimals);

        setupVaultWithDecimals(decimals);

        // No requestDeposit calls - no pending deposits

        // Settle with no pending: totalAssets should equal NAV
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(scaledNAV);

        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSettleDepositAccounting.selector
        });

        vm.prank(safe.addr);
        vault.settleDeposit(scaledNAV);

        assertEq(vault.totalAssets(), scaledNAV, "totalAssets should equal NAV when no pending deposits");
    }

    // ==================== Fuzz Test 5: Extreme Value Combinations ====================

    /// @notice Fuzz test: Extreme combinations of NAV and pending amounts
    /// @dev Tests precision and overflow scenarios
    function testFuzz_ExtremeValueCombinations(
        uint8 decimals,
        uint256 navAmount,
        uint256 pendingAmount,
        bool largeNav
    ) public {
        // Bound inputs
        decimals = uint8(bound(decimals, 6, 18)); // Only 6 and 18 for simplicity
        if (decimals > 6 && decimals < 18) decimals = 18;

        uint256 baseNAV;
        uint256 basePending;

        if (largeNav) {
            // Large NAV, small pending
            baseNAV = bound(navAmount, 1e9, 1e11);
            basePending = bound(pendingAmount, 1e6, 1e7);
        } else {
            // Small NAV, large pending
            baseNAV = bound(navAmount, 0, 1e7);
            basePending = bound(pendingAmount, 1e9, 1e11);
        }

        uint256 scaledNAV = scaleAmount(baseNAV, decimals);
        uint256 scaledPending = scaleAmount(basePending, decimals);

        setupVaultWithDecimals(decimals);

        // Give user tokens
        mockAsset.mint(user1.addr, scaledPending * 2);
        vm.prank(user1.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        // Request deposit
        vm.prank(user1.addr);
        vault.requestDeposit(scaledPending, user1.addr, user1.addr);

        // Settle
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(scaledNAV);

        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSettleDepositAccounting.selector
        });

        vm.prank(safe.addr);
        vault.settleDeposit(scaledNAV);

        // Verify accounting holds even with extreme ratios
        assertEq(vault.totalAssets(), scaledNAV + scaledPending, "Accounting should hold with extreme value ratios");
    }
}
