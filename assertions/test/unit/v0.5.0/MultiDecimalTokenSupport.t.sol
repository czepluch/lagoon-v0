// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SiloBalanceConsistencyAssertion} from "../../../src/SiloBalanceConsistencyAssertion.a.sol";
import {SyncDepositModeAssertion_v0_5_0} from "../../../src/SyncDepositModeAssertion_v0.5.0.a.sol";
import {TotalAssetsAccountingAssertion_v0_5_0} from "../../../src/TotalAssetsAccountingAssertion_v0.5.0.a.sol";

import {AssertionBaseTest_v0_5_0} from "../../AssertionBaseTest_v0_5_0.sol";

import {BeaconProxyFactory, InitStruct as BeaconProxyInitStruct} from "@src/protocol-v1/BeaconProxyFactory.sol";
import {FeeRegistry} from "@src/protocol-v1/FeeRegistry.sol";
import {VaultHelper} from "@test/v0.5.0/VaultHelper.sol";

import {IERC20Metadata, IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

using SafeERC20 for IERC20;
using Math for uint256;

/// @title MockERC20Local
/// @notice Local mock ERC20 token for multi-decimal testing (separate from base MockERC20)
contract MockERC20Local is ERC20 {
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

/// @title TestMultiDecimalTokenSupport
/// @notice Tests Invariants 1, 3, 4 with tokens of varying decimals (0, 6, 8, 18)
/// @dev Validates that assertions work correctly regardless of token decimals.
///      Tests cover:
///      - 18-decimal tokens (WETH-like)
///      - 8-decimal tokens (WBTC-like)
///      - 6-decimal tokens (USDC-like)
///      - 0-decimal tokens (edge case)
///      - decimalsOffset calculation correctness
contract TestMultiDecimalTokenSupport is AssertionBaseTest_v0_5_0 {
    // Use local mock for multi-decimal testing (don't inherit mockAsset from base)
    MockERC20Local public mockAssetLocal;

    // ============ Helper Functions ============

    /// @notice Setup vault with a specific token (overrides base setup)
    function setupVaultWithToken(MockERC20Local token, string memory name, string memory symbol) internal {
        mockAssetLocal = token;

        // Deploy vault implementation
        address implementation = address(new VaultHelper(false));

        // Prepare initialization struct
        BeaconProxyInitStruct memory initStruct = BeaconProxyInitStruct({
            underlying: address(mockAssetLocal),
            name: name,
            symbol: symbol,
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

        // Whitelist essential addresses
        address[] memory essentialAddresses = new address[](5);
        essentialAddresses[0] = feeReceiver.addr;
        essentialAddresses[1] = dao.addr;
        essentialAddresses[2] = safe.addr;
        essentialAddresses[3] = vault.pendingSilo();
        essentialAddresses[4] = address(feeRegistry);
        vm.prank(whitelistManager.addr);
        vault.addToWhitelist(essentialAddresses);

        // Label contracts
        vm.label(address(vault), name);
        vm.label(vault.pendingSilo(), "vault.pendingSilo");
        vm.label(address(mockAssetLocal), name);
    }

    /// @notice Deal assets and approve vault for a user (overridden for local mock)
    function dealAndApproveAndWhitelistLocal(address user, uint256 amount) internal {
        mockAssetLocal.mint(user, amount);
        vm.prank(user);
        IERC20(address(mockAssetLocal)).approve(address(vault), type(uint256).max);
        deal(user, 100 ether); // Gas

        address[] memory usersArray = new address[](1);
        usersArray[0] = user;
        vm.prank(whitelistManager.addr);
        vault.addToWhitelist(usersArray);
    }

    function setUp() public {
        // Setup base infrastructure (feeRegistry, factory, mockWETH)
        // We'll override the vault setup in individual tests
        feeRegistry = new FeeRegistry(false);
        feeRegistry.initialize(dao.addr, dao.addr);

        address implementation = address(new VaultHelper(false));
        factory = new BeaconProxyFactory(address(feeRegistry), implementation, dao.addr, address(mockWETH));
    }

    // ==================== 18-Decimal Token Tests (WETH-like) ====================

    /// @notice Test: settleDeposit with 18-decimal token
    function test18DecimalToken_SettleDeposit() public {
        MockERC20Local token18 = new MockERC20Local("Mock WETH", "WETH", 18);
        setupVaultWithToken(token18, "WETH Vault", "vWETH");

        // Verify decimalsOffset = 0 for 18-decimal tokens (18-18=0, offset value is 10^0 = 1)
        assertEq(vault.decimalsOffset(), 0, "decimalsOffset should be 0 for 18-decimal tokens");

        dealAndApproveAndWhitelistLocal(user1.addr, 10 ether);

        // Request deposit
        vm.prank(user1.addr);
        vault.requestDeposit(1 ether, user1.addr, user1.addr);

        // Update NAV (base totalAssets before settlement)
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(0);

        // Setup Safe approval
        vm.prank(safe.addr);
        mockAssetLocal.approve(address(vault), type(uint256).max);

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSettleDepositAccounting.selector
        });

        // Settle deposit with base totalAssets = 0
        // settleDeposit will add the 1 ether pending deposit to get final totalAssets = 1 ether
        vm.prank(safe.addr);
        vault.settleDeposit(0);

        assertEq(vault.totalAssets(), 1 ether, "Total assets should match deposit");
    }

    /// @notice Test: settleRedeem with 18-decimal token
    function test18DecimalToken_SettleRedeem() public {
        MockERC20Local token18 = new MockERC20Local("Mock WETH", "WETH", 18);
        setupVaultWithToken(token18, "WETH Vault", "vWETH");

        dealAndApproveAndWhitelistLocal(user1.addr, 10 ether);

        // Setup: deposit and mint shares
        vm.prank(user1.addr);
        vault.requestDeposit(1 ether, user1.addr, user1.addr);

        // For this test, we're simulating the vault already having 1 ether in the Safe
        // So updateNewTotalAssets(1 ether) represents existing holdings before settlement
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(1 ether);

        mockAssetLocal.mint(safe.addr, 1 ether);
        vm.prank(safe.addr);
        mockAssetLocal.approve(address(vault), type(uint256).max);
        vm.prank(safe.addr);
        vault.settleDeposit(1 ether); // Base 1 ether + pending 1 ether = 2 ether final

        uint256 claimableShares = vault.claimableDepositRequest(0, user1.addr);
        vm.prank(user1.addr);
        vault.deposit(claimableShares, user1.addr, user1.addr);

        // Request redeem
        uint256 userShares = vault.balanceOf(user1.addr);
        vm.prank(user1.addr);
        vault.requestRedeem(userShares, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(1 ether);

        uint256 needed = vault.totalAssets();
        mockAssetLocal.mint(safe.addr, needed);
        vm.prank(safe.addr);
        mockAssetLocal.approve(address(vault), type(uint256).max);

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSettleRedeemAccounting.selector
        });

        // Settle redeem
        vm.prank(safe.addr);
        vault.settleRedeem(1 ether);
    }

    /// @notice Test: syncDeposit with 18-decimal token
    function test18DecimalToken_SyncDeposit() public {
        MockERC20Local token18 = new MockERC20Local("Mock WETH", "WETH", 18);
        setupVaultWithToken(token18, "WETH Vault", "vWETH");

        dealAndApproveAndWhitelistLocal(user1.addr, 10 ether);

        // Enable sync mode
        vm.prank(safe.addr);
        vault.updateTotalAssetsLifespan(1000);
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(0);
        vm.prank(safe.addr);
        vault.settleDeposit(0);

        require(vault.isTotalAssetsValid(), "NAV should be valid");

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionSyncDepositAccounting.selector
        });

        // Execute syncDeposit
        vm.prank(user1.addr);
        uint256 shares = vault.syncDeposit(1 ether, user1.addr, address(0));

        assertGt(shares, 0, "Shares should be minted");
        assertEq(vault.totalAssets(), 1 ether, "Total assets should match deposit");
    }

    /// @notice Test: Silo balance consistency with 18-decimal token
    function test18DecimalToken_SiloBalanceConsistency() public {
        MockERC20Local token18 = new MockERC20Local("Mock WETH", "WETH", 18);
        setupVaultWithToken(token18, "WETH Vault", "vWETH");

        dealAndApproveAndWhitelistLocal(user1.addr, 10 ether);

        // Request deposit
        vm.prank(user1.addr);
        vault.requestDeposit(1 ether, user1.addr, user1.addr);

        // Update NAV and settle
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(1 ether);

        mockAssetLocal.mint(safe.addr, 1 ether);
        vm.prank(safe.addr);
        mockAssetLocal.approve(address(vault), type(uint256).max);

        cl.assertion({
            adopter: address(vault),
            createData: type(SiloBalanceConsistencyAssertion).creationCode,
            fnSelector: SiloBalanceConsistencyAssertion.assertionSettleDepositSiloBalance.selector
        });

        vm.prank(safe.addr);
        vault.settleDeposit(1 ether);

        // Verify Silo is empty after settlement
        assertEq(mockAssetLocal.balanceOf(vault.pendingSilo()), 0, "Silo should be empty");
    }

    // ==================== 8-Decimal Token Tests (WBTC-like) ====================

    /// @notice Test: settleDeposit with 8-decimal token
    function test8DecimalToken_SettleDeposit() public {
        MockERC20Local token8 = new MockERC20Local("Mock WBTC", "WBTC", 8);
        setupVaultWithToken(token8, "WBTC Vault", "vWBTC");

        // Verify decimalsOffset = 10 for 8-decimal tokens (18-8=10, offset value is 10^10)
        assertEq(vault.decimalsOffset(), 10, "decimalsOffset should be 10 for 8-decimal tokens");

        dealAndApproveAndWhitelistLocal(user1.addr, 10e8); // 10 WBTC

        vm.prank(user1.addr);
        vault.requestDeposit(1e8, user1.addr, user1.addr); // 1 WBTC

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(0);

        vm.prank(safe.addr);
        mockAssetLocal.approve(address(vault), type(uint256).max);

        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSettleDepositAccounting.selector
        });

        vm.prank(safe.addr);
        vault.settleDeposit(0);

        assertEq(vault.totalAssets(), 1e8, "Total assets should match deposit");
    }

    /// @notice Test: syncDeposit with 8-decimal token
    function test8DecimalToken_SyncDeposit() public {
        MockERC20Local token8 = new MockERC20Local("Mock WBTC", "WBTC", 8);
        setupVaultWithToken(token8, "WBTC Vault", "vWBTC");

        dealAndApproveAndWhitelistLocal(user1.addr, 10e8);

        // Enable sync mode
        vm.prank(safe.addr);
        vault.updateTotalAssetsLifespan(1000);
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(0);
        vm.prank(safe.addr);
        vault.settleDeposit(0);

        require(vault.isTotalAssetsValid(), "NAV should be valid");

        cl.assertion({
            adopter: address(vault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionSyncDepositAccounting.selector
        });

        vm.prank(user1.addr);
        uint256 shares = vault.syncDeposit(1e8, user1.addr, address(0));

        assertGt(shares, 0, "Shares should be minted");
        assertEq(vault.totalAssets(), 1e8, "Total assets should match deposit");
    }

    /// @notice Test: Multiple operations with 8-decimal token
    function test8DecimalToken_MultipleOperations() public {
        MockERC20Local token8 = new MockERC20Local("Mock WBTC", "WBTC", 8);
        setupVaultWithToken(token8, "WBTC Vault", "vWBTC");

        dealAndApproveAndWhitelistLocal(user1.addr, 100e8);
        dealAndApproveAndWhitelistLocal(user2.addr, 100e8);

        // First deposit
        vm.prank(user1.addr);
        vault.requestDeposit(5e8, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(0);

        vm.prank(safe.addr);
        mockAssetLocal.approve(address(vault), type(uint256).max);

        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSettleDepositAccounting.selector
        });

        vm.prank(safe.addr);
        vault.settleDeposit(0); // Base 0 + pending 5e8 = 5e8 final

        // Second deposit
        vm.prank(user2.addr);
        vault.requestDeposit(3e8, user2.addr, user2.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(5e8); // Current totalAssets before adding new pending

        vm.prank(safe.addr);
        mockAssetLocal.approve(address(vault), type(uint256).max);

        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSettleDepositAccounting.selector
        });

        vm.prank(safe.addr);
        vault.settleDeposit(5e8); // Base 5e8 + pending 3e8 = 8e8 final

        assertEq(vault.totalAssets(), 8e8, "Total assets should be 8 WBTC");
    }

    // ==================== 0-Decimal Token Tests (Edge Case) ====================

    /// @notice Test: settleDeposit with 0-decimal token (edge case)
    function test0DecimalToken_SettleDeposit() public {
        MockERC20Local token0 = new MockERC20Local("Mock Token", "MTK", 0);
        setupVaultWithToken(token0, "Zero Decimal Vault", "vMTK");

        // Verify decimalsOffset = 18 for 0-decimal tokens (18-0=18, offset value is 10^18)
        assertEq(vault.decimalsOffset(), 18, "decimalsOffset should be 18 for 0-decimal tokens");

        dealAndApproveAndWhitelistLocal(user1.addr, 1000); // 1000 tokens (no decimals)

        vm.prank(user1.addr);
        vault.requestDeposit(100, user1.addr, user1.addr); // 100 tokens

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(0);

        vm.prank(safe.addr);
        mockAssetLocal.approve(address(vault), type(uint256).max);

        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSettleDepositAccounting.selector
        });

        vm.prank(safe.addr);
        vault.settleDeposit(0);

        assertEq(vault.totalAssets(), 100, "Total assets should be 100 tokens");
    }

    /// @notice Test: syncDeposit with 0-decimal token
    function test0DecimalToken_SyncDeposit() public {
        MockERC20Local token0 = new MockERC20Local("Mock Token", "MTK", 0);
        setupVaultWithToken(token0, "Zero Decimal Vault", "vMTK");

        dealAndApproveAndWhitelistLocal(user1.addr, 1000);

        // Enable sync mode
        vm.prank(safe.addr);
        vault.updateTotalAssetsLifespan(1000);
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(0);
        vm.prank(safe.addr);
        vault.settleDeposit(0);

        require(vault.isTotalAssetsValid(), "NAV should be valid");

        cl.assertion({
            adopter: address(vault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionSyncDepositAccounting.selector
        });

        vm.prank(user1.addr);
        uint256 shares = vault.syncDeposit(100, user1.addr, address(0));

        assertGt(shares, 0, "Shares should be minted");
        assertEq(vault.totalAssets(), 100, "Total assets should be 100 tokens");
    }

    /// @notice Test: Share calculation precision with 0-decimal token
    function test0DecimalToken_SharePrecision() public {
        MockERC20Local token0 = new MockERC20Local("Mock Token", "MTK", 0);
        setupVaultWithToken(token0, "Zero Decimal Vault", "vMTK");

        dealAndApproveAndWhitelistLocal(user1.addr, 1000);

        // Enable sync mode
        vm.prank(safe.addr);
        vault.updateTotalAssetsLifespan(1000);
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(0);
        vm.prank(safe.addr);
        vault.settleDeposit(0);

        // First deposit: 50 tokens
        vm.prank(user1.addr);
        uint256 shares1 = vault.syncDeposit(50, user1.addr, address(0));

        // Verify shares account for decimalsOffset (10^18)
        // Expected: 50 * (0 + 10^18) / 1 = 50 * 10^18
        assertEq(shares1, 50 * 10 ** 18, "Shares should scale correctly");

        // Second deposit: 25 tokens (vault now has 50 totalAssets, 50e18 totalSupply)
        vm.prank(user1.addr);
        uint256 shares2 = vault.syncDeposit(25, user1.addr, address(0));

        // Expected: 25 * totalSupply / totalAssets = 25 * 50e18 / 50 = 25e18
        // For non-empty vaults, shares are proportional to existing ratio
        assertEq(shares2, 25e18, "Second deposit shares should be proportional");
    }

    // ==================== decimalsOffset Verification Tests ====================

    /// @notice Test: Verify decimalsOffset calculation for all token types
    function testDecimalsOffsetCalculation() public {
        // 18-decimal token: decimalsOffset = 18-18 = 0 (offset value = 10^0 = 1)
        MockERC20Local token18 = new MockERC20Local("Token18", "T18", 18);
        setupVaultWithToken(token18, "Vault18", "V18");
        assertEq(vault.decimalsOffset(), 0, "18-decimal offset should be 0");

        // 8-decimal token: decimalsOffset = 18-8 = 10 (offset value = 10^10)
        MockERC20Local token8 = new MockERC20Local("Token8", "T8", 8);
        setupVaultWithToken(token8, "Vault8", "V8");
        assertEq(vault.decimalsOffset(), 10, "8-decimal offset should be 10");

        // 6-decimal token: decimalsOffset = 18-6 = 12 (offset value = 10^12)
        MockERC20Local token6 = new MockERC20Local("Token6", "T6", 6);
        setupVaultWithToken(token6, "Vault6", "V6");
        assertEq(vault.decimalsOffset(), 12, "6-decimal offset should be 12");

        // 0-decimal token: decimalsOffset = 18-0 = 18 (offset value = 10^18)
        MockERC20Local token0 = new MockERC20Local("Token0", "T0", 0);
        setupVaultWithToken(token0, "Vault0", "V0");
        assertEq(vault.decimalsOffset(), 18, "0-decimal offset should be 18");
    }

    /// @notice Test: Share calculation consistency across different decimals
    /// @dev Verifies that share calculation logic works correctly with decimalsOffset
    function testShareCalculationConsistency() public {
        // Test with 6-decimal token (USDC-like)
        MockERC20Local token6 = new MockERC20Local("USDC", "USDC", 6);
        setupVaultWithToken(token6, "USDC Vault", "vUSDC");
        dealAndApproveAndWhitelistLocal(user1.addr, 1000e6);

        vm.prank(safe.addr);
        vault.updateTotalAssetsLifespan(1000);
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(0);
        vm.prank(safe.addr);
        vault.settleDeposit(0);

        // First deposit: 100 USDC = 100e6
        vm.prank(user1.addr);
        uint256 shares6 = vault.syncDeposit(100e6, user1.addr, address(0));

        // Expected: 100e6 * (0 + 10^12) / 1 = 100e6 * 10^12 = 100e18
        assertEq(shares6, 100e18, "First deposit should receive 100e18 shares");

        // Test with 18-decimal token (WETH-like)
        MockERC20Local token18 = new MockERC20Local("WETH", "WETH", 18);
        setupVaultWithToken(token18, "WETH Vault", "vWETH");
        dealAndApproveAndWhitelistLocal(user1.addr, 1000 ether);

        vm.prank(safe.addr);
        vault.updateTotalAssetsLifespan(1000);
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(0);
        vm.prank(safe.addr);
        vault.settleDeposit(0);

        // First deposit: 100 WETH = 100e18
        vm.prank(user1.addr);
        uint256 shares18 = vault.syncDeposit(100 ether, user1.addr, address(0));

        // Expected: 100e18 * (0 + 1) / 1 = 100e18
        assertEq(shares18, 100e18, "First deposit should receive 100e18 shares");

        // Both vaults should have same share amount (100e18) despite different asset decimals
        // This proves decimalsOffset normalizes shares correctly
    }

    /// @notice Test: Silo balance consistency with multiple decimal tokens
    function testSiloBalanceConsistencyMultipleDecimals() public {
        // Test with 6-decimal token
        MockERC20Local token6 = new MockERC20Local("USDC", "USDC", 6);
        setupVaultWithToken(token6, "USDC Vault", "vUSDC");
        dealAndApproveAndWhitelistLocal(user1.addr, 1000e6);

        vm.prank(user1.addr);
        vault.requestDeposit(100e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(100e6);

        mockAssetLocal.mint(safe.addr, 100e6);
        vm.prank(safe.addr);
        mockAssetLocal.approve(address(vault), type(uint256).max);

        cl.assertion({
            adopter: address(vault),
            createData: type(SiloBalanceConsistencyAssertion).creationCode,
            fnSelector: SiloBalanceConsistencyAssertion.assertionSettleDepositSiloBalance.selector
        });

        vm.prank(safe.addr);
        vault.settleDeposit(100e6);

        assertEq(mockAssetLocal.balanceOf(vault.pendingSilo()), 0, "Silo should be empty after settlement");
    }
}
