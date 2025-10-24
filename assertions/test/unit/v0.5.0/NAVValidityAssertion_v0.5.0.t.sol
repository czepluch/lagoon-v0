// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {NAVValidityAssertion_v0_5_0} from "../../../src/NAVValidityAssertion_v0.5.0.a.sol";
import {AssertionBaseTest_v0_5_0} from "../../AssertionBaseTest_v0_5_0.sol";

/// @title TestNAVValidityAssertion
/// @notice Tests Invariant #5: NAV Validity and Expiration Lifecycle for v0.5.0
/// @dev Tests cover all sub-invariants:
///      - 5.A: NAV Validity Consistency (isTotalAssetsValid matches totalAssetsExpiration)
///      - 5.B: NAV Update Access Control (updateNewTotalAssets blocked when valid)
///      - 5.C: Expiration Timestamp After Settlement (expiration set correctly)
///      - 5.D: Lifespan Update Verification (event emitted, state updated)
///      - 5.E: Manual Expiration Verification (expireTotalAssets works correctly)
contract TestNAVValidityAssertion is AssertionBaseTest_v0_5_0 {
    function setUp() public {
        setUpVaultWithFactory(0, 0, 6); // Factory-based setup, zero fees, 6 decimals (USDC)
    }

    // ============================================================================
    // GROUP A: VALIDITY CONSISTENCY (3 tests)
    // ============================================================================

    /// @notice Test: isTotalAssetsValid() consistent when NAV is expired (lifespan = 0)
    function testValidityConsistentWhenExpired() public {
        // Setup: Default state has lifespan = 0 (async-only mode)
        // No settlement needed, NAV should be expired by default

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(NAVValidityAssertion_v0_5_0).creationCode,
            fnSelector: NAVValidityAssertion_v0_5_0.assertionIsTotalAssetsValidConsistency.selector
        });

        // Action: Update NAV (allowed when expired)
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        // Assertion verifies: isTotalAssetsValid() == false and totalAssetsExpiration == 0
    }

    /// @notice Test: isTotalAssetsValid() consistent when NAV is valid
    function testValidityConsistentWhenValid() public {
        // Setup: Set lifespan and settle to make NAV valid
        enableSyncMode(1000);

        dealAndApproveAndWhitelist(user1.addr);
        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(NAVValidityAssertion_v0_5_0).creationCode,
            fnSelector: NAVValidityAssertion_v0_5_0.assertionIsTotalAssetsValidConsistency.selector
        });

        // Action: Settle deposit (sets expiration = block.timestamp + 1000)
        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        // Assertion verifies: isTotalAssetsValid() == true and expiration > block.timestamp
    }

    /// @notice Test: isTotalAssetsValid() consistent after expiration time passes
    function testValidityConsistentAfterExpiration() public {
        // Setup: Set short lifespan and settle
        enableSyncMode(1);

        dealAndApproveAndWhitelist(user1.addr);
        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        // Warp past expiration
        vm.warp(block.timestamp + 2);

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(NAVValidityAssertion_v0_5_0).creationCode,
            fnSelector: NAVValidityAssertion_v0_5_0.assertionIsTotalAssetsValidConsistency.selector
        });

        // Action: Update NAV after expiration
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(60_000e6);

        // Assertion verifies: isTotalAssetsValid() == false even though expiration > 0
    }

    // ============================================================================
    // GROUP B: ACCESS CONTROL (2 tests)
    // ============================================================================

    /// @notice Test: updateNewTotalAssets() blocked when NAV is valid
    function testNAVUpdateBlockedWhenValid() public {
        // Setup: Set lifespan and settle to make NAV valid
        enableSyncMode(1000);

        dealAndApproveAndWhitelist(user1.addr);
        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        // NAV is now valid for 1000 seconds
        // Safe must expire NAV first before valuation manager can update

        expireNAV();

        // Register assertion (checks NAV was expired before update)
        cl.assertion({
            adopter: address(vault),
            createData: type(NAVValidityAssertion_v0_5_0).creationCode,
            fnSelector: NAVValidityAssertion_v0_5_0.assertionNAVUpdateAccessControl.selector
        });

        // Now valuation manager can update NAV
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(60_000e6);

        // Assertion verifies: NAV was expired before updateNewTotalAssets was called
    }

    /// @notice Test: updateNewTotalAssets() allowed when NAV is expired
    function testNAVUpdateAllowedWhenExpired() public {
        // Setup: Default state has lifespan = 0 (NAV always expired)

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(NAVValidityAssertion_v0_5_0).creationCode,
            fnSelector: NAVValidityAssertion_v0_5_0.assertionNAVUpdateAccessControl.selector
        });

        // Action: Update NAV (allowed when expired)
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        // Assertion verifies: NAV was expired before update
    }

    // ============================================================================
    // GROUP C: EXPIRATION AFTER SETTLEMENT (3 tests)
    // ============================================================================

    /// @notice Test: totalAssetsExpiration set correctly after settleDeposit
    function testExpirationSetAfterSettleDeposit() public {
        // Setup: Set lifespan = 1000
        enableSyncMode(1000);

        dealAndApproveAndWhitelist(user1.addr);
        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(NAVValidityAssertion_v0_5_0).creationCode,
            fnSelector: NAVValidityAssertion_v0_5_0.assertionExpirationSetAfterSettlement.selector
        });

        // Action: Settle deposit
        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        // Assertion verifies: totalAssetsExpiration == block.timestamp + 1000
    }

    /// @notice Test: totalAssetsExpiration set correctly after settleRedeem
    function testExpirationSetAfterSettleRedeem() public {
        // Setup: Deposit, get shares, then request redeem
        enableSyncMode(1000);

        dealAndApproveAndWhitelist(user1.addr);
        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        // User claims shares
        uint256 claimable = vault.claimableDepositRequest(0, user1.addr);
        vm.prank(user1.addr);
        vault.deposit(claimable, user1.addr, user1.addr);

        // User requests redeem
        uint256 userShares = vault.balanceOf(user1.addr);
        vm.prank(user1.addr);
        vault.approve(address(vault), userShares);
        vm.prank(user1.addr);
        vault.requestRedeem(userShares, user1.addr, user1.addr);

        // Expire NAV so we can update it
        expireNAV();

        // Update NAV for redeem settlement
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        // Safe funds vault
        ensureSafeHasAssets(20_000e6);

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(NAVValidityAssertion_v0_5_0).creationCode,
            fnSelector: NAVValidityAssertion_v0_5_0.assertionExpirationSetAfterSettlement.selector
        });

        // Action: Settle redeem
        vm.prank(safe.addr);
        vault.settleRedeem(50_000e6);

        // Assertion verifies: totalAssetsExpiration == block.timestamp + 1000
    }

    /// @notice Test: totalAssetsExpiration remains 0 when lifespan is 0
    function testExpirationZeroWhenLifespanZero() public {
        // Setup: Lifespan = 0 (default async-only mode)
        dealAndApproveAndWhitelist(user1.addr);
        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(NAVValidityAssertion_v0_5_0).creationCode,
            fnSelector: NAVValidityAssertion_v0_5_0.assertionExpirationSetAfterSettlement.selector
        });

        // Action: Settle deposit with lifespan = 0
        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        // Assertion verifies: totalAssetsExpiration == 0 (not block.timestamp + 0)
    }

    // ============================================================================
    // GROUP D: LIFESPAN UPDATES (2 tests)
    // ============================================================================

    /// @notice Test: Lifespan update from 0 to non-zero
    function testLifespanUpdateFromZeroToNonZero() public {
        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(NAVValidityAssertion_v0_5_0).creationCode,
            fnSelector: NAVValidityAssertion_v0_5_0.assertionLifespanUpdate.selector
        });

        // Action: Safe sets lifespan to 1000
        enableSyncMode(1000);

        // Assertion verifies:
        // - TotalAssetsLifespanUpdated(0, 1000) event emitted
        // - totalAssetsLifespan == 1000
    }

    /// @notice Test: Lifespan update from non-zero to zero (disable sync mode)
    function testLifespanUpdateFromNonZeroToZero() public {
        // Setup: Set lifespan to 1000 first
        enableSyncMode(1000);

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(NAVValidityAssertion_v0_5_0).creationCode,
            fnSelector: NAVValidityAssertion_v0_5_0.assertionLifespanUpdate.selector
        });

        // Action: Safe disables sync mode by setting lifespan to 0
        disableSyncMode();

        // Assertion verifies:
        // - TotalAssetsLifespanUpdated(1000, 0) event emitted
        // - totalAssetsLifespan == 0
    }

    // ============================================================================
    // GROUP E: MANUAL EXPIRATION (2 tests)
    // ============================================================================

    /// @notice Test: Manual expiration forces async mode
    function testManualExpirationForcesAsyncMode() public {
        // Setup: Set lifespan and settle to make NAV valid
        enableSyncMode(1000);

        dealAndApproveAndWhitelist(user1.addr);
        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        // NAV is now valid for 1000 seconds

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(NAVValidityAssertion_v0_5_0).creationCode,
            fnSelector: NAVValidityAssertion_v0_5_0.assertionManualExpiration.selector
        });

        // Action: Safe manually expires NAV
        expireNAV();

        // Assertion verifies:
        // - totalAssetsExpiration == 0
        // - isTotalAssetsValid() == false
    }

    /// @notice Test: Manual expiration enables NAV update
    function testManualExpirationEnablesNAVUpdate() public {
        // Setup: Set lifespan and settle to make NAV valid
        enableSyncMode(1000);

        dealAndApproveAndWhitelist(user1.addr);
        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        // NAV is now valid - updateNewTotalAssets would fail

        // Safe manually expires NAV
        expireNAV();

        // Register assertion (verifies NAV was expired before update)
        cl.assertion({
            adopter: address(vault),
            createData: type(NAVValidityAssertion_v0_5_0).creationCode,
            fnSelector: NAVValidityAssertion_v0_5_0.assertionNAVUpdateAccessControl.selector
        });

        // Action: Valuation manager can now update NAV
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(60_000e6);

        // Assertion verifies: NAV was expired before update (access control enforced)
    }
}
