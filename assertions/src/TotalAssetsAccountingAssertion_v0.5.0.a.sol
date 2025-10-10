// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IVault} from "./IVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Assertion} from "credible-std/Assertion.sol";
import {PhEvm} from "credible-std/PhEvm.sol";

/// @title TotalAssetsAccountingAssertion_v0.5.0
/// @notice Validates total assets accounting integrity for Lagoon v0.5.0
///
/// @dev INVARIANT #1: TOTAL ASSETS ACCOUNTING INTEGRITY
///
/// The vault's `totalAssets` is an accounting variable representing Net Asset Value (NAV),
/// set by the valuation manager. During Open/Closing states, it does NOT equal physical
/// balances since the Safe invests assets into external strategies (DeFi protocols, RWAs, etc.).
/// We verify accounting consistency across settlements, not physical balance equality.
///
/// This assertion protects two critical sub-invariants:
///
/// 1.A ACCOUNTING CONSERVATION
///     After settleDeposit(): totalAssets_new = totalAssets_old + pendingAssets
///     After settleRedeem(): totalAssets_new = totalAssets_old - assetsToWithdraw
///
///     WHY: Accounting mismatches compound over time, breaking share pricing. If totalAssets
///     doesn't accurately reflect the vault's economic position, users get incorrect share prices.
///
/// 1.B SOLVENCY (CAN FULFILL CLAIMABLE REDEMPTIONS)
///     After settleRedeem(): assets transferred from Safe to Vault equal assetsToWithdraw
///     Vault balance must increase by exactly the amount users can now claim
///
///     WHY: Insolvency means users cannot claim assets they're entitled to. The vault must
///     always have sufficient balance to cover claimable redemptions.
///
/// @dev This assertion uses events to extract pending amounts (not accessible via getters),
/// then independently verifies the accounting math is correct. We use events for DATA extraction,
/// not for verification - we calculate what totalAssets SHOULD be and verify it independently.
contract TotalAssetsAccountingAssertion_v0_5_0 is Assertion {
    /// @notice Event signatures for log parsing
    bytes32 private constant SETTLE_DEPOSIT_SIG =
        keccak256("SettleDeposit(uint40,uint40,uint256,uint256,uint256,uint256)");
    bytes32 private constant SETTLE_REDEEM_SIG =
        keccak256("SettleRedeem(uint40,uint40,uint256,uint256,uint256,uint256)");
    bytes32 private constant TOTAL_ASSETS_UPDATED_SIG = keccak256("TotalAssetsUpdated(uint256)");
    bytes32 private constant DEPOSIT_SYNC_SIG = keccak256("DepositSync(address,address,uint256,uint256)");
    /// @notice Registers assertion triggers on settlement functions
    function triggers() external view override {
        // 1.A Accounting Conservation
        registerCallTrigger(this.assertionSettleDepositAccounting.selector, IVault.settleDeposit.selector);
        registerCallTrigger(this.assertionSettleRedeemAccounting.selector, IVault.settleRedeem.selector);
        registerCallTrigger(this.assertionSyncDepositAccounting.selector, IVault.syncDeposit.selector);

        // 1.B Solvency
        registerCallTrigger(this.assertionVaultSolvency.selector, IVault.settleRedeem.selector);
    }

    /// @notice Invariant 1.A: Verify totalAssets increases correctly after settleDeposit()
    /// @dev Verifies: totalAssets_new = totalAssets_old + pendingAssets
    /// @dev Handles early return when pendingAssets == 0 (no event emitted)
    function assertionSettleDepositAccounting() external {
        IVault vault = IVault(ph.getAssertionAdopter());

        // Get pre-state (not used, but required for fork setup)
        ph.forkPreTx();

        // Get post-state and extract pendingAssets from event
        ph.forkPostTx();
        uint256 postTotalAssets = vault.totalAssets();

        // Parse logs to find TotalAssetsUpdated and SettleDeposit events
        // settleDeposit() does two things:
        // 1. Updates totalAssets to newTotalAssets (emits TotalAssetsUpdated)
        // 2. Adds pending deposits to totalAssets (emits SettleDeposit)
        PhEvm.Log[] memory logs = ph.getLogs();
        uint256 pendingAssets = 0;
        uint256 newTotalAssets = 0;
        bool settleEventFound = false;
        bool navUpdateFound = false;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(vault)) {
                if (logs[i].topics[0] == TOTAL_ASSETS_UPDATED_SIG) {
                    newTotalAssets = abi.decode(logs[i].data, (uint256));
                    navUpdateFound = true;
                } else if (logs[i].topics[0] == SETTLE_DEPOSIT_SIG) {
                    // SettleDeposit(uint40 indexed lastDepositEpochIdSettled, uint40 indexed depositSettleId,
                    //               uint256 totalAssets, uint256 totalSupply, uint256 pendingAssets, uint256 shares)
                    // Non-indexed in data: totalAssets, totalSupply, pendingAssets, shares
                    (, , uint256 eventPendingAssets,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                    pendingAssets = eventPendingAssets;
                    settleEventFound = true;
                }
            }
        }

        // Verify accounting
        // settleDeposit calls _updateTotalAssetsAndTakeFees then _settleDeposit
        // Expected: totalAssets = newTotalAssets (from NAV update) + pendingAssets (from settlement)
        if (settleEventFound && navUpdateFound) {
            require(
                postTotalAssets == newTotalAssets + pendingAssets,
                "Accounting violation: totalAssets after settleDeposit incorrect"
            );
        } else if (navUpdateFound && !settleEventFound) {
            // NAV updated but no pending deposits (_settleDeposit returned early)
            require(
                postTotalAssets == newTotalAssets, "Accounting violation: totalAssets incorrect with no pending"
            );
        } else {
            // This shouldn't happen - settleDeposit always updates NAV
            require(false, "Accounting violation: expected TotalAssetsUpdated event");
        }
    }

    /// @notice Invariant 1.A: Verify totalAssets decreases correctly after settleRedeem()
    /// @dev Verifies: totalAssets_new = newTotalAssets - assetsWithdrawn
    /// @dev Handles early return when pendingShares == 0 or insufficient Safe balance (no event emitted)
    function assertionSettleRedeemAccounting() external {
        IVault vault = IVault(ph.getAssertionAdopter());

        // Get pre-state (not used, but required for fork setup)
        ph.forkPreTx();

        // Get post-state and extract assetsWithdrawn from event
        ph.forkPostTx();
        uint256 postTotalAssets = vault.totalAssets();

        // Parse logs to find TotalAssetsUpdated and SettleRedeem events
        // settleRedeem() does two things:
        // 1. Updates totalAssets to newTotalAssets (emits TotalAssetsUpdated)
        // 2. Subtracts redeemed assets from totalAssets (emits SettleRedeem)
        PhEvm.Log[] memory logs = ph.getLogs();
        uint256 assetsWithdrawn = 0;
        uint256 newTotalAssets = 0;
        bool settleEventFound = false;
        bool navUpdateFound = false;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(vault)) {
                if (logs[i].topics[0] == TOTAL_ASSETS_UPDATED_SIG) {
                    newTotalAssets = abi.decode(logs[i].data, (uint256));
                    navUpdateFound = true;
                } else if (logs[i].topics[0] == SETTLE_REDEEM_SIG) {
                    // SettleRedeem(uint40 indexed lastRedeemEpochIdSettled, uint40 indexed redeemSettleId,
                    //              uint256 totalAssets, uint256 totalSupply, uint256 assetsWithdrawn, uint256 pendingShares)
                    // Non-indexed in data: totalAssets, totalSupply, assetsWithdrawn, pendingShares
                    (, , uint256 eventAssetsWithdrawn,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                    assetsWithdrawn = eventAssetsWithdrawn;
                    settleEventFound = true;
                }
            }
        }

        // Verify accounting
        // settleRedeem calls _updateTotalAssetsAndTakeFees then _settleRedeem
        // Expected: totalAssets = newTotalAssets (from NAV update) - assetsWithdrawn (from settlement)
        if (settleEventFound && navUpdateFound) {
            require(
                postTotalAssets == newTotalAssets - assetsWithdrawn,
                "Accounting violation: totalAssets after settleRedeem incorrect"
            );
        } else if (navUpdateFound && !settleEventFound) {
            // NAV updated but no pending redemptions (_settleRedeem returned early)
            require(
                postTotalAssets == newTotalAssets, "Accounting violation: totalAssets incorrect with no pending"
            );
        } else {
            // This shouldn't happen - settleRedeem always updates NAV
            require(false, "Accounting violation: expected TotalAssetsUpdated event");
        }
    }

    /// @notice Invariant 1.B: Verify vault can fulfill claimable redemptions
    /// @dev Verifies: vault balance increases by assetsWithdrawn after settleRedeem()
    /// @dev Uses induction: track incremental changes to ensure vault stays solvent
    function assertionVaultSolvency() external {
        IVault vault = IVault(ph.getAssertionAdopter());
        address asset = vault.asset();

        // Get pre-state
        ph.forkPreTx();
        uint256 preVaultBalance = IERC20(asset).balanceOf(address(vault));

        // Get post-state and extract assetsWithdrawn from event
        ph.forkPostTx();
        uint256 postVaultBalance = IERC20(asset).balanceOf(address(vault));

        // Parse logs to find SettleRedeem event
        PhEvm.Log[] memory logs = ph.getLogs();
        uint256 assetsWithdrawn = 0;
        bool eventFound = false;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(vault) && logs[i].topics[0] == SETTLE_REDEEM_SIG) {
                // SettleRedeem(uint40 indexed lastRedeemEpochIdSettled, uint40 indexed redeemSettleId,
                //              uint256 totalAssets, uint256 totalSupply, uint256 assetsWithdrawn, uint256 pendingShares)
                // Non-indexed in data: totalAssets, totalSupply, assetsWithdrawn, pendingShares
                (, , uint256 eventAssetsWithdrawn,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                assetsWithdrawn = eventAssetsWithdrawn;
                eventFound = true;
                break;
            }
        }

        // Verify vault balance increased correctly (induction-based solvency)
        // By verifying each incremental change, we ensure vault can always fulfill claims
        if (eventFound) {
            require(
                postVaultBalance == preVaultBalance + assetsWithdrawn,
                "Solvency violation: vault balance did not increase correctly"
            );
        } else {
            // No event = no settlement occurred, vault balance shouldn't change
            require(
                postVaultBalance == preVaultBalance,
                "Solvency violation: vault balance changed when no settlement occurred"
            );
        }
    }

    /// @notice Invariant 1.A: Verify totalAssets increases correctly after syncDeposit()
    /// @dev Verifies: totalAssets_new = totalAssets_old + assets
    /// @dev syncDeposit() is v0.5.0 feature for instant deposits when NAV is fresh
    /// @dev Also verifies assets go to Safe (not Silo) for proper routing
    function assertionSyncDepositAccounting() external {
        IVault vault = IVault(ph.getAssertionAdopter());
        address asset = vault.asset();
        address safe = vault.safe();

        // Get pre-state
        ph.forkPreTx();
        uint256 preTotalAssets = vault.totalAssets();
        uint256 preSafeBalance = IERC20(asset).balanceOf(safe);

        // Get post-state
        ph.forkPostTx();
        uint256 postTotalAssets = vault.totalAssets();
        uint256 postSafeBalance = IERC20(asset).balanceOf(safe);

        // Parse logs to find DepositSync event(s)
        // DepositSync(address indexed sender, address indexed receiver, uint256 assets, uint256 shares)
        PhEvm.Log[] memory logs = ph.getLogs();
        uint256 totalAssetsDeposited = 0;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(vault) && logs[i].topics[0] == DEPOSIT_SYNC_SIG) {
                // Non-indexed in data: assets, shares
                (uint256 assets,) = abi.decode(logs[i].data, (uint256, uint256));
                totalAssetsDeposited += assets;
            }
        }

        // Verify totalAssets increased by exactly the deposited amount
        require(
            postTotalAssets == preTotalAssets + totalAssetsDeposited,
            "Accounting violation: totalAssets after syncDeposit incorrect"
        );

        // Verify assets went to Safe (not Silo) - this is critical for v0.5.0 routing
        require(
            postSafeBalance == preSafeBalance + totalAssetsDeposited,
            "Routing violation: syncDeposit assets did not go to Safe"
        );
    }
}
