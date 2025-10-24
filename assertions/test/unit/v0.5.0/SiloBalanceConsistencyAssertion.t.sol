// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SiloBalanceConsistencyAssertion} from "../../../src/SiloBalanceConsistencyAssertion.a.sol";
import {AssertionBaseTest_v0_5_0} from "../../AssertionBaseTest_v0_5_0.sol";

/// @title TestSiloBalanceConsistency
/// @notice Tests Invariant #3: Silo Balance Consistency for v0.5.0
/// @dev Tests cover:
///      - 3.A: Asset Balance Consistency (requestDeposit, settleDeposit, cancelRequestDeposit, syncDeposit)
///      - 3.B: Share Balance Consistency (requestRedeem, settleRedeem)
contract TestSiloBalanceConsistency is AssertionBaseTest_v0_5_0 {
    function setUp() public {
        setUpVault(0, 0, 6); // Zero fees, 6 decimals (USDC)
    }

    // ==================== Invariant 3.A: Asset Balance Consistency Tests ====================

    /// @notice Test: Silo asset balance increases after requestDeposit
    function testRequestDepositIncreasesSiloAssetBalance() public {
        dealAndApproveAndWhitelist(user1.addr);

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(SiloBalanceConsistencyAssertion).creationCode,
            fnSelector: SiloBalanceConsistencyAssertion.assertionRequestDepositSiloBalance.selector
        });

        // User requests deposit
        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);
    }

    /// @notice Test: Multiple users requesting deposits in same epoch
    function testRequestDepositMultipleUsers() public {
        dealAndApproveAndWhitelist(user1.addr);
        dealAndApproveAndWhitelist(user2.addr);

        // First user request
        cl.assertion({
            adopter: address(vault),
            createData: type(SiloBalanceConsistencyAssertion).creationCode,
            fnSelector: SiloBalanceConsistencyAssertion.assertionRequestDepositSiloBalance.selector
        });
        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);

        // Second user request
        cl.assertion({
            adopter: address(vault),
            createData: type(SiloBalanceConsistencyAssertion).creationCode,
            fnSelector: SiloBalanceConsistencyAssertion.assertionRequestDepositSiloBalance.selector
        });
        vm.prank(user2.addr);
        vault.requestDeposit(20_000e6, user2.addr, user2.addr);
    }

    /// @notice Test: Silo asset balance decreases after settleDeposit
    function testSettleDepositDecreasesSiloAssetBalance() public {
        dealAndApproveAndWhitelist(user1.addr);

        // User requests deposit
        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);

        // Valuation manager updates NAV
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        // Safe approves vault
        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(SiloBalanceConsistencyAssertion).creationCode,
            fnSelector: SiloBalanceConsistencyAssertion.assertionSettleDepositSiloBalance.selector
        });

        // Settle deposit (assets move from Silo to Safe)
        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);
    }

    /// @notice Test: New requests remain in Silo after settlement
    function testSettleDepositWithNewRequests() public {
        dealAndApproveAndWhitelist(user1.addr);
        dealAndApproveAndWhitelist(user2.addr);

        // User1 requests deposit
        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);

        // Valuation manager updates NAV (increments epoch)
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        // User2 requests deposit AFTER valuation (new epoch)
        vm.prank(user2.addr);
        vault.requestDeposit(20_000e6, user2.addr, user2.addr);

        // Safe approves vault
        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        // Register assertion (should only settle user1's deposit, user2's stays in Silo)
        cl.assertion({
            adopter: address(vault),
            createData: type(SiloBalanceConsistencyAssertion).creationCode,
            fnSelector: SiloBalanceConsistencyAssertion.assertionSettleDepositSiloBalance.selector
        });

        // Settle deposit
        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);
    }

    /// @notice Test: Silo asset balance decreases after cancelRequestDeposit
    function testCancelRequestDepositDecreasesSiloBalance() public {
        dealAndApproveAndWhitelist(user1.addr);

        // User requests deposit
        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);

        // Register assertion
        cl.assertion({
            adopter: address(vault),
            createData: type(SiloBalanceConsistencyAssertion).creationCode,
            fnSelector: SiloBalanceConsistencyAssertion.assertionCancelRequestDepositSiloBalance.selector
        });

        // User cancels deposit (assets refunded from Silo)
        vm.prank(user1.addr);
        vault.cancelRequestDeposit();
    }

    /// @notice Test: syncDeposit does NOT affect Silo (v0.5.0)
    function testSyncDepositDoesNotAffectSilo() public {
        dealAndApproveAndWhitelist(user1.addr);

        // Enable sync mode
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);
        vm.prank(safe.addr);
        vault.updateTotalAssetsLifespan(1000);
        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);
        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        require(vault.isTotalAssetsValid(), "NAV should be valid");

        // Register assertion (Silo should be unchanged, Safe should increase)
        cl.assertion({
            adopter: address(vault),
            createData: type(SiloBalanceConsistencyAssertion).creationCode,
            fnSelector: SiloBalanceConsistencyAssertion.assertionSyncDepositSiloIsolation.selector
        });

        // Sync deposit (assets go directly to Safe, bypass Silo)
        vm.prank(user1.addr);
        vault.syncDeposit(10_000e6, user1.addr, address(0));
    }

    // ==================== Invariant 3.B: Share Balance Consistency Tests ====================

    /// @notice Test: Silo share balance increases after requestRedeem
    function testRequestRedeemIncreasesSiloShareBalance() public {
        // Setup: Give user1 some shares first via deposit flow
        dealAndApproveAndWhitelist(user1.addr);
        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);
        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);
        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        // User claims their shares (using deposit function to claim) - BEFORE assertion registration
        uint256 claimable = vault.claimableDepositRequest(0, user1.addr);
        vm.prank(user1.addr);
        vault.deposit(claimable, user1.addr, user1.addr);

        // User approves vault to transfer shares for requestRedeem
        uint256 userShares = vault.balanceOf(user1.addr);
        vm.prank(user1.addr);
        vault.approve(address(vault), userShares);

        // Register assertion AFTER claiming shares and approval
        cl.assertion({
            adopter: address(vault),
            createData: type(SiloBalanceConsistencyAssertion).creationCode,
            fnSelector: SiloBalanceConsistencyAssertion.assertionRequestRedeemSiloBalance.selector
        });

        // Now user requests redeem
        vm.prank(user1.addr);
        vault.requestRedeem(userShares, user1.addr, user1.addr);
    }

    /// @notice Test: Silo share balance decreases after settleRedeem
    function testSettleRedeemDecreasesSiloShareBalance() public {
        // Setup: User deposits, gets shares, then requests redeem
        dealAndApproveAndWhitelist(user1.addr);
        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);
        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);
        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        // User claims their shares
        uint256 claimable = vault.claimableDepositRequest(0, user1.addr);
        vm.prank(user1.addr);
        vault.deposit(claimable, user1.addr, user1.addr);

        // User approves vault to transfer shares for requestRedeem
        uint256 userShares = vault.balanceOf(user1.addr);
        vm.prank(user1.addr);
        vault.approve(address(vault), userShares);

        // User requests redeem
        vm.prank(user1.addr);
        vault.requestRedeem(userShares, user1.addr, user1.addr);

        // Valuation manager updates NAV
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        // Safe funds vault for redemptions
        ensureSafeHasAssets(20_000e6);

        // Register assertion (shares burned from Silo)
        cl.assertion({
            adopter: address(vault),
            createData: type(SiloBalanceConsistencyAssertion).creationCode,
            fnSelector: SiloBalanceConsistencyAssertion.assertionSettleRedeemSiloBalance.selector
        });

        // Settle redeem
        vm.prank(safe.addr);
        vault.settleRedeem(50_000e6);
    }

    /// @notice Test: settleDeposit with no pending requests leaves Silo unchanged
    function testSettleDepositWithNoPending() public {
        // Setup: Initial deposit to set totalAssets
        dealAndApproveAndWhitelist(user1.addr);
        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);
        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);
        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        // Now try to settle again with no pending requests
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(60_000e6);

        cl.assertion({
            adopter: address(vault),
            createData: type(SiloBalanceConsistencyAssertion).creationCode,
            fnSelector: SiloBalanceConsistencyAssertion.assertionSettleDepositSiloBalance.selector
        });

        vm.prank(safe.addr);
        vault.settleDeposit(60_000e6);
    }

    /// @notice Test: settleRedeem with no pending requests leaves Silo unchanged
    function testSettleRedeemWithNoPending() public {
        // Setup: Initial deposit to have totalAssets
        dealAndApproveAndWhitelist(user1.addr);
        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);
        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);
        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        // Try to settle redeem with no pending requests
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(60_000e6);

        ensureSafeHasAssets(20_000e6);

        cl.assertion({
            adopter: address(vault),
            createData: type(SiloBalanceConsistencyAssertion).creationCode,
            fnSelector: SiloBalanceConsistencyAssertion.assertionSettleRedeemSiloBalance.selector
        });

        vm.prank(safe.addr);
        vault.settleRedeem(60_000e6);
    }

    // ============================================
    // Airdrop/Donation Scenario Tests
    // ============================================

    /// @notice Test: Airdrop assets to Silo after requestDeposit
    /// @dev Tests that extra assets in Silo don't break assertions
    function testAirdropToSiloAssets_AfterRequestDeposit() public {
        dealAndApproveAndWhitelist(user1.addr);

        // User makes deposit request - Silo gets 10k assets
        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);

        // Airdrop 5k assets directly to Silo (donation/airdrop scenario)
        address silo = vault.pendingSilo();
        mockAsset.mint(silo, 5000e6);

        // Now Silo has 15k but only 10k is from requests
        uint256 siloBalance = mockAsset.balanceOf(silo);
        assertEq(siloBalance, 15_000e6, "Silo should have 15k (10k request + 5k airdrop)");

        // Try to settle - assertion should tolerate the extra 5k
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(10_000e6);

        ensureSafeHasAssets(10_000e6);

        cl.assertion({
            adopter: address(vault),
            createData: type(SiloBalanceConsistencyAssertion).creationCode,
            fnSelector: SiloBalanceConsistencyAssertion.assertionSettleDepositSiloBalance.selector
        });

        vm.prank(safe.addr);
        vault.settleDeposit(10_000e6);

        // After settlement, verify Silo balance
        // The vault takes ALL assets from Silo during settlement, including airdrops
        uint256 siloBalanceAfter = mockAsset.balanceOf(silo);
        assertEq(siloBalanceAfter, 0, "Silo should be empty - vault takes all assets including airdrops");
    }

    /// @notice Test: Airdrop assets to Silo before settlement
    /// @dev Tests that airdrops don't interfere with accounting during settlement
    function testAirdropToSiloAssets_BeforeSettle() public {
        dealAndApproveAndWhitelist(user1.addr);

        // User makes deposit request
        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);

        // Prepare for settlement
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(10_000e6);

        // Airdrop 3k assets to Silo right before settlement
        address silo = vault.pendingSilo();
        mockAsset.mint(silo, 3000e6);

        ensureSafeHasAssets(10_000e6);

        cl.assertion({
            adopter: address(vault),
            createData: type(SiloBalanceConsistencyAssertion).creationCode,
            fnSelector: SiloBalanceConsistencyAssertion.assertionSettleDepositSiloBalance.selector
        });

        vm.prank(safe.addr);
        vault.settleDeposit(10_000e6);

        // Silo should have 3k remaining (the airdrop)
        uint256 siloBalanceAfter = mockAsset.balanceOf(silo);
        assertEq(siloBalanceAfter, 3000e6, "Silo should have 3k remaining from airdrop");
    }

    /// @notice Test: Donate shares to Silo after requestRedeem
    /// @dev Tests that extra shares in Silo don't break assertions
    function testAirdropToSiloShares_AfterRequestRedeem() public {
        // Setup: User needs shares to redeem
        dealAndApproveAndWhitelist(user1.addr);
        vm.prank(user1.addr);
        vault.requestDeposit(20_000e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(20_000e6);

        ensureSafeHasAssets(20_000e6);

        vm.prank(safe.addr);
        vault.settleDeposit(20_000e6);

        // User claims shares
        vm.prank(user1.addr);
        uint256 claimedShares = vault.deposit(20_000e6, user1.addr, user1.addr);

        // User requests redeem for half their shares
        vm.prank(user1.addr);
        vault.requestRedeem(claimedShares / 2, user1.addr, user1.addr);

        // Someone donates extra shares to Silo (airdrop scenario)
        address silo = vault.pendingSilo();
        vm.prank(user1.addr);
        vault.transfer(silo, claimedShares / 4);

        // Now Silo has more shares than just the redeem request
        uint256 siloShareBalance = vault.balanceOf(silo);
        assertGt(siloShareBalance, claimedShares / 2, "Silo should have extra donated shares");

        // Try to settle redeem - assertion should tolerate extra shares
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(20_000e6);

        ensureSafeHasAssets(10_000e6);

        cl.assertion({
            adopter: address(vault),
            createData: type(SiloBalanceConsistencyAssertion).creationCode,
            fnSelector: SiloBalanceConsistencyAssertion.assertionSettleRedeemSiloBalance.selector
        });

        vm.prank(safe.addr);
        vault.settleRedeem(20_000e6);
    }

    /// @notice Test: Donation to Safe does not affect Silo assertions
    /// @dev Verifies that airdrops to Safe don't interfere with Silo accounting
    function testDonationToSafe_DoesNotAffectSilo() public {
        dealAndApproveAndWhitelist(user1.addr);

        // User makes deposit request
        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);

        // Airdrop directly to Safe (not Silo)
        mockAsset.mint(safe.addr, 50_000e6);

        // Settle - Silo assertions should be unaffected by Safe airdrops
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(10_000e6);

        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        cl.assertion({
            adopter: address(vault),
            createData: type(SiloBalanceConsistencyAssertion).creationCode,
            fnSelector: SiloBalanceConsistencyAssertion.assertionSettleDepositSiloBalance.selector
        });

        vm.prank(safe.addr);
        vault.settleDeposit(10_000e6);

        // Verify Silo is empty after settlement
        address silo = vault.pendingSilo();
        uint256 siloBalance = mockAsset.balanceOf(silo);
        assertEq(siloBalance, 0, "Silo should be empty after settlement");
    }

    /// @notice Test: Airdrop happens in the same transaction as requestDeposit
    /// @dev Tests edge case where balance changes mid-transaction
    function testAirdropDuringRequestDeposit() public {
        dealAndApproveAndWhitelist(user1.addr);

        address silo = vault.pendingSilo();

        // Pre-airdrop some assets to Silo before any requests
        mockAsset.mint(silo, 2000e6);

        cl.assertion({
            adopter: address(vault),
            createData: type(SiloBalanceConsistencyAssertion).creationCode,
            fnSelector: SiloBalanceConsistencyAssertion.assertionRequestDepositSiloBalance.selector
        });

        // User makes deposit request - assertion should handle pre-existing Silo balance
        vm.prank(user1.addr);
        vault.requestDeposit(10_000e6, user1.addr, user1.addr);

        // Silo should have initial 2k + 10k from request
        uint256 siloBalance = mockAsset.balanceOf(silo);
        assertEq(siloBalance, 12_000e6, "Silo should have 12k total");
    }
}
