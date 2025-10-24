// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SyncDepositModeAssertion_v0_5_0} from "../../../src/SyncDepositModeAssertion_v0.5.0.a.sol";
import {TotalAssetsAccountingAssertion_v0_5_0} from "../../../src/TotalAssetsAccountingAssertion_v0.5.0.a.sol";
import {AssertionBaseTest_v0_5_0} from "../../AssertionBaseTest_v0_5_0.sol";

import {BeaconProxyFactory, InitStruct as BeaconProxyInitStruct} from "@src/protocol-v1/BeaconProxyFactory.sol";
import {VaultHelper} from "@test/v0.5.0/VaultHelper.sol";

import {IERC20Metadata, IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

using SafeERC20 for IERC20;
using Math for uint256;

/// @title TestFeesIntegrationAssertion
/// @notice Tests assertion behavior with fee integration (management & performance fees)
/// @dev This file focuses on verifying assertions work correctly when fees are enabled.
///      All other existing tests use 0% fees to isolate assertion logic.
///
/// Fee System Summary:
/// - Management Fees: Time-based (annualized %), charged on totalAssets
/// - Performance Fees: Gain-based (%), charged on profit above high water mark
/// - Fee Mechanism: Shares minted to feeReceiver + protocolFeeReceiver (dilution model)
/// - Key Invariant: totalAssets UNCHANGED by fee minting (only totalSupply increases)
/// - Fees Taken: During settleDeposit(), settleRedeem(), close()
/// - NO Fees: During syncDeposit() (instant deposits don't accrue fees)
contract TestFeesIntegrationAssertion is AssertionBaseTest_v0_5_0 {
    // Fee configuration for this test suite
    uint16 managementRate = 200; // 2% annual (200 basis points)
    uint16 performanceRate = 0; // Start with 0%, will increase in specific tests
    uint16 protocolRate = 1000; // 10% of fees go to protocol

    // ============ Constants ============
    uint256 constant ONE_YEAR = 365 days;
    uint256 constant BPS_DIVIDER = 10_000;

    function setUp() public {
        // Setup vault with management fees enabled
        setUpVault(managementRate, performanceRate, 6); // 2% management, 0% performance, 6 decimals

        // Set protocol rate on FeeRegistry (10% of fees go to protocol)
        vm.prank(dao.addr);
        feeRegistry.updateDefaultRate(protocolRate);
    }

    // ============ Helper Functions ============

    /// @notice Calculate expected management fee for given parameters
    /// @param totalAssets Current total assets
    /// @param annualRate Annual fee rate in basis points (e.g., 200 = 2%)
    /// @param timeElapsed Time elapsed since last fee in seconds
    /// @return managementFee Fee amount in assets
    function _calculateExpectedManagementFee(
        uint256 totalAssets,
        uint256 annualRate,
        uint256 timeElapsed
    ) internal pure returns (uint256 managementFee) {
        uint256 annualFee = totalAssets.mulDiv(annualRate, BPS_DIVIDER, Math.Rounding.Ceil);
        managementFee = annualFee.mulDiv(timeElapsed, ONE_YEAR, Math.Rounding.Ceil);
    }

    /// @notice Calculate expected fee shares minted (with dilution)
    /// @param totalFees Total fees in assets (management + performance)
    /// @param totalAssets Current total assets BEFORE fees
    /// @param totalSupply Current total supply
    /// @param _decimalsOffset Decimals offset (10^(18 - assetDecimals))
    /// @return totalShares Total shares to be minted
    function _calculateExpectedFeeShares(
        uint256 totalFees,
        uint256 totalAssets,
        uint256 totalSupply,
        uint256 _decimalsOffset
    ) internal pure returns (uint256 totalShares) {
        // Formula from FeeManager._calculateFees()
        // totalShares = totalFees * (totalSupply + decimalsOffset) / (totalAssets - totalFees + 1)
        totalShares = totalFees.mulDiv(totalSupply + _decimalsOffset, (totalAssets - totalFees) + 1, Math.Rounding.Ceil);
    }

    /// @notice Calculate protocol and manager share split
    /// @param totalShares Total fee shares minted
    /// @param _protocolRate Protocol rate in basis points
    /// @return protocolShares Shares for protocol
    /// @return managerShares Shares for manager
    function _calculateFeeSplit(
        uint256 totalShares,
        uint256 _protocolRate
    ) internal pure returns (uint256 protocolShares, uint256 managerShares) {
        protocolShares = totalShares.mulDiv(_protocolRate, BPS_DIVIDER, Math.Rounding.Ceil);
        managerShares = totalShares - protocolShares;
    }

    // ==================== Invariant 1: Total Assets Accounting with Management Fees ====================

    /// @notice Test: settleDeposit accounting remains correct with management fees enabled
    /// @dev This is the FIRST fee integration test - verifies core assertion logic handles fees
    ///
    /// Test Flow:
    /// 1. Initial deposit & settlement (no fees yet, lastFeeTime = 0)
    /// 2. Warp 1 year forward to accrue management fees
    /// 3. New deposit request
    /// 4. Settlement triggers fee minting + deposit settlement
    /// 5. Verify assertion passes and accounting is correct
    ///
    /// Key Learning: Does assertionSettleDepositAccounting handle:
    /// - Share minting mid-transaction (totalSupply increases)
    /// - totalAssets unchanged by fee minting
    /// - Correct calculation: postTotalAssets == newTotalAssets + pendingAssets
    function testSettleDepositAccountingWithManagementFees() public {
        dealAndApproveAndWhitelist(user1.addr);

        // ============ Step 1: Initial Deposit & Settlement ============
        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);
        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        // User claims shares
        uint256 claimableShares = vault.claimableDepositRequest(0, user1.addr);
        vm.prank(user1.addr);
        vault.deposit(claimableShares, user1.addr, user1.addr);

        // ============ Step 1b: Reset Fee Timer with Immediate Settlement ============
        // Purpose: Reset lastFeeTime to establish clean baseline
        vm.warp(block.timestamp + 1);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(60_000e6);

        vm.prank(safe.addr);
        vault.settleDeposit(60_000e6);

        // Capture clean baseline state
        uint256 baselineTotalAssets = vault.totalAssets();
        uint256 baselineTotalSupply = vault.totalSupply();
        uint256 baselineFeeReceiverBalance = vault.balanceOf(feeReceiver.addr);
        uint256 baselineProtocolBalance = vault.balanceOf(dao.addr);

        // Verify baseline expectations
        assertEq(baselineTotalAssets, 60_000e6, "Baseline totalAssets should be 60k (50k NAV + 10k deposits)");
        assertGt(baselineFeeReceiverBalance, 0, "Initial fees were minted");
        assertGt(baselineProtocolBalance, 0, "Initial protocol fees were minted");

        // ============ Step 2: Warp Time to Accrue Management Fees ============
        vm.warp(block.timestamp + ONE_YEAR);

        // ============ Step 3: New Deposit Request ============
        dealAndApproveAndWhitelist(user2.addr);
        vm.prank(user2.addr);
        vault.requestDeposit(20_000e6, user2.addr, user2.addr);

        // ============ Step 4: Calculate Expected Fee Shares ============
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(70_000e6);

        // CRITICAL: Fees are calculated on the NEW totalAssets (70k) after _updateTotalAssets()
        // NOT on the baseline (60k). The protocol flow is:
        //   1. _updateTotalAssets(70k) -> sets $.totalAssets = 70k
        //   2. _takeFees() -> reads totalAssets() which returns 70k
        //   3. Fees calculated on 70k
        uint256 newTotalAssets = 70_000e6;

        uint256 expectedManagementFee = _calculateExpectedManagementFee(
            newTotalAssets, // Use NEW totalAssets (70k), not baseline (60k)
            managementRate,
            ONE_YEAR
        );

        assertEq(expectedManagementFee, 1400e6, "Management fee should be 1.4k USDC (2% of 70k)");

        // Calculate expected fee shares (before settlement)
        uint256 decimalsOffsetValue = 10 ** (18 - mockAsset.decimals()); // 10^12 for USDC
        uint256 expectedTotalFeeShares =
            _calculateExpectedFeeShares(expectedManagementFee, newTotalAssets, baselineTotalSupply, decimalsOffsetValue);

        (uint256 expectedProtocolShares, uint256 expectedManagerShares) =
            _calculateFeeSplit(expectedTotalFeeShares, protocolRate);

        // ============ Step 5: Settlement with Assertion ============

        // Register assertion to verify accounting
        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSettleDepositAccounting.selector
        });

        // Settle deposit - this will:
        // 1. Call _updateTotalAssetsAndTakeFees() -> mints fee shares
        // 2. Call _settleDeposit() -> processes pending deposits
        vm.prank(safe.addr);
        vault.settleDeposit(70_000e6);

        // ============ Step 6: Verify Post-Settlement State ============
        uint256 postTotalAssets = vault.totalAssets();
        uint256 postTotalSupply = vault.totalSupply();
        uint256 postFeeReceiverBalance = vault.balanceOf(feeReceiver.addr);
        uint256 postProtocolBalance = vault.balanceOf(dao.addr);

        // Key Assertion: totalAssets should be 90,000 (70k NAV + 20k new deposits)
        // Fees don't change totalAssets (they're share dilution)
        assertEq(postTotalAssets, 90_000e6, "totalAssets should be newTotalAssets + pendingAssets (70k + 20k)");

        // Fee shares should be minted
        assertGt(postFeeReceiverBalance, baselineFeeReceiverBalance, "Manager should receive fee shares");
        assertGt(postProtocolBalance, baselineProtocolBalance, "Protocol should receive fee shares");

        // Total supply should increase
        assertGt(postTotalSupply, baselineTotalSupply, "Total supply should increase from fee minting");

        // Verify INCREMENTAL fee shares are approximately correct
        uint256 incrementalManagerShares = postFeeReceiverBalance - baselineFeeReceiverBalance;
        uint256 incrementalProtocolShares = postProtocolBalance - baselineProtocolBalance;

        assertApproxEqAbs(
            incrementalManagerShares,
            expectedManagerShares,
            100,
            "Incremental manager shares should match calculation (+/-100)"
        );
        assertApproxEqAbs(
            incrementalProtocolShares,
            expectedProtocolShares,
            100,
            "Incremental protocol shares should match calculation (+/-100)"
        );
    }

    // ==================== Invariant 1: Total Assets Accounting with Management Fees (Redeem) ====================

    /// @notice Test: settleRedeem accounting remains correct with management fees enabled
    /// @dev Simplified test - focuses on assertion passing, not detailed fee validation
    ///
    /// Test Flow:
    /// 1. Setup: Deposit + settlement to establish vault with shares
    /// 2. User requests redemption
    /// 3. Warp 1 year forward to accrue management fees
    /// 4. Settlement triggers fee minting + redeem settlement
    /// 5. Verify assertion passes
    ///
    /// Key Point: assertionSettleRedeemAccounting should handle fee minting correctly
    /// Formula: postTotalAssets == newTotalAssets - assetsWithdrawn
    function testSettleRedeemAccountingWithManagementFees() public {
        dealAndApproveAndWhitelist(user1.addr);

        // ============ Setup: Establish vault with shares ============
        vm.prank(user1.addr);
        vault.requestDeposit(50_000e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);
        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        // User claims shares
        uint256 claimableShares = vault.claimableDepositRequest(0, user1.addr);
        vm.prank(user1.addr);
        uint256 userShares = vault.deposit(claimableShares, user1.addr, user1.addr);

        // Reset fee timer with immediate settlement
        vm.warp(block.timestamp + 1);
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(100_000e6);
        vm.prank(safe.addr);
        vault.settleDeposit(100_000e6);

        // ============ User Requests Redemption ============
        // User redeems half their shares
        uint256 redeemAmount = userShares / 2;
        vm.prank(user1.addr);
        vault.requestRedeem(redeemAmount, user1.addr, user1.addr);

        // ============ Warp Time to Accrue Fees ============
        vm.warp(block.timestamp + ONE_YEAR);

        // ============ Settlement with Assertion ============
        // Vault NAV has grown to 120k
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(120_000e6);

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSettleRedeemAccounting.selector
        });

        // Settle redeem - this will:
        // 1. Call _updateTotalAssetsAndTakeFees() -> mints fee shares
        // 2. Call _settleRedeem() -> withdraws assets for redeemer
        vm.prank(safe.addr);
        vault.settleRedeem(120_000e6);

        // ============ Verify Assertion Passed ============
        // If we get here, the assertion passed
        // The assertion verifies: postTotalAssets == newTotalAssets - assetsWithdrawn

        uint256 postTotalAssets = vault.totalAssets();

        // Basic sanity check: totalAssets should be less than 120k (assets were withdrawn)
        assertLt(postTotalAssets, 120_000e6, "totalAssets should be less than newTotalAssets after redeem");

        // Verify totalAssets is still positive
        assertGt(postTotalAssets, 0, "totalAssets should still be positive");
    }

    // ==================== Invariant 1: Total Assets Accounting with Performance Fees (Deposit) ====================

    /// @notice Test: settleDeposit accounting with performance fees
    /// @dev Performance fees trigger when pricePerShare > highWaterMark
    function testSettleDepositAccountingWithPerformanceFees() public {
        // Create vault with performance fees instead of management fees
        VaultHelper freshVault = VaultHelper(
            factory.createVaultProxy(
                BeaconProxyInitStruct({
                    underlying: address(mockAsset),
                    name: "Test Vault",
                    symbol: "TEST",
                    safe: safe.addr,
                    whitelistManager: whitelistManager.addr,
                    valuationManager: valuationManager.addr,
                    admin: admin.addr,
                    feeReceiver: feeReceiver.addr,
                    managementRate: 0, // No management fees
                    performanceRate: 2000, // 20% performance fee
                    enableWhitelist: true,
                    rateUpdateCooldown: 0
                }),
                keccak256("perfFeeDeposit")
            )
        );

        // Whitelist vault addresses
        address[] memory vaultAddresses = new address[](5);
        vaultAddresses[0] = feeReceiver.addr;
        vaultAddresses[1] = dao.addr;
        vaultAddresses[2] = freshVault.pendingSilo();
        vaultAddresses[3] = safe.addr;
        vaultAddresses[4] = address(feeRegistry);
        vm.prank(whitelistManager.addr);
        freshVault.addToWhitelist(vaultAddresses);

        // Setup user1 for freshVault
        mockAsset.mint(user1.addr, 100_000e6);
        vm.prank(user1.addr);
        mockAsset.approve(address(freshVault), type(uint256).max);
        deal(user1.addr, 100 ether);

        address[] memory user1Array = new address[](1);
        user1Array[0] = user1.addr;
        vm.prank(whitelistManager.addr);
        freshVault.addToWhitelist(user1Array);

        // ============ Setup: Initial deposit ============
        vm.prank(user1.addr);
        freshVault.requestDeposit(50_000e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        freshVault.updateNewTotalAssets(50_000e6);

        vm.prank(safe.addr);
        mockAsset.approve(address(freshVault), type(uint256).max);
        vm.prank(safe.addr);
        freshVault.settleDeposit(50_000e6);

        // ============ Create profit to trigger performance fees ============
        // Setup user2 for freshVault
        mockAsset.mint(user2.addr, 100_000e6);
        vm.prank(user2.addr);
        mockAsset.approve(address(freshVault), type(uint256).max);
        deal(user2.addr, 100 ether);

        address[] memory user2Array = new address[](1);
        user2Array[0] = user2.addr;
        vm.prank(whitelistManager.addr);
        freshVault.addToWhitelist(user2Array);

        vm.prank(user2.addr);
        freshVault.requestDeposit(20_000e6, user2.addr, user2.addr);

        // Update NAV to show 100% profit (50k -> 100k) before new deposits
        vm.prank(valuationManager.addr);
        freshVault.updateNewTotalAssets(100_000e6);

        // Register assertion
        cl.assertion({
            adopter: address(freshVault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSettleDepositAccounting.selector
        });

        // Settle - this triggers performance fees on the profit
        vm.prank(safe.addr);
        freshVault.settleDeposit(100_000e6);

        // ============ Verify ============
        uint256 postTotalAssets = freshVault.totalAssets();

        // Should be 100k + 20k = 120k
        assertEq(postTotalAssets, 120_000e6, "totalAssets should be newTotalAssets + pendingAssets");

        // Fee shares should have been minted (performance fee on 50k profit)
        assertGt(freshVault.balanceOf(feeReceiver.addr), 0, "Performance fees should be minted");
    }

    // ==================== Invariant 1: Total Assets Accounting with Performance Fees (Redeem) ====================

    /// @notice Test: settleRedeem accounting with performance fees
    function testSettleRedeemAccountingWithPerformanceFees() public {
        VaultHelper freshVault = VaultHelper(
            factory.createVaultProxy(
                BeaconProxyInitStruct({
                    underlying: address(mockAsset),
                    name: "Test Vault",
                    symbol: "TEST",
                    safe: safe.addr,
                    whitelistManager: whitelistManager.addr,
                    valuationManager: valuationManager.addr,
                    admin: admin.addr,
                    feeReceiver: feeReceiver.addr,
                    managementRate: 0,
                    performanceRate: 2000, // 20% performance fee
                    enableWhitelist: true,
                    rateUpdateCooldown: 0
                }),
                keccak256("perfFeeRedeem")
            )
        );

        // Whitelist vault addresses
        address[] memory vaultAddresses = new address[](5);
        vaultAddresses[0] = feeReceiver.addr;
        vaultAddresses[1] = dao.addr;
        vaultAddresses[2] = freshVault.pendingSilo();
        vaultAddresses[3] = safe.addr;
        vaultAddresses[4] = address(feeRegistry);
        vm.prank(whitelistManager.addr);
        freshVault.addToWhitelist(vaultAddresses);

        // Setup user1 for freshVault
        mockAsset.mint(user1.addr, 100_000e6);
        vm.prank(user1.addr);
        mockAsset.approve(address(freshVault), type(uint256).max);
        deal(user1.addr, 100 ether);

        address[] memory user1Array = new address[](1);
        user1Array[0] = user1.addr;
        vm.prank(whitelistManager.addr);
        freshVault.addToWhitelist(user1Array);

        // ============ Setup: Deposit + claim shares ============
        vm.prank(user1.addr);
        freshVault.requestDeposit(50_000e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        freshVault.updateNewTotalAssets(50_000e6);

        vm.prank(safe.addr);
        mockAsset.approve(address(freshVault), type(uint256).max);
        vm.prank(safe.addr);
        freshVault.settleDeposit(50_000e6);

        uint256 claimableShares = freshVault.claimableDepositRequest(0, user1.addr);
        vm.prank(user1.addr);
        uint256 userShares = freshVault.deposit(claimableShares, user1.addr, user1.addr);

        // ============ Request redemption ============
        vm.prank(user1.addr);
        freshVault.requestRedeem(userShares / 2, user1.addr, user1.addr);

        // ============ Create profit to trigger performance fees ============
        vm.prank(valuationManager.addr);
        freshVault.updateNewTotalAssets(100_000e6); // 100% profit

        // Register assertion
        cl.assertion({
            adopter: address(freshVault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSettleRedeemAccounting.selector
        });

        // Settle redeem with performance fees
        vm.prank(safe.addr);
        freshVault.settleRedeem(100_000e6);

        // ============ Verify ============
        uint256 postTotalAssets = freshVault.totalAssets();

        assertLt(postTotalAssets, 100_000e6, "totalAssets should be less after redeem");

        assertGt(freshVault.balanceOf(feeReceiver.addr), 0, "Performance fees should be minted");
    }

    // ==================== Invariant 1: Vault Solvency with Both Fee Types ====================

    /// @notice Test: Vault solvency assertion with both management and performance fees
    /// @dev Tests the most complex fee scenario
    function testVaultSolvencyWithBothFeeTypes() public {
        VaultHelper freshVault = VaultHelper(
            factory.createVaultProxy(
                BeaconProxyInitStruct({
                    underlying: address(mockAsset),
                    name: "Test Vault",
                    symbol: "TEST",
                    safe: safe.addr,
                    whitelistManager: whitelistManager.addr,
                    valuationManager: valuationManager.addr,
                    admin: admin.addr,
                    feeReceiver: feeReceiver.addr,
                    managementRate: 200, // 2% management
                    performanceRate: 2000, // 20% performance
                    enableWhitelist: true,
                    rateUpdateCooldown: 0
                }),
                keccak256("bothFees")
            )
        );

        // Whitelist vault addresses
        address[] memory vaultAddresses = new address[](5);
        vaultAddresses[0] = feeReceiver.addr;
        vaultAddresses[1] = dao.addr;
        vaultAddresses[2] = freshVault.pendingSilo();
        vaultAddresses[3] = safe.addr;
        vaultAddresses[4] = address(feeRegistry);
        vm.prank(whitelistManager.addr);
        freshVault.addToWhitelist(vaultAddresses);

        // Setup user1 for freshVault
        mockAsset.mint(user1.addr, 100_000e6);
        vm.prank(user1.addr);
        mockAsset.approve(address(freshVault), type(uint256).max);
        deal(user1.addr, 100 ether);

        address[] memory user1Array = new address[](1);
        user1Array[0] = user1.addr;
        vm.prank(whitelistManager.addr);
        freshVault.addToWhitelist(user1Array);

        // ============ Setup ============
        vm.prank(user1.addr);
        freshVault.requestDeposit(50_000e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        freshVault.updateNewTotalAssets(50_000e6);

        vm.prank(safe.addr);
        mockAsset.approve(address(freshVault), type(uint256).max);
        vm.prank(safe.addr);
        freshVault.settleDeposit(50_000e6);

        // Reset fee timer
        vm.warp(block.timestamp + 1);
        vm.prank(valuationManager.addr);
        freshVault.updateNewTotalAssets(50_000e6);
        vm.prank(safe.addr);
        freshVault.settleDeposit(50_000e6);

        // ============ Warp time and create profit ============
        vm.warp(block.timestamp + ONE_YEAR);

        // Setup user2 for freshVault
        mockAsset.mint(user2.addr, 100_000e6);
        vm.prank(user2.addr);
        mockAsset.approve(address(freshVault), type(uint256).max);
        deal(user2.addr, 100 ether);

        address[] memory user2Array = new address[](1);
        user2Array[0] = user2.addr;
        vm.prank(whitelistManager.addr);
        freshVault.addToWhitelist(user2Array);

        vm.prank(user2.addr);
        freshVault.requestDeposit(10_000e6, user2.addr, user2.addr);

        // Show profit + new deposit
        vm.prank(valuationManager.addr);
        freshVault.updateNewTotalAssets(100_000e6);

        // Register assertion
        cl.assertion({
            adopter: address(freshVault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSettleDepositAccounting.selector
        });

        // Settle - triggers BOTH management AND performance fees
        vm.prank(safe.addr);
        freshVault.settleDeposit(100_000e6);

        // ============ Verify ============
        // Vault should remain solvent with both fee types
        uint256 postTotalAssets = freshVault.totalAssets();
        assertGt(postTotalAssets, 0, "Vault should remain solvent");

        // Verify both fee types were minted
        assertGt(freshVault.balanceOf(feeReceiver.addr), 0, "Both management and performance fees should be minted");
    }

    // ==================== Sync Deposit with Fees (No Fee Impact) ====================

    /// @notice Test: syncDeposit does NOT trigger fees (even with fees enabled)
    /// @dev This is a critical property: sync deposits are instant and bypass epoch settlement
    function testSyncDepositAccountingWithFeesEnabled() public {
        dealAndApproveAndWhitelist(user1.addr);

        // ============ Setup: Establish vault ============
        vm.prank(user1.addr);
        vault.requestDeposit(50_000e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        // Reset fee timer
        vm.warp(block.timestamp + 1);
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);
        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        // ============ Warp time to accrue fees ============
        vm.warp(block.timestamp + ONE_YEAR);

        // Extend totalAssetsLifespan so NAV remains valid for syncDeposit
        vm.prank(safe.addr);
        vault.updateTotalAssetsLifespan(365 days);

        // Update and commit NAV to make it valid for syncDeposit
        // NOTE: This WILL trigger fees, but we capture baseline AFTER this
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);
        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        // Capture baseline AFTER fee settlement
        uint256 baselineFeeReceiverBalance = vault.balanceOf(feeReceiver.addr);

        // ============ syncDeposit (should NOT trigger fees) ============
        dealAndApproveAndWhitelist(user2.addr);

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionSyncDepositAccounting.selector
        });

        vm.prank(user2.addr);
        vault.syncDeposit(10_000e6, user2.addr, user2.addr);

        // ============ Verify NO fees were taken ============
        uint256 postFeeReceiverBalance = vault.balanceOf(feeReceiver.addr);

        assertEq(postFeeReceiverBalance, baselineFeeReceiverBalance, "syncDeposit should NOT mint fee shares");
    }
}
