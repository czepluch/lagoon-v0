// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Assertion} from "credible-std/Assertion.sol";

/// @notice Minimal interface for vault functions that modify epochs
interface IVault {
    function updateNewTotalAssets(uint256 newTotalAssets) external;
    function settleDeposit(uint256 totalAssets) external;
    function settleRedeem(uint256 totalAssets) external;
}

/// @title EpochInvariantsAssertion
/// @notice Validates epoch management invariants for the Lagoon v0.4.0 ERC7540 vault
///
/// @dev INVARIANT #2: EPOCH SETTLEMENT ORDERING AND CLAIMABILITY
///
/// The Lagoon vault uses an epoch-based async request/redeem system (ERC7540) where:
/// - Users request deposits/redeems in an "open" epoch
/// - The vault settles these requests, making shares/assets claimable
/// - Epochs follow a strict lifecycle to ensure users can always claim their funds
///
/// This assertion protects three critical sub-invariants:
///
/// 2.1 EPOCH PARITY
///     depositEpochId must always be ODD (1, 3, 5, ...)
///     redeemEpochId must always be EVEN (2, 4, 6, ...)
///
///     WHY: The vault uses parity to distinguish deposit vs redeem epochs. Breaking this
///     causes epoch confusion, potentially mixing deposit and redeem operations incorrectly.
///
/// 2.2 SETTLEMENT ORDERING
///     lastDepositEpochIdSettled <= depositEpochId - 2
///     lastRedeemEpochIdSettled <= redeemEpochId - 2
///
///     WHY: The current epoch is always "open" for new requests. The most recent epoch that
///     could be settled is (current - 2). If lastSettled exceeds this, the vault has settled
///     the current epoch or a future epoch, breaking temporal ordering and potentially
///     allowing premature claims or making funds unclaimable.
///
/// 2.3 EPOCH INCREMENTS
///     Epochs only increment by 0 (no change) or 2 (next epoch)
///
///     WHY: Incrementing by 1 breaks parity. Incrementing by >2 skips epochs, potentially
///     orphaning user requests in the skipped epochs, making their funds unclaimable.
///
/// These invariants together ensure users can always claim their funds and prevent
/// temporal inconsistencies in the vault's async request processing.
///
/// @dev Contains three separate assertion functions for parallel execution
contract EpochInvariantsAssertion is Assertion {
    /// @notice ERC7540 storage location from the vault contract
    bytes32 private constant ERC7540_STORAGE_LOCATION =
        0x5c74d456014b1c0eb4368d944667a568313858a3029a650ff0cb7b56f8b57a00;

    /// @notice Registers assertion triggers on vault functions that modify epochs
    function triggers() external view override {
        registerCallTrigger(this.assertionEpochParity.selector, IVault.updateNewTotalAssets.selector);
        registerCallTrigger(this.assertionSettlementOrdering.selector, IVault.settleDeposit.selector);
        registerCallTrigger(this.assertionSettlementOrdering.selector, IVault.settleRedeem.selector);
        registerCallTrigger(this.assertionEpochIncrements.selector, IVault.updateNewTotalAssets.selector);
    }

    /// @notice Invariant #2.1: Epoch Parity
    /// @dev Checks that depositEpochId is always odd and redeemEpochId is always even
    function assertionEpochParity() external {
        address vaultAddress = ph.getAssertionAdopter();
        ph.forkPostTx();

        bytes32 epochSlot = bytes32(uint256(ERC7540_STORAGE_LOCATION) + 2);
        bytes32 epochData = ph.load(vaultAddress, epochSlot);

        uint40 depositEpochId = uint40(uint256(epochData));
        uint40 redeemEpochId = uint40(uint256(epochData) >> 120);
        require(depositEpochId % 2 == 1, "Epoch parity violation: deposit epoch must be odd");
        require(redeemEpochId % 2 == 0, "Epoch parity violation: redeem epoch must be even");
    }

    /// @notice Invariant #2.2: Settlement Ordering
    /// @dev Verifies lastSettled epochs are always at least 2 behind current epochs
    /// @dev Current epoch is "open" for requests. Only epoch (current - 2) can be settled.
    function assertionSettlementOrdering() external {
        address vaultAddress = ph.getAssertionAdopter();
        ph.forkPostTx();

        bytes32 epochSlot = bytes32(uint256(ERC7540_STORAGE_LOCATION) + 2);
        bytes32 epochData = ph.load(vaultAddress, epochSlot);

        uint40 depositEpochId = uint40(uint256(epochData));
        uint40 lastDepositEpochIdSettled = uint40(uint256(epochData) >> 80);
        uint40 redeemEpochId = uint40(uint256(epochData) >> 120);
        uint40 lastRedeemEpochIdSettled = uint40(uint256(epochData) >> 200);

        // For deposit epochs: check only if depositEpochId >= 2 to avoid underflow
        if (depositEpochId >= 2) {
            require(
                lastDepositEpochIdSettled <= depositEpochId - 2,
                "Settlement ordering violation: lastDepositEpochIdSettled > depositEpochId - 2"
            );
        }

        // For redeem epochs: check only if redeemEpochId >= 2 to avoid underflow
        if (redeemEpochId >= 2) {
            require(
                lastRedeemEpochIdSettled <= redeemEpochId - 2,
                "Settlement ordering violation: lastRedeemEpochIdSettled > redeemEpochId - 2"
            );
        }
    }

    /// @notice Invariant #2.3: Epoch Increments
    /// @dev Verifies epochs only increment by 0 or 2 to maintain parity and prevent skipping
    function assertionEpochIncrements() external {
        address vaultAddress = ph.getAssertionAdopter();
        bytes32 epochSlot = bytes32(uint256(ERC7540_STORAGE_LOCATION) + 2);

        ph.forkPreTx();
        bytes32 preEpochData = ph.load(vaultAddress, epochSlot);
        uint40 preDepositEpochId = uint40(uint256(preEpochData));
        uint40 preRedeemEpochId = uint40(uint256(preEpochData) >> 120);

        ph.forkPostTx();
        bytes32 postEpochData = ph.load(vaultAddress, epochSlot);
        uint40 postDepositEpochId = uint40(uint256(postEpochData));
        uint40 postRedeemEpochId = uint40(uint256(postEpochData) >> 120);

        uint40 depositIncrement = postDepositEpochId - preDepositEpochId;
        uint40 redeemIncrement = postRedeemEpochId - preRedeemEpochId;
        require(
            depositIncrement == 0 || depositIncrement == 2,
            "Epoch increment violation: deposit epoch must increment by 0 or 2"
        );
        require(
            redeemIncrement == 0 || redeemIncrement == 2,
            "Epoch increment violation: redeem epoch must increment by 0 or 2"
        );
    }
}
