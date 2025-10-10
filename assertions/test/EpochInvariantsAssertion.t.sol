// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EpochInvariantsAssertion} from "../src/EpochInvariantsAssertion.a.sol";
import {AssertionBaseTest} from "./AssertionBaseTest.sol";

/// @title EpochInvariantsAssertion Happy Path Tests
/// @notice Tests all epoch-related invariants against real v0.4.0 Vault contracts
/// @dev Covers Invariant #2: Epoch Settlement Ordering and Claimability
///      - #2.1 Epoch Parity (deposit odd, redeem even)
///      - #2.2 Settlement Ordering (lastSettled ≤ current)
///      - #2.3 Epoch Increments (only 0 or 2)
contract TestEpochInvariantsAssertion is AssertionBaseTest {
    EpochInvariantsAssertion public assertion;

    function setUp() public {
        setUpVault(0, 0, 0);
        assertion = new EpochInvariantsAssertion();
    }

    // ==================== Invariant #2.1: Epoch Parity Tests ====================

    /// @notice Test: Epoch parity holds after vault initialization
    /// @dev Initial state should be depositEpochId = 1 (odd), redeemEpochId = 2 (even)
    function testEpochParityAfterInitialization() public {
        assertEq(vault.depositEpochId(), 1, "Initial deposit epoch should be 1");
        assertEq(vault.redeemEpochId(), 2, "Initial redeem epoch should be 2");

        cl.assertion({
            adopter: address(vault),
            createData: type(EpochInvariantsAssertion).creationCode,
            fnSelector: EpochInvariantsAssertion.assertionEpochParity.selector
        });

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(1000e6);

        assertEq(vault.depositEpochId(), 1);
        assertEq(vault.redeemEpochId(), 2);
    }

    /// @notice Test: Epoch parity after updateNewTotalAssets increments epochs
    function testEpochParityAfterUpdateNewTotalAssets() public {
        dealAndApproveAndWhitelist(user1.addr);
        vm.prank(user1.addr);
        vault.requestDeposit(50_000e6, user1.addr, user1.addr);

        assertEq(vault.depositEpochId(), 1);
        assertEq(vault.redeemEpochId(), 2);

        cl.assertion({
            adopter: address(vault),
            createData: type(EpochInvariantsAssertion).creationCode,
            fnSelector: EpochInvariantsAssertion.assertionEpochParity.selector
        });

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        assertEq(vault.depositEpochId(), 3, "Deposit epoch should increment to 3");
        assertEq(vault.redeemEpochId(), 2, "Redeem epoch should remain at 2");
    }

    /// @notice Test: Epoch parity with pending redeem requests
    function testEpochParityAfterUpdateWithPendingRedeem() public {
        // Setup: Complete deposit cycle to get shares
        dealAndApproveAndWhitelist(user1.addr);
        vm.prank(user1.addr);
        vault.requestDeposit(50_000e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        uint256 totalAssets = vault.newTotalAssets();
        mockAsset.mint(safe.addr, totalAssets);
        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);
        vm.prank(safe.addr);
        vault.settleDeposit(totalAssets);

        vm.prank(user1.addr);
        vault.deposit(50_000e6, user1.addr);

        // Request redemption
        address pendingSilo = vault.pendingSilo();
        vm.prank(user1.addr);
        vault.approve(pendingSilo, type(uint256).max);

        uint256 sharesToRedeem = vault.balanceOf(user1.addr);
        vm.prank(user1.addr);
        vault.requestRedeem(sharesToRedeem, user1.addr, user1.addr);

        assertEq(vault.depositEpochId(), 3);
        assertEq(vault.redeemEpochId(), 2);

        cl.assertion({
            adopter: address(vault),
            createData: type(EpochInvariantsAssertion).creationCode,
            fnSelector: EpochInvariantsAssertion.assertionEpochParity.selector
        });

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        assertEq(vault.depositEpochId(), 3, "Deposit epoch should remain 3");
        assertEq(vault.redeemEpochId(), 4, "Redeem epoch should increment to 4");
    }

    /// @notice Test: Epoch parity when both deposits and redeems are pending
    function testEpochParityWithBothPending() public {
        // Setup initial deposit and get shares
        dealAndApproveAndWhitelist(user1.addr);
        vm.prank(user1.addr);
        vault.requestDeposit(50_000e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        uint256 totalAssets = vault.newTotalAssets();
        mockAsset.mint(safe.addr, totalAssets);
        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);
        vm.prank(safe.addr);
        vault.settleDeposit(totalAssets);

        vm.prank(user1.addr);
        vault.deposit(50_000e6, user1.addr);

        address pendingSilo = vault.pendingSilo();
        vm.prank(user1.addr);
        vault.approve(pendingSilo, type(uint256).max);

        // Create both pending deposit and redeem
        dealAndApproveAndWhitelist(user2.addr);
        vm.prank(user2.addr);
        vault.requestDeposit(30_000e6, user2.addr, user2.addr);

        uint256 sharesToRedeem = vault.balanceOf(user1.addr);
        vm.prank(user1.addr);
        vault.requestRedeem(sharesToRedeem, user1.addr, user1.addr);

        assertEq(vault.depositEpochId(), 3);
        assertEq(vault.redeemEpochId(), 2);

        cl.assertion({
            adopter: address(vault),
            createData: type(EpochInvariantsAssertion).creationCode,
            fnSelector: EpochInvariantsAssertion.assertionEpochParity.selector
        });

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(80_000e6);

        assertEq(vault.depositEpochId(), 5, "Deposit epoch should increment to 5");
        assertEq(vault.redeemEpochId(), 4, "Redeem epoch should increment to 4");
    }

    // ==================== Invariant #2.2: Settlement Ordering Tests ====================

    /// @notice Test: Settlement ordering after first deposit settlement
    function testSettlementOrderingAfterFirstDeposit() public {
        dealAndApproveAndWhitelist(user1.addr);
        vm.prank(user1.addr);
        vault.requestDeposit(50_000e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        mockAsset.mint(safe.addr, 50_000e6);
        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        cl.assertion({
            adopter: address(vault),
            createData: type(EpochInvariantsAssertion).creationCode,
            fnSelector: EpochInvariantsAssertion.assertionSettlementOrdering.selector
        });

        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        assertEq(vault.depositEpochId(), 3);
    }

    /// @notice Test: Settlement ordering after redeem settlement
    function testSettlementOrderingAfterRedeem() public {
        // Setup: complete deposit cycle
        dealAndApproveAndWhitelist(user1.addr);
        vm.prank(user1.addr);
        vault.requestDeposit(50_000e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        mockAsset.mint(safe.addr, 50_000e6);
        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);
        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        vm.prank(user1.addr);
        vault.deposit(50_000e6, user1.addr);

        // Request redeem
        uint256 sharesToRedeem = vault.balanceOf(user1.addr);
        vm.prank(user1.addr);
        vault.requestRedeem(sharesToRedeem, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(100_000e6);

        cl.assertion({
            adopter: address(vault),
            createData: type(EpochInvariantsAssertion).creationCode,
            fnSelector: EpochInvariantsAssertion.assertionSettlementOrdering.selector
        });

        vm.prank(safe.addr);
        vault.settleRedeem(100_000e6);
    }

    /// @notice Test: Settlement ordering across multiple settlement cycles
    function testSettlementOrderingMultipleEpochs() public {
        // First cycle
        dealAndApproveAndWhitelist(user1.addr);
        vm.prank(user1.addr);
        vault.requestDeposit(50_000e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        mockAsset.mint(safe.addr, 50_000e6);
        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        cl.assertion({
            adopter: address(vault),
            createData: type(EpochInvariantsAssertion).creationCode,
            fnSelector: EpochInvariantsAssertion.assertionSettlementOrdering.selector
        });
        vm.prank(safe.addr);
        vault.settleDeposit(50_000e6);

        // Second cycle
        dealAndApproveAndWhitelist(user2.addr);
        vm.prank(user2.addr);
        vault.requestDeposit(30_000e6, user2.addr, user2.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(80_000e6);

        mockAsset.mint(safe.addr, 30_000e6);
        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);

        cl.assertion({
            adopter: address(vault),
            createData: type(EpochInvariantsAssertion).creationCode,
            fnSelector: EpochInvariantsAssertion.assertionSettlementOrdering.selector
        });
        vm.prank(safe.addr);
        vault.settleDeposit(80_000e6);
    }

    // ==================== Invariant #2.3: Epoch Increments Tests ====================

    /// @notice Test: Epochs increment by 0 when no pending requests
    function testEpochIncrementsZeroWhenNoPending() public {
        assertEq(vault.depositEpochId(), 1);
        assertEq(vault.redeemEpochId(), 2);

        cl.assertion({
            adopter: address(vault),
            createData: type(EpochInvariantsAssertion).creationCode,
            fnSelector: EpochInvariantsAssertion.assertionEpochIncrements.selector
        });

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(1000e6);

        assertEq(vault.depositEpochId(), 1, "Should remain 1 (increment by 0)");
        assertEq(vault.redeemEpochId(), 2, "Should remain 2 (increment by 0)");
    }

    /// @notice Test: Deposit epoch increments by 2 when pending deposits exist
    function testEpochIncrementsDepositByTwo() public {
        dealAndApproveAndWhitelist(user1.addr);
        vm.prank(user1.addr);
        vault.requestDeposit(50_000e6, user1.addr, user1.addr);

        assertEq(vault.depositEpochId(), 1);

        cl.assertion({
            adopter: address(vault),
            createData: type(EpochInvariantsAssertion).creationCode,
            fnSelector: EpochInvariantsAssertion.assertionEpochIncrements.selector
        });

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        assertEq(vault.depositEpochId(), 3, "Should increment by 2 (1 -> 3)");
        assertEq(vault.redeemEpochId(), 2, "Should remain 2 (increment by 0)");
    }

    /// @notice Test: Redeem epoch increments by 2 when pending redeems exist
    function testEpochIncrementsRedeemByTwo() public {
        // Setup: get shares
        dealAndApproveAndWhitelist(user1.addr);
        vm.prank(user1.addr);
        vault.requestDeposit(50_000e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        uint256 totalAssets = vault.newTotalAssets();
        mockAsset.mint(safe.addr, totalAssets);
        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);
        vm.prank(safe.addr);
        vault.settleDeposit(totalAssets);

        vm.prank(user1.addr);
        vault.deposit(50_000e6, user1.addr);

        // Request redeem
        address pendingSilo = vault.pendingSilo();
        vm.prank(user1.addr);
        vault.approve(pendingSilo, type(uint256).max);

        uint256 sharesToRedeem = vault.balanceOf(user1.addr);
        vm.prank(user1.addr);
        vault.requestRedeem(sharesToRedeem, user1.addr, user1.addr);

        assertEq(vault.redeemEpochId(), 2);

        cl.assertion({
            adopter: address(vault),
            createData: type(EpochInvariantsAssertion).creationCode,
            fnSelector: EpochInvariantsAssertion.assertionEpochIncrements.selector
        });

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        assertEq(vault.depositEpochId(), 3, "Should remain 3 (increment by 0)");
        assertEq(vault.redeemEpochId(), 4, "Should increment by 2 (2 -> 4)");
    }

    /// @notice Test: Both epochs increment by 2 when both have pending requests
    function testEpochIncrementsBothByTwo() public {
        // Setup: get shares
        dealAndApproveAndWhitelist(user1.addr);
        vm.prank(user1.addr);
        vault.requestDeposit(50_000e6, user1.addr, user1.addr);

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(50_000e6);

        uint256 totalAssets = vault.newTotalAssets();
        mockAsset.mint(safe.addr, totalAssets);
        vm.prank(safe.addr);
        mockAsset.approve(address(vault), type(uint256).max);
        vm.prank(safe.addr);
        vault.settleDeposit(totalAssets);

        vm.prank(user1.addr);
        vault.deposit(50_000e6, user1.addr);

        address pendingSilo = vault.pendingSilo();
        vm.prank(user1.addr);
        vault.approve(pendingSilo, type(uint256).max);

        // Create both pending
        dealAndApproveAndWhitelist(user2.addr);
        vm.prank(user2.addr);
        vault.requestDeposit(30_000e6, user2.addr, user2.addr);

        uint256 sharesToRedeem = vault.balanceOf(user1.addr);
        vm.prank(user1.addr);
        vault.requestRedeem(sharesToRedeem, user1.addr, user1.addr);

        assertEq(vault.depositEpochId(), 3);
        assertEq(vault.redeemEpochId(), 2);

        cl.assertion({
            adopter: address(vault),
            createData: type(EpochInvariantsAssertion).creationCode,
            fnSelector: EpochInvariantsAssertion.assertionEpochIncrements.selector
        });

        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(80_000e6);

        assertEq(vault.depositEpochId(), 5, "Should increment by 2 (3 -> 5)");
        assertEq(vault.redeemEpochId(), 4, "Should increment by 2 (2 -> 4)");
    }
}

/// @dev NOTE: Settlement ordering (Invariant #2.2) cannot have mock failure tests.
/// The settlement logic computes lastDepositEpochIdSettled = depositEpochId - 2 and
/// lastRedeemEpochIdSettled = redeemEpochId - 2, which mathematically guarantees the
/// invariant holds. Any violation would require a fundamental Solidity arithmetic bug.

/// @dev NOTE: Sync deposit isolation tests (Invariant #2.4 for v0.5.0) are in
/// TotalAssetsAccountingAssertion_v0.5.0.t.sol since they require v0.5.0 vault setup.
