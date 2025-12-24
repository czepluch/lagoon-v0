// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SyncDepositModeAssertion_v0_5_0} from "../../../src/SyncDepositModeAssertion_v0.5.0.a.sol";
import {AssertionBaseTest_v0_5_0} from "../../AssertionBaseTest_v0_5_0.sol";

/// @title TestSyncDepositModeAssertion
/// @notice Tests Invariant #4: Synchronous Deposit Mode Integrity for v0.5.0
/// @dev Tests cover all sub-invariants:
///      - 4.A: Mode Mutual Exclusivity (sync vs async mode)
///      - 4.B: Synchronous Deposit Accounting (totalAssets, Safe balance, shares)
///      - 4.C: Epoch System Isolation (depositEpochId, Silo balance)
///      - 4.D: NAV Expiration State Machine (totalAssetsExpiration updates)
contract TestSyncDepositModeAssertion is AssertionBaseTest_v0_5_0 {
    // ============ Assertion Contract ============
    SyncDepositModeAssertion_v0_5_0 public assertion;

    function setUp() public {
        setUpVault(0, 0, 6); // Zero fees, 6 decimals (USDC)

        // Enable sync deposit mode by setting totalAssetsLifespan (1000 seconds)
        enableSyncMode(1000);

        // Settle to set expiration timestamp
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(0);
        vm.prank(safe.addr);
        vault.settleDeposit(0);

        // Deploy assertion contract
        assertion = new SyncDepositModeAssertion_v0_5_0();
    }

    // ==================== Invariant 4.A: Mode Mutual Exclusivity Tests ====================

    /// @notice Test: syncDeposit works when NAV is valid (sync mode)
    /// @dev This tests the happy path for Invariant 4.A - sync mode should be allowed
    function testSyncDepositModeWhenNAVValid() public {
        dealAndApproveAndWhitelist(user1.addr);

        // Verify NAV is valid (sync mode enabled)
        assertTrue(vault.isTotalAssetsValid(), "NAV should be valid for sync mode");

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionSyncDepositMode.selector
        });

        // Execute syncDeposit - should pass
        vm.prank(user1.addr);
        uint256 shares = vault.syncDeposit(10_000e6, user1.addr, address(0));

        assertGt(shares, 0, "Shares should be minted");
    }

    /// @notice Test: requestDeposit works when NAV is expired (async mode)
    /// @dev This tests the happy path for Invariant 4.A - async mode should be allowed
    function testAsyncDepositModeWhenNAVExpired() public {
        dealAndApproveAndWhitelist(user1.addr);

        // Expire NAV
        vm.warp(block.timestamp + 1001);
        assertFalse(vault.isTotalAssetsValid(), "NAV should be expired");

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionAsyncDepositMode.selector
        });

        // Execute requestDeposit - should pass
        vm.prank(user1.addr);
        uint256 requestId = vault.requestDeposit(10_000e6, user1.addr, user1.addr);

        assertGt(requestId, 0, "Request ID should be assigned");
    }

    // ==================== Invariant 4.B: Synchronous Deposit Accounting Tests ====================

    /// @notice Test: syncDeposit correctly updates totalAssets, Safe balance, and shares
    /// @dev Verifies all accounting changes are correct after syncDeposit
    function testSyncDepositAccounting() public {
        dealAndApproveAndWhitelist(user1.addr);

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionSyncDepositAccounting.selector
        });

        // Execute syncDeposit
        vm.prank(user1.addr);
        uint256 shares = vault.syncDeposit(50_000e6, user1.addr, address(0));

        // Verify shares were minted
        assertEq(vault.balanceOf(user1.addr), shares, "User should receive shares");
        assertGt(shares, 0, "Shares should be minted");
    }

    /// @notice Test: syncDeposit accounting with multiple deposits
    /// @dev Verifies accounting remains correct across multiple syncDeposit calls
    function testSyncDepositAccountingMultipleDeposits() public {
        dealAndApproveAndWhitelist(user1.addr);
        dealAndApproveAndWhitelist(user2.addr);

        // First deposit
        cl.assertion({
            adopter: address(vault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionSyncDepositAccounting.selector
        });

        vm.prank(user1.addr);
        uint256 shares1 = vault.syncDeposit(30_000e6, user1.addr, address(0));

        // Second deposit
        cl.assertion({
            adopter: address(vault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionSyncDepositAccounting.selector
        });

        vm.prank(user2.addr);
        uint256 shares2 = vault.syncDeposit(20_000e6, user2.addr, address(0));

        // Verify both users have correct shares
        assertEq(vault.balanceOf(user1.addr), shares1);
        assertEq(vault.balanceOf(user2.addr), shares2);
    }

    /// @notice Test: syncDeposit accounting with different receiver
    /// @dev Verifies shares go to receiver, not sender
    function testSyncDepositAccountingDifferentReceiver() public {
        dealAndApproveAndWhitelist(user1.addr);
        dealAndApproveAndWhitelist(user2.addr);

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionSyncDepositAccounting.selector
        });

        // user1 deposits, user2 receives shares
        vm.prank(user1.addr);
        uint256 shares = vault.syncDeposit(10_000e6, user2.addr, address(0));

        // Verify user2 received shares, not user1
        assertEq(vault.balanceOf(user2.addr), shares, "Receiver should get shares");
        assertEq(vault.balanceOf(user1.addr), 0, "Sender should not get shares");
    }

    // ==================== Invariant 4.C: Epoch System Isolation Tests ====================

    /// @notice Test: syncDeposit does not increment depositEpochId
    /// @dev Verifies epoch system remains unchanged by syncDeposit
    function testEpochIsolationDepositEpochUnchanged() public {
        dealAndApproveAndWhitelist(user1.addr);

        uint40 preDepositEpochId = vault.depositEpochId();

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionEpochIsolation.selector
        });

        // Execute syncDeposit
        vm.prank(user1.addr);
        vault.syncDeposit(10_000e6, user1.addr, address(0));

        // Verify depositEpochId unchanged
        assertEq(vault.depositEpochId(), preDepositEpochId, "depositEpochId should not change");
    }

    /// @notice Test: syncDeposit does not affect Silo balance
    /// @dev Verifies assets go to Safe, not Silo
    function testEpochIsolationSiloBalanceUnchanged() public {
        dealAndApproveAndWhitelist(user1.addr);

        address silo = vault.pendingSilo();
        uint256 preSiloBalance = mockAsset.balanceOf(silo);

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionEpochIsolation.selector
        });

        // Execute syncDeposit
        vm.prank(user1.addr);
        vault.syncDeposit(10_000e6, user1.addr, address(0));

        // Verify Silo balance unchanged
        assertEq(mockAsset.balanceOf(silo), preSiloBalance, "Silo balance should not change");
    }

    /// @notice Test: syncDeposit isolation with multiple deposits
    /// @dev Verifies epoch isolation holds across multiple syncDeposit calls
    function testEpochIsolationMultipleSyncDeposits() public {
        dealAndApproveAndWhitelist(user1.addr);
        dealAndApproveAndWhitelist(user2.addr);

        uint40 preDepositEpochId = vault.depositEpochId();
        address silo = vault.pendingSilo();
        uint256 preSiloBalance = mockAsset.balanceOf(silo);

        // First deposit
        cl.assertion({
            adopter: address(vault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionEpochIsolation.selector
        });
        vm.prank(user1.addr);
        vault.syncDeposit(10_000e6, user1.addr, address(0));

        // Second deposit
        cl.assertion({
            adopter: address(vault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionEpochIsolation.selector
        });
        vm.prank(user2.addr);
        vault.syncDeposit(15_000e6, user2.addr, address(0));

        // Verify epoch system still isolated
        assertEq(vault.depositEpochId(), preDepositEpochId);
        assertEq(mockAsset.balanceOf(silo), preSiloBalance);
    }

    // ==================== Invariant 4.D: NAV Expiration State Machine Tests ====================

    /// @notice Test: settleDeposit updates totalAssetsExpiration correctly
    /// @dev Verifies expiration = block.timestamp + lifespan after settlement
    function testNAVExpirationUpdateAfterSettleDeposit() public {
        // Setup: Create pending deposit
        dealAndApproveAndWhitelist(user1.addr);

        // Expire NAV first
        vm.warp(block.timestamp + 1001);
        vm.prank(user1.addr);
        vault.requestDeposit(50_000e6, user1.addr, user1.addr);

        // Update NAV
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        // Prepare assets for settlement
        ensureSafeHasAssets(50_000e6);

        // Register assertion for settleDeposit
        cl.assertion({
            adopter: address(vault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionNAVExpirationUpdate.selector
        });

        // Settle deposit
        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        // Verify expiration is updated correctly
        uint256 expectedExpiration = block.timestamp + vault.totalAssetsLifespan();
        assertEq(vault.totalAssetsExpiration(), expectedExpiration, "Expiration should match formula");
    }

    /// @notice Test: settleRedeem updates totalAssetsExpiration correctly
    /// @dev Verifies expiration formula works for redeem settlements too
    function testNAVExpirationUpdateAfterSettleRedeem() public {
        // Setup: Complete deposit cycle first
        dealAndApproveAndWhitelist(user1.addr);
        vm.prank(user1.addr);
        vault.syncDeposit(50_000e6, user1.addr, address(0));

        // Request redeem
        address pendingSilo = vault.pendingSilo();
        vm.prank(user1.addr);
        vault.approve(pendingSilo, type(uint256).max);

        // Expire NAV
        vm.warp(block.timestamp + 1001);

        uint256 sharesToRedeem = vault.balanceOf(user1.addr);
        vm.prank(user1.addr);
        vault.requestRedeem(sharesToRedeem, user1.addr, user1.addr);

        // Update NAV - Note: During redemption, assets stay in Safe
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        // Ensure Safe has approved vault to handle transfers for claimRedeem
        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        // Register assertion for settleRedeem
        cl.assertion({
            adopter: address(vault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionNAVExpirationUpdate.selector
        });

        // Settle redeem
        vm.prank(safe.addr);
        vault.settleRedeem(50_000e6);

        // Verify expiration updated
        uint256 expectedExpiration = block.timestamp + vault.totalAssetsLifespan();
        assertEq(vault.totalAssetsExpiration(), expectedExpiration);
    }

    /// @notice Test: NAV expiration update with zero lifespan (sync mode disabled)
    /// @dev When lifespan = 0, assertion should not enforce expiration updates
    function testNAVExpirationWithZeroLifespan() public {
        // Disable sync mode by setting lifespan to 0
        disableSyncMode();

        // Expire NAV manually since lifespan = 0 means NAV is always expired
        expireNAV();

        // Setup deposit
        dealAndApproveAndWhitelist(user1.addr);
        vm.prank(user1.addr);
        vault.requestDeposit(50_000e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        // Prepare assets for settlement
        ensureSafeHasAssets(50_000e6);

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionNAVExpirationUpdate.selector
        });

        // Settle - should pass even without expiration update check (lifespan = 0)
        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);
    }

    /// @notice Test: NAV expiration update across multiple settlements
    /// @dev Verifies expiration updates correctly after each settlement
    function testNAVExpirationMultipleSettlements() public {
        // First settlement
        dealAndApproveAndWhitelist(user1.addr);
        vm.warp(block.timestamp + 1001);
        vm.prank(user1.addr);
        vault.requestDeposit(30_000e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(30_000e6);

        // Prepare assets for settlement
        ensureSafeHasAssets(30_000e6);

        cl.assertion({
            adopter: address(vault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionNAVExpirationUpdate.selector
        });

        vm.prank(safe.addr);
        vault.settleDeposit(30_000e6);

        uint256 firstExpiration = vault.totalAssetsExpiration();
        uint256 expectedFirst = block.timestamp + vault.totalAssetsLifespan();
        assertEq(firstExpiration, expectedFirst, "First expiration should be correct");

        // Second settlement after warp
        vm.warp(block.timestamp + 500);
        dealAndApproveAndWhitelist(user2.addr);
        vm.warp(block.timestamp + 501); // Expire again
        vm.prank(user2.addr);
        vault.requestDeposit(20_000e6, user2.addr, user2.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        // Prepare assets for second settlement
        ensureSafeHasAssets(50_000e6);

        cl.assertion({
            adopter: address(vault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionNAVExpirationUpdate.selector
        });

        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        uint256 secondExpiration = vault.totalAssetsExpiration();
        uint256 expectedSecond = block.timestamp + vault.totalAssetsLifespan();
        assertEq(secondExpiration, expectedSecond, "Second expiration should be updated");
        assertGt(secondExpiration, firstExpiration, "Expiration should increase over time");
    }
}
