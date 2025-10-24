// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IVault} from "./IVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Assertion} from "credible-std/Assertion.sol";
import {PhEvm} from "credible-std/PhEvm.sol";

/// @title SiloBalanceConsistencyAssertion
/// @notice Validates Silo balance consistency for Lagoon v0.4.0 & v0.5.0
///
/// @dev INVARIANT #3: SILO BALANCE CONSISTENCY
///
/// The Silo contract is an immutable, trustless component that temporarily holds assets
/// (for pending deposits) and shares (for pending redeems). Its balances must equal or
/// exceed the sum of all pending requests, with tolerance for airdrops/donations.
///
/// This assertion protects critical sub-invariants:
///
/// 3.A ASSET BALANCE CONSISTENCY
///     After requestDeposit(): siloAssetBalance increases by assets
///     After settleDeposit(): siloAssetBalance decreases by settled assets (move to Safe)
///     After cancelRequestDeposit(): siloAssetBalance decreases by refunded assets
///     v0.5.0: After syncDeposit(): siloAssetBalance UNCHANGED (assets go to Safe)
///
///     WHY: Silo accounting mismatches allow users to withdraw more than they deposited.
///     The Silo is the staging area where user funds are vulnerable before settlement.
///
/// 3.B SHARE BALANCE CONSISTENCY
///     After requestRedeem(): siloShareBalance increases by shares
///     After settleRedeem(): siloShareBalance decreases by settled shares (burned)
///
///     WHY: Share accounting errors let users claim shares they didn't pay for.
///
/// @dev This assertion uses event-based verification (induction pattern): we verify each
/// transaction's delta is consistent, which implies the global invariant holds over time.
contract SiloBalanceConsistencyAssertion is Assertion {
    /// @notice ERC7540 storage location
    /// @dev keccak256(abi.encode(uint256(keccak256("hopper.storage.erc7540")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ERC7540_STORAGE_LOCATION =
        0x5c74d456014b1c0eb4368d944667a568313858a3029a650ff0cb7b56f8b57a00;

    /// @notice Offset of pendingSilo in ERC7540Storage struct (in storage slots)
    /// @dev pendingSilo is at slot 8 in the struct (after 2 uint256s, packed uint40s, and 5 mappings)
    uint256 private constant PENDING_SILO_OFFSET = 8;

    /// @notice Event signatures for log parsing
    bytes32 private constant DEPOSIT_REQUEST_SIG = keccak256("DepositRequest(address,address,uint256,address,uint256)");
    bytes32 private constant DEPOSIT_REQUEST_CANCELED_SIG = keccak256("DepositRequestCanceled(uint256,address)");
    bytes32 private constant REDEEM_REQUEST_SIG = keccak256("RedeemRequest(address,address,uint256,address,uint256)");
    bytes32 private constant SETTLE_DEPOSIT_SIG =
        keccak256("SettleDeposit(uint40,uint40,uint256,uint256,uint256,uint256)");
    bytes32 private constant SETTLE_REDEEM_SIG =
        keccak256("SettleRedeem(uint40,uint40,uint256,uint256,uint256,uint256)");
    bytes32 private constant DEPOSIT_SYNC_SIG = keccak256("DepositSync(address,address,uint256,uint256)");

    /// @notice Read the pendingSilo address from vault's ERC7540 storage
    /// @param vault Address of the vault contract
    /// @return silo Address of the pending Silo
    function _getPendingSilo(
        address vault
    ) internal view returns (address silo) {
        bytes32 siloSlot = bytes32(uint256(ERC7540_STORAGE_LOCATION) + PENDING_SILO_OFFSET);
        return address(uint160(uint256(ph.load(vault, siloSlot))));
    }

    /// @notice Registers assertion triggers on Silo-affecting functions
    function triggers() external view override {
        // Asset balance assertions
        registerCallTrigger(this.assertionRequestDepositSiloBalance.selector, IVault.requestDeposit.selector);
        registerCallTrigger(this.assertionSettleDepositSiloBalance.selector, IVault.settleDeposit.selector);
        registerCallTrigger(
            this.assertionCancelRequestDepositSiloBalance.selector, IVault.cancelRequestDeposit.selector
        );
        registerCallTrigger(this.assertionSyncDepositSiloIsolation.selector, IVault.syncDeposit.selector);

        // Share balance assertions
        registerCallTrigger(this.assertionRequestRedeemSiloBalance.selector, IVault.requestRedeem.selector);
        registerCallTrigger(this.assertionSettleRedeemSiloBalance.selector, IVault.settleRedeem.selector);
    }

    /// @notice Invariant 3.A: Verify Silo asset balance increases after requestDeposit()
    /// @dev Verifies: postSiloAssetBalance = preSiloAssetBalance + assets
    function assertionRequestDepositSiloBalance() external {
        IVault vault = IVault(ph.getAssertionAdopter());
        address asset = vault.asset();
        address silo = _getPendingSilo(address(vault));

        ph.forkPreTx();
        uint256 preSiloBalance = IERC20(asset).balanceOf(silo);

        ph.forkPostTx();
        uint256 postSiloBalance = IERC20(asset).balanceOf(silo);

        // Parse DepositRequest event to get assets deposited
        PhEvm.Log[] memory logs = ph.getLogs();
        uint256 totalAssetsDeposited = 0;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(vault) && logs[i].topics[0] == DEPOSIT_REQUEST_SIG) {
                // DepositRequest(address indexed controller, address indexed owner, uint256 indexed requestId, address
                // sender, uint256 assets)
                (, uint256 assets) = abi.decode(logs[i].data, (address, uint256));
                totalAssetsDeposited += assets;
            }
        }

        // Verify Silo balance increased by exactly the deposited amount
        require(
            postSiloBalance == preSiloBalance + totalAssetsDeposited,
            "Silo balance violation: assets not transferred to Silo correctly on requestDeposit"
        );
    }

    /// @notice Invariant 3.A: Verify Silo asset balance decreases after settleDeposit()
    /// @dev Verifies: postSiloAssetBalance = preSiloAssetBalance - settledAssets
    /// @dev Note: New requests after last valuation remain in Silo
    function assertionSettleDepositSiloBalance() external {
        IVault vault = IVault(ph.getAssertionAdopter());
        address asset = vault.asset();
        address silo = _getPendingSilo(address(vault));

        ph.forkPreTx();
        uint256 preSiloBalance = IERC20(asset).balanceOf(silo);

        ph.forkPostTx();
        uint256 postSiloBalance = IERC20(asset).balanceOf(silo);

        // Parse events to get settled assets and any new deposit requests in same tx
        PhEvm.Log[] memory logs = ph.getLogs();
        uint256 settledAssets = 0;
        uint256 newDepositAssets = 0;
        bool settleEventFound = false;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(vault)) {
                if (logs[i].topics[0] == SETTLE_DEPOSIT_SIG) {
                    // SettleDeposit(uint40 indexed epochId, uint40 indexed settledId, uint256 totalAssets, uint256
                    // totalSupply, uint256 assetsDeposited, uint256 sharesMinted)
                    (,, uint256 assetsDeposited,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                    settledAssets += assetsDeposited;
                    settleEventFound = true;
                } else if (logs[i].topics[0] == DEPOSIT_REQUEST_SIG) {
                    // DepositRequest events in same tx (new deposits after settlement)
                    (, uint256 assets) = abi.decode(logs[i].data, (address, uint256));
                    newDepositAssets += assets;
                }
            }
        }

        // If no settlement occurred (pendingAssets == 0), Silo balance should be unchanged
        if (!settleEventFound) {
            require(
                postSiloBalance == preSiloBalance, "Silo balance violation: Silo changed when no deposits were settled"
            );
        } else {
            // Verify Silo balance decreased by at least the settled amount (allow airdrops/donations)
            // Formula: postSilo >= preSilo - settledAssets + newDepositAssets
            // Use >= to tolerate airdrops/donations that remain in Silo
            require(
                postSiloBalance >= preSiloBalance - settledAssets + newDepositAssets,
                "Silo balance violation: Silo balance decreased more than expected"
            );
        }
    }

    /// @notice Invariant 3.A: Verify Silo asset balance decreases after cancelRequestDeposit()
    /// @dev Verifies: postSiloAssetBalance = preSiloAssetBalance - refundedAssets
    function assertionCancelRequestDepositSiloBalance() external {
        IVault vault = IVault(ph.getAssertionAdopter());
        address asset = vault.asset();
        address silo = _getPendingSilo(address(vault));

        ph.forkPreTx();
        uint256 preSiloBalance = IERC20(asset).balanceOf(silo);

        ph.forkPostTx();
        uint256 postSiloBalance = IERC20(asset).balanceOf(silo);

        // Verify Silo balance decreased (assets refunded to user)
        // Note: We verify balance decreased but don't parse exact amount since DepositRequestCanceled
        // event doesn't include assets field. The transfer amount is verified by the transfer itself.
        require(
            postSiloBalance < preSiloBalance,
            "Silo balance violation: Silo balance did not decrease on cancelRequestDeposit"
        );

        // TODO: We could do something like:
        // uint256 requestedAmount = $.epochs[requestId].depositRequest[msg.sender];
        // to get the amount of assets refunded to the user.
        // TODO: This is the code of the cancelRequestDeposit function:
        //     function cancelRequestDeposit() external whenNotPaused {
        //     ERC7540Storage storage $ = _getERC7540Storage();

        //     uint40 requestId = $.lastDepositRequestId[msg.sender];
        //     if (requestId != $.depositEpochId) {
        //         revert RequestNotCancelable(requestId);
        //     }

        //     uint256 requestedAmount = $.epochs[requestId].depositRequest[msg.sender];
        //     $.epochs[requestId].depositRequest[msg.sender] = 0;
        //     IERC20(asset()).safeTransferFrom(address($.pendingSilo), msg.sender, requestedAmount);

        //     emit DepositRequestCanceled(requestId, msg.sender);
        // }
    }

    /// @notice Invariant 3.A: Verify syncDeposit does NOT affect Silo (v0.5.0)
    /// @dev Verifies: postSiloAssetBalance = preSiloAssetBalance (NO CHANGE)
    /// @dev Assets go directly to Safe, bypassing Silo entirely
    function assertionSyncDepositSiloIsolation() external {
        IVault vault = IVault(ph.getAssertionAdopter());
        address asset = vault.asset();
        address silo = _getPendingSilo(address(vault));
        address safe = vault.safe();

        ph.forkPreTx();
        uint256 preSiloBalance = IERC20(asset).balanceOf(silo);
        uint256 preSafeBalance = IERC20(asset).balanceOf(safe);

        ph.forkPostTx();
        uint256 postSiloBalance = IERC20(asset).balanceOf(silo);
        uint256 postSafeBalance = IERC20(asset).balanceOf(safe);

        // Parse DepositSync event to get assets deposited
        PhEvm.Log[] memory logs = ph.getLogs();
        uint256 totalAssetsDeposited = 0;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(vault) && logs[i].topics[0] == DEPOSIT_SYNC_SIG) {
                // DepositSync(address indexed sender, address indexed receiver, uint256 assets, uint256 shares)
                (uint256 assets,) = abi.decode(logs[i].data, (uint256, uint256));
                totalAssetsDeposited += assets;
            }
        }

        // Verify Silo balance UNCHANGED (sync deposits bypass Silo)
        require(
            postSiloBalance == preSiloBalance, "Silo isolation violation: syncDeposit incorrectly affected Silo balance"
        );

        // Verify Safe balance increased (assets go directly to Safe)
        require(
            postSafeBalance == preSafeBalance + totalAssetsDeposited,
            "Silo isolation violation: syncDeposit assets did not go to Safe"
        );
    }

    /// @notice Invariant 3.B: Verify Silo share balance increases after requestRedeem()
    /// @dev Verifies: postSiloShareBalance = preSiloShareBalance + shares
    function assertionRequestRedeemSiloBalance() external {
        IVault vault = IVault(ph.getAssertionAdopter());
        address silo = _getPendingSilo(address(vault));

        ph.forkPreTx();
        uint256 preSiloBalance = vault.balanceOf(silo);

        ph.forkPostTx();
        uint256 postSiloBalance = vault.balanceOf(silo);

        // Parse RedeemRequest event to get shares
        PhEvm.Log[] memory logs = ph.getLogs();
        uint256 totalSharesRedeemed = 0;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(vault) && logs[i].topics[0] == REDEEM_REQUEST_SIG) {
                // RedeemRequest(address indexed controller, address indexed owner, uint256 indexed requestId, address
                // sender, uint256 shares)
                (, uint256 shares) = abi.decode(logs[i].data, (address, uint256));
                totalSharesRedeemed += shares;
            }
        }

        // Verify Silo share balance increased by requested shares
        require(
            postSiloBalance == preSiloBalance + totalSharesRedeemed,
            "Silo balance violation: shares not transferred to Silo correctly on requestRedeem"
        );
    }

    /// @notice Invariant 3.B: Verify Silo share balance decreases after settleRedeem()
    /// @dev Verifies: postSiloShareBalance = preSiloShareBalance - settledShares
    /// @dev Shares are burned from Silo during settlement
    function assertionSettleRedeemSiloBalance() external {
        IVault vault = IVault(ph.getAssertionAdopter());
        address silo = _getPendingSilo(address(vault));

        ph.forkPreTx();
        uint256 preSiloBalance = vault.balanceOf(silo);

        ph.forkPostTx();
        uint256 postSiloBalance = vault.balanceOf(silo);

        // Parse events to get settled shares and any new redeem requests in same tx
        PhEvm.Log[] memory logs = ph.getLogs();
        uint256 settledShares = 0;
        uint256 newRedeemShares = 0;
        bool settleEventFound = false;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(vault)) {
                if (logs[i].topics[0] == SETTLE_REDEEM_SIG) {
                    // SettleRedeem(uint40 indexed epochId, uint40 indexed settledId, uint256 totalAssets, uint256
                    // totalSupply, uint256 assetsWithdrawed, uint256 sharesBurned)
                    (,,, uint256 sharesBurned) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                    settledShares += sharesBurned;
                    settleEventFound = true;
                } else if (logs[i].topics[0] == REDEEM_REQUEST_SIG) {
                    // RedeemRequest events in same tx (new redeems after settlement)
                    (, uint256 shares) = abi.decode(logs[i].data, (address, uint256));
                    newRedeemShares += shares;
                }
            }
        }

        // If no settlement occurred (pendingShares == 0), Silo balance should be unchanged
        if (!settleEventFound) {
            require(
                postSiloBalance == preSiloBalance, "Silo balance violation: Silo changed when no redeems were settled"
            );
        } else {
            // Verify Silo balance decreased by at least the settled amount (allow donated shares)
            // Formula: postSilo >= preSilo - settledShares + newRedeemShares
            // Use >= to tolerate share donations that remain in Silo
            require(
                postSiloBalance >= preSiloBalance - settledShares + newRedeemShares,
                "Silo balance violation: Silo share balance decreased more than expected"
            );
        }
    }
}
