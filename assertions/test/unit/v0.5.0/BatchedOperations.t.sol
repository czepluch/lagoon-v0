// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SyncDepositModeAssertion_v0_5_0} from "../../../src/SyncDepositModeAssertion_v0.5.0.a.sol";
import {AssertionBaseTest_v0_5_0} from "../../AssertionBaseTest_v0_5_0.sol";
import {VaultHelper} from "@test/v0.5.0/VaultHelper.sol";

/// @title BatchSyncDepositCaller
/// @notice Helper contract to batch multiple syncDeposit calls in a single transaction
contract BatchSyncDepositCaller {
    function batchSyncDeposits(
        VaultHelper vault,
        uint256[] calldata amounts,
        address receiver
    ) external returns (uint256[] memory shares) {
        shares = new uint256[](amounts.length);
        for (uint256 i = 0; i < amounts.length; i++) {
            shares[i] = vault.syncDeposit(amounts[i], receiver, address(0));
        }
    }
}

/// @title BatchRequestDepositCaller
/// @notice Helper contract to batch multiple requestDeposit calls in a single transaction
contract BatchRequestDepositCaller {
    function batchRequestDeposits(
        VaultHelper vault,
        uint256[] calldata amounts,
        address controller,
        address owner
    ) external returns (uint256[] memory requestIds) {
        requestIds = new uint256[](amounts.length);
        for (uint256 i = 0; i < amounts.length; i++) {
            requestIds[i] = vault.requestDeposit(amounts[i], controller, owner);
        }
    }
}

/// @title BatchClaimAndRedeemCaller
/// @notice Helper contract to claim shares then immediately request redeem in one transaction
/// @dev Realistic user flow: claim settled deposit shares, then immediately request to redeem them
contract BatchClaimAndRedeemCaller {
    /// @notice Claims shares from settled deposit, then requests to redeem them
    /// @param vault The vault to interact with
    /// @param claimAmount Amount of assets to claim (converts to shares)
    /// @param redeemShares Amount of shares to request redeem
    /// @param receiver Address to receive the claimed shares
    /// @param controller Address that owns the deposit request
    /// @return shares Shares received from claim
    /// @return requestId Redeem request ID
    function claimAndRedeem(
        VaultHelper vault,
        uint256 claimAmount,
        uint256 redeemShares,
        address receiver,
        address controller
    ) external returns (uint256 shares, uint256 requestId) {
        // First: claim shares from settled async deposit
        shares = vault.deposit(claimAmount, receiver, controller);

        // Second: immediately request to redeem those (or other) shares
        requestId = vault.requestRedeem(redeemShares, receiver, receiver);
    }
}

/// @title TestBatchedOperations
/// @notice Tests batched vault operations in single transactions
contract TestBatchedOperations is AssertionBaseTest_v0_5_0 {
    BatchSyncDepositCaller public syncBatchCaller;
    BatchRequestDepositCaller public requestBatchCaller;
    BatchClaimAndRedeemCaller public claimAndRedeemCaller;

    function setUp() public {
        setUpVault(0, 0, 6); // Zero fees, 6 decimals (USDC)

        // Enable sync mode
        enableSyncMode(1000);
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(0);
        vm.prank(safe.addr);
        vault.settleDeposit(0);

        // Deploy and setup sync batch caller
        syncBatchCaller = new BatchSyncDepositCaller();
        mockAsset.mint(address(syncBatchCaller), 100_000e6);
        vm.prank(address(syncBatchCaller));
        mockAsset.approve(address(vault), type(uint256).max);
        address[] memory callers = new address[](1);
        callers[0] = address(syncBatchCaller);
        whitelist(callers);

        // Deploy and setup request batch caller
        requestBatchCaller = new BatchRequestDepositCaller();
        mockAsset.mint(address(requestBatchCaller), 100_000e6);
        vm.prank(address(requestBatchCaller));
        mockAsset.approve(address(vault), type(uint256).max);
        address[] memory requestCallers = new address[](1);
        requestCallers[0] = address(requestBatchCaller);
        whitelist(requestCallers);

        // Deploy claim and redeem caller
        claimAndRedeemCaller = new BatchClaimAndRedeemCaller();
        address[] memory claimCallers = new address[](1);
        claimCallers[0] = address(claimAndRedeemCaller);
        whitelist(claimCallers);
    }

    /// @notice Test: Multiple syncDeposit calls in same transaction via batch caller
    /// @dev Tests batched operations affecting totalAssets/totalSupply
    function testBatchedMultipleSyncDeposits() public {
        // Setup user
        dealAndApproveAndWhitelist(user1.addr);

        // Prepare amounts
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 10_000e6;
        amounts[1] = 5000e6;
        amounts[2] = 3000e6;

        // Register assertion to monitor the batch transaction
        cl.assertion({
            adopter: address(vault),
            createData: type(SyncDepositModeAssertion_v0_5_0).creationCode,
            fnSelector: SyncDepositModeAssertion_v0_5_0.assertionSyncDepositAccounting.selector
        });

        // Batched call - all 3 syncDeposits in ONE transaction
        vm.prank(address(syncBatchCaller));
        syncBatchCaller.batchSyncDeposits(vault, amounts, user1.addr);

        // Verify all deposits succeeded and accounting is correct
        assertGt(vault.balanceOf(user1.addr), 0, "User should have shares");
        assertEq(vault.totalAssets(), 18_000e6, "Total assets should be sum");
    }

    /// @notice Test: Multiple requestDeposit calls in same transaction via batch caller
    /// @dev Tests batched async deposit requests
    function testBatchedMultipleRequestDeposits() public {
        // Expire NAV to enable async mode
        vm.warp(block.timestamp + 1001);
        require(!vault.isTotalAssetsValid(), "NAV should be expired for async mode");

        // Prepare amounts for batched requestDeposit
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 10_000e6;
        amounts[1] = 5000e6;
        amounts[2] = 3000e6;

        // Batched call - all 3 requestDeposits in ONE transaction
        vm.prank(address(requestBatchCaller));
        uint256[] memory requestIds = requestBatchCaller.batchRequestDeposits(
            vault, amounts, address(requestBatchCaller), address(requestBatchCaller)
        );

        // Verify all requests were created
        assertEq(requestIds.length, 3, "Should have 3 request IDs");
        assertGt(requestIds[0], 0, "First request should have valid ID");
        assertGt(requestIds[1], 0, "Second request should have valid ID");
        assertGt(requestIds[2], 0, "Third request should have valid ID");

        // Verify the pending silo received all the assets
        uint256 siloBalance = mockAsset.balanceOf(vault.pendingSilo());
        assertEq(siloBalance, 18_000e6, "Silo should have sum of all deposits");
    }

    /// @notice Test: deposit (claim shares) + requestRedeem in same transaction
    /// @dev Tests realistic user flow: claim settled shares then immediately request to redeem them
    function testBatchedClaimSharesAndRequestRedeem() public {
        // Setup user
        dealAndApproveAndWhitelist(user1.addr);

        // Expire NAV to enable async mode
        vm.warp(block.timestamp + 1001);
        require(!vault.isTotalAssetsValid(), "NAV should be expired for async mode");

        // User makes async deposit request
        vm.prank(user1.addr);
        vault.requestDeposit(20_000e6, user1.addr, user1.addr);

        // Settle the deposit to make shares claimable
        vm.prank(valuationManager.addr);
        vault.updateNewTotalAssets(20_000e6);

        ensureSafeHasAssets(20_000e6);

        vm.prank(safe.addr);
        vault.settleDeposit(20_000e6);

        // Verify user has claimable shares
        uint256 claimableAssets = vault.claimableDepositRequest(0, user1.addr);
        assertGt(claimableAssets, 0, "User should have claimable assets");

        // User sets claim caller as operator to act on their behalf
        vm.prank(user1.addr);
        vault.setOperator(address(claimAndRedeemCaller), true);

        // Execute: claim shares + request redeem in ONE transaction
        vm.prank(address(claimAndRedeemCaller));
        (uint256 claimedShares, uint256 redeemRequestId) =
            claimAndRedeemCaller.claimAndRedeem(vault, claimableAssets, claimableAssets / 2, user1.addr, user1.addr);

        // Verify claim succeeded
        assertGt(claimedShares, 0, "Should have claimed shares");

        // Verify redeem request was created
        assertGt(redeemRequestId, 0, "Should have created redeem request");

        // Verify user still has some shares (claimed full, redeemed half)
        uint256 userBalance = vault.balanceOf(user1.addr);
        assertGt(userBalance, 0, "User should still have shares");

        // Verify pending silo has the redeem request
        uint256 pendingRedeem = vault.pendingRedeemRequest(redeemRequestId, user1.addr);
        assertGt(pendingRedeem, 0, "Should have pending redeem request");
    }
}
