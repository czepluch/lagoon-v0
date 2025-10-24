// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EpochInvariantsAssertion} from "../../../src/EpochInvariantsAssertion.a.sol";
import {TotalAssetsAccountingAssertion_v0_5_0} from "../../../src/TotalAssetsAccountingAssertion_v0.5.0.a.sol";
import {AssertionBaseTest_v0_5_0} from "../../AssertionBaseTest_v0_5_0.sol";

/// @title TestTotalAssetsAccountingAssertion
/// @notice Tests Invariant #1: Total Assets Accounting Integrity for v0.5.0
/// @dev Tests cover:
///      - 1.A: Accounting Conservation (settleDeposit, settleRedeem)
///      - 1.B: Solvency (vault balance covers claimable redemptions)
contract TestTotalAssetsAccountingAssertion is AssertionBaseTest_v0_5_0 {
    function setUp() public {
        setUpVault(0, 0, 6); // Zero fees, 6 decimals (USDC)
    }

    // ==================== Invariant 1.A: Accounting Conservation Tests ====================

    /// @notice Test: totalAssets increases correctly after single settleDeposit
    function testSettleDepositAccountingSingle() public {
        dealAndApproveAndWhitelist(user1.addr);

        // User requests deposit (assets go to Silo)
        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);

        // Valuation manager updates NAV and increments epochs
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        // Setup: Safe approves vault (must be BEFORE cl.assertion)
        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSettleDepositAccounting.selector
        });

        // Safe settles deposit - assertion should pass
        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);
    }

    /// @notice Test: totalAssets increases correctly after multiple sequential settlements
    function testSettleDepositAccountingMultiple() public {
        dealAndApproveAndWhitelist(user1.addr);
        dealAndApproveAndWhitelist(user2.addr);

        // First deposit cycle
        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSettleDepositAccounting.selector
        });

        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        // Second deposit cycle
        vm.prank(user2.addr);
        vault.requestDeposit(20_000e6, user2.addr, user2.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(70_000e6);

        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSettleDepositAccounting.selector
        });

        vm.prank(safe.addr);
        vault.settleDeposit(70_000e6);
    }

    /// @notice Test: totalAssets decreases correctly after single settleRedeem
    function testSettleRedeemAccountingSingle() public {
        // Setup: deposit and mint shares
        dealAndApproveAndWhitelist(user1.addr);

        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        // Claim shares (deposit for v0.5.0)
        uint256 claimableShares = vault.claimableDepositRequest(0, user1.addr);
        vm.prank(user1.addr);
        vault.deposit(claimableShares, user1.addr, user1.addr);

        // Request redeem
        uint256 userShares = vault.balanceOf(user1.addr);
        vm.prank(user1.addr);
        vault.requestRedeem(userShares, user1.addr, user1.addr);

        // Trigger epoch increment
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(60_000e6);

        // Setup: Safe gets assets and approves vault (must be BEFORE cl.assertion)
        ensureSafeHasAssets(vault.totalAssets());

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSettleRedeemAccounting.selector
        });

        // Settle redeem - assertion should pass
        vm.prank(safe.addr);
        vault.settleRedeem(60_000e6);
    }

    /// @notice Test: totalAssets decreases correctly after multiple sequential redeem settlements
    function testSettleRedeemAccountingMultiple() public {
        // Setup: deposit and mint shares for two users
        dealAndApproveAndWhitelist(user1.addr);
        dealAndApproveAndWhitelist(user2.addr);

        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);
        vm.prank(user2.addr);
        vault.requestDeposit(20_000e6, user2.addr, user2.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);
        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        uint256 claimableShares1 = vault.claimableDepositRequest(0, user1.addr);
        vm.prank(user1.addr);
        vault.deposit(claimableShares1, user1.addr, user1.addr);

        uint256 claimableShares2 = vault.claimableDepositRequest(0, user2.addr);
        vm.prank(user2.addr);
        vault.deposit(claimableShares2, user2.addr, user2.addr);

        // First redeem cycle (user1)
        uint256 user1Shares = vault.balanceOf(user1.addr);
        vm.prank(user1.addr);
        vault.requestRedeem(user1Shares, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(60_000e6);

        ensureSafeHasAssets(vault.totalAssets());

        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSettleRedeemAccounting.selector
        });

        vm.prank(safe.addr);
        vault.settleRedeem(60_000e6);

        // Second redeem cycle (user2)
        uint256 user2Shares = vault.balanceOf(user2.addr);
        vm.prank(user2.addr);
        vault.requestRedeem(user2Shares, user2.addr, user2.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(40_000e6);

        ensureSafeHasAssets(vault.totalAssets());

        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSettleRedeemAccounting.selector
        });

        vm.prank(safe.addr);
        vault.settleRedeem(40_000e6);
    }

    /// @notice Test: Handles zero pending deposits gracefully (no event, no state change)
    function testSettleDepositWithZeroPending() public {
        // No pending deposits

        // Trigger epoch increment
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSettleDepositAccounting.selector
        });

        // Settle with zero pending - assertion should pass (no event, no state change)
        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);
    }

    /// @notice Test: Handles zero pending redeems gracefully (no event, no state change)
    function testSettleRedeemWithZeroPending() public {
        // Setup: deposit and mint shares
        dealAndApproveAndWhitelist(user1.addr);

        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);
        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        // No pending redeems

        // Trigger epoch increment
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(60_000e6);

        ensureSafeHasAssets(vault.totalAssets());

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSettleRedeemAccounting.selector
        });

        // Settle with zero pending - assertion should pass (no event, no state change)
        vm.prank(safe.addr);
        vault.settleRedeem(60_000e6);
    }

    // ==================== Batched Operations Tests ====================

    /// @notice Test: Multiple requestDeposit calls in same transaction
    /// @dev Verifies Silo balance and pending deposits accumulate correctly
    function testBatchedMultipleRequestDeposits() public {
        dealAndApproveAndWhitelist(user1.addr);

        // Multiple requestDeposit calls in one transaction
        vm.startPrank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);
        vault.requestDeposit(5000e6, user1.addr, user1.addr);
        vault.requestDeposit(3000e6, user1.addr, user1.addr);
        vm.stopPrank();

        // Verify assets went to Silo
        address silo = vault.pendingSilo();
        assertEq(mockAsset.balanceOf(silo), 18_000e6, "Silo should have all deposited assets");

        // Settle and verify accounting
        // Vault is empty (totalAssets = 0), so NAV before settlement is 0
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

        // Verify totalAssets matches
        assertEq(vault.totalAssets(), 18_000e6, "Total assets should match all deposits");
    }

    /// @notice Test: settleDeposit followed by new requestDeposit in same transaction
    /// @dev Verifies accounting when settlement and new request happen together
    function testBatchedSettleAndNewRequest() public {
        dealAndApproveAndWhitelist(user1.addr);
        dealAndApproveAndWhitelist(user2.addr);

        // User1 makes initial request
        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);

        // Vault is empty (totalAssets = 0), so NAV before settlement is 0
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(0);

        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSettleDepositAccounting.selector
        });

        // Settle user1's deposit, then user2 makes new request (simulated batched tx)
        vm.prank(safe.addr);
        vault.settleDeposit(0);

        vm.prank(user2.addr);
        vault.requestDeposit(5000e6, user2.addr, user2.addr);

        // Verify accounting: totalAssets = 10k, Silo = 5k
        assertEq(vault.totalAssets(), 10_000e6, "Total assets from first settlement");
        assertEq(mockAsset.balanceOf(vault.pendingSilo()), 5000e6, "New deposit in Silo");
    }

    // ==================== Invariant 1.B: Solvency Tests ====================

    /// @notice Test: Vault balance increases correctly after settleRedeem (solvency)
    function testVaultSolvencyAfterRedeem() public {
        // Setup: deposit and mint shares
        dealAndApproveAndWhitelist(user1.addr);

        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);
        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        uint256 claimableShares = vault.claimableDepositRequest(0, user1.addr);
        vm.prank(user1.addr);
        vault.deposit(claimableShares, user1.addr, user1.addr);

        // Request redeem
        uint256 userShares = vault.balanceOf(user1.addr);
        vm.prank(user1.addr);
        vault.requestRedeem(userShares, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(60_000e6);

        ensureSafeHasAssets(vault.totalAssets());

        // Register solvency assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionVaultSolvency.selector
        });

        // Settle redeem - vault should receive assets from Safe
        vm.prank(safe.addr);
        vault.settleRedeem(60_000e6);
    }

    /// @notice Test: Vault solvency maintained across multiple redemptions
    function testVaultSolvencyMultipleRedemptions() public {
        // Setup: deposit and mint shares for two users
        dealAndApproveAndWhitelist(user1.addr);
        dealAndApproveAndWhitelist(user2.addr);

        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);
        vm.prank(user2.addr);
        vault.requestDeposit(20_000e6, user2.addr, user2.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);
        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        uint256 claimableShares1 = vault.claimableDepositRequest(0, user1.addr);
        vm.prank(user1.addr);
        vault.deposit(claimableShares1, user1.addr, user1.addr);

        uint256 claimableShares2 = vault.claimableDepositRequest(0, user2.addr);
        vm.prank(user2.addr);
        vault.deposit(claimableShares2, user2.addr, user2.addr);

        // First redeem
        uint256 user1Shares = vault.balanceOf(user1.addr);
        vm.prank(user1.addr);
        vault.requestRedeem(user1Shares, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(60_000e6);

        ensureSafeHasAssets(vault.totalAssets());

        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionVaultSolvency.selector
        });

        vm.prank(safe.addr);
        vault.settleRedeem(60_000e6);

        // Second redeem
        uint256 user2Shares = vault.balanceOf(user2.addr);
        vm.prank(user2.addr);
        vault.requestRedeem(user2Shares, user2.addr, user2.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(40_000e6);

        ensureSafeHasAssets(vault.totalAssets());

        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionVaultSolvency.selector
        });

        vm.prank(safe.addr);
        vault.settleRedeem(40_000e6);
    }

    /// @notice Test: Solvency assertion handles zero pending redeems
    function testVaultSolvencyWithZeroPending() public {
        // Setup: deposit and mint shares
        dealAndApproveAndWhitelist(user1.addr);

        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);
        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        // No pending redeems

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(60_000e6);

        ensureSafeHasAssets(vault.totalAssets());

        // Register solvency assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionVaultSolvency.selector
        });

        // Settle with zero pending - vault balance shouldn't change
        vm.prank(safe.addr);
        vault.settleRedeem(60_000e6);
    }

    // ==================== Invariant 1.A: Sync Deposit Accounting Tests ====================

    /// @notice Test: totalAssets increases correctly after single syncDeposit
    function testSyncDepositAccountingSingle() public {
        dealAndApproveAndWhitelist(user1.addr);

        // Set NAV and enable sync mode
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);
        vm.prank(safe.addr);
        vault.updateTotalAssetsLifespan(1000);
        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6); // This sets expiration = block.timestamp + 1000

        // Verify NAV is valid (sync mode active)
        require(vault.isTotalAssetsValid(), "NAV should be valid");

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSyncDepositAccounting.selector
        });

        // User does sync deposit - assertion should pass
        vm.prank(user1.addr);
        vault.syncDeposit(10_000e6, user1.addr, address(0));
    }

    /// @notice Test: Verifies assets go to Safe, not Silo
    function testSyncDepositRoutingToSafe() public {
        dealAndApproveAndWhitelist(user1.addr);

        // Set NAV and enable sync mode
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);
        vm.prank(safe.addr);
        vault.updateTotalAssetsLifespan(1000);
        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        require(vault.isTotalAssetsValid(), "NAV should be valid");

        // Check balances before
        uint256 preSafeBalance = mockAsset.balanceOf(safe.addr);
        uint256 preSiloBalance = mockAsset.balanceOf(vault.pendingSilo());

        // Register assertion (checks Safe balance increase)
        cl.assertion({
            adopter: address(vault),
            createData: type(TotalAssetsAccountingAssertion_v0_5_0).creationCode,
            fnSelector: TotalAssetsAccountingAssertion_v0_5_0.assertionSyncDepositAccounting.selector
        });

        // Sync deposit
        vm.prank(user1.addr);
        vault.syncDeposit(10_000e6, user1.addr, address(0));

        // Verify routing: Safe increased, Silo unchanged
        assertEq(mockAsset.balanceOf(safe.addr), preSafeBalance + 10_000e6, "Safe should receive assets");
        assertEq(mockAsset.balanceOf(vault.pendingSilo()), preSiloBalance, "Silo should be unchanged");
    }

    // ==================== Invariant 2.4: Sync Deposit Epoch Isolation Tests ====================

    /// @notice Test: syncDeposit does NOT change depositEpochId (from EpochInvariantsAssertion)
    function testSyncDepositEpochIsolationSingle() public {
        dealAndApproveAndWhitelist(user1.addr);

        // Set NAV and enable sync mode
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);
        vm.prank(safe.addr);
        vault.updateTotalAssetsLifespan(1000);
        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        require(vault.isTotalAssetsValid(), "NAV should be valid");

        uint40 preDepositEpochId = vault.depositEpochId();
        uint40 preRedeemEpochId = vault.redeemEpochId();

        // Register EpochInvariantsAssertion
        cl.assertion({
            adopter: address(vault),
            createData: type(EpochInvariantsAssertion).creationCode,
            fnSelector: EpochInvariantsAssertion.assertionSyncDepositIsolation.selector
        });

        // Sync deposit - assertion should pass (epochs unchanged)
        vm.prank(user1.addr);
        vault.syncDeposit(10_000e6, user1.addr, address(0));

        // Verify epochs didn't change
        assertEq(vault.depositEpochId(), preDepositEpochId, "depositEpochId should not change");
        assertEq(vault.redeemEpochId(), preRedeemEpochId, "redeemEpochId should not change");
    }
}
