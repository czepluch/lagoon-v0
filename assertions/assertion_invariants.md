# Lagoon Protocol Invariants - Tier 1

> **Focus**: This document contains only **Tier 1** invariants selected for assertions implementation. For complete invariant documentation including Tier 2 and Tier 3, see `invariants.md`.
> **Coverage**: Both **v0.4.0** (async-only) and **v0.5.0** (synchronous deposits + NAV expiration)

---

## Tier 1 Invariants Summary

1. **Total Assets Accounting Integrity** (v0.4.0 & v0.5.0)
2. **Epoch Settlement Ordering and Claimability** (v0.4.0 & v0.5.0)
3. **Silo Balance Consistency** (v0.4.0 & v0.5.0)
4. **Synchronous Deposit Mode Integrity** (v0.5.0 only) - **HIGHEST PRIORITY**
5. **NAV Validity and Expiration Lifecycle** (v0.5.0 only)

---

## 1. Total Assets Accounting Integrity [TIER 1]

**Applies to**: v0.4.0 & v0.5.0

**Description**: The vault's `totalAssets` is an accounting variable representing Net Asset Value (NAV), set by the valuation manager. During Open/Closing states, it does NOT equal physical balances since the Safe invests assets into external strategies (DeFi protocols, RWAs, etc.). We verify accounting consistency across settlements, not physical balance equality.

**Invariant Rules**:

### A. Accounting Conservation (All States)

- After `_settleDeposit()`: `totalAssets_new = totalAssets_old + pendingAssets`
- After `_settleRedeem()`: `totalAssets_new = totalAssets_old - assetsWithdrawn`
- After `syncDeposit()` (v0.5.0 only): `totalAssets_new = totalAssets_old + assets`
- Track settlement events (`SettleDeposit`, `SettleRedeem`, `DepositSync`) to verify accounting changes match event data
- Fee minting increases `totalSupply` but does not directly change `totalAssets` (fees dilute via share issuance)
- Use `_settleDeposit()` and `_settleRedeem()` internal functions for better coverage since they're called by both `settleDeposit()` and `settleRedeem()`

### B. Solvency (Can Fulfill Claimable Redemptions)

- After `_settleRedeem()`, assets are transferred from Safe to Vault and totalAssets is reduced or stays equal
- Use `_settleRedeem()` for better coverage (called by both `settleRedeem()` and `settleDeposit()`)
- Vault balance must cover all claimable redemptions: `vaultBalance >= Σ(claimableRedeemRequest(user))`
- When Closed, vault balance must cover all potential redemptions at fixed price

**Why Critical**: Accounting mismatches compound over time, breaking share pricing. Insolvency means users cannot claim assets they're entitled to.

**Implementation Notes**:

- Use event tracking (`getLogs`) as primary verification method
- Compare pre-tx and post-tx totalAssets values
- Monitor solvency: vault balance must cover claimable redemptions
- Note: Assertions cannot trigger on internal functions like `_settleDeposit()` and `_settleRedeem()`. Instead, trigger on the public/external functions that call them: `settleDeposit()`, `settleRedeem()`, `close()`, and `syncDeposit()` (v0.5.0)

---

## 2. Epoch Settlement Ordering and Claimability [TIER 1]

**Applies to**: v0.4.0 & v0.5.0

**Description**: The epoch-based settlement system must maintain strict ordering and state consistency. Users can only claim from settled epochs. This is especially critical for upgrade protection - ensures logic upgrades don't introduce bugs that violate epoch mechanics.

**Invariant Rules**:

- Current epoch always at least 2 ahead of last settled: `lastDepositEpochIdSettled <= depositEpochId - 2` and `lastRedeemEpochIdSettled <= redeemEpochId - 2`
- Deposit epochs must always be odd: `depositEpochId % 2 == 1`
- Redeem epochs must always be even: `redeemEpochId % 2 == 0`
- Users cannot claim from epochs where `requestId > lastEpochIdSettled`
- Once an epoch is settled, its conversion rate (totalAssets/totalSupply at settlement) is locked forever
- Calling `updateNewTotalAssets()` increments epoch IDs by 2 if there are pending requests
- **v0.5.0 only**: `syncDeposit()` must NOT increment `depositEpochId` (only `updateNewTotalAssets()` does)

**Why Critical**: Epoch ordering violations allow users to claim assets/shares at incorrect conversion rates, enabling front-running attacks where users can choose favorable pricing by timing their claims. Double-claiming via epoch manipulation.

**Implementation Notes**:

- These checks are especially valuable after contract upgrades
- Verify epoch parity (odd/even) is maintained across all transactions
- Check ordering invariants hold in every state transition
- v0.5.0: Verify `syncDeposit()` does NOT change `depositEpochId`

---

## 3. Silo Balance Consistency [TIER 1]

**Applies to**: v0.4.0 & v0.5.0

**Description**: The Silo contract is an immutable, trustless component that temporarily holds assets (for pending deposits) and shares (for pending redeems). Its balances must equal or exceed the sum of all pending requests, with tolerance for airdrops/donations.

**Invariant Rules**:

- Silo asset balance must be at least: `Σ(epochs[depositEpochId].depositRequest[user])` for all users
- Silo share balance must be at least: `Σ(epochs[redeemEpochId].redeemRequest[user])` for all users
- Silo balances can exceed sum of requests (allows for airdrops/donations)
- After `settleDeposit()`: Deposits from settled epoch transferred to Safe, but new deposits (after last valuation) remain in Silo
- After `settleRedeem()`: Shares from settled epoch burned, but shares from current epoch remain in Silo
- Users can only have one pending request per type (deposit OR redeem) at a time
- `cancelRequestDeposit()` must only work in the same epoch: `requestId == depositEpochId`
- **v0.5.0 only**: `syncDeposit()` must NOT interact with Silo balances (assets go directly to Safe)

**Why Critical**: Silo accounting mismatches allow users to withdraw more than they deposited or claim shares they didn't pay for. The Silo is the staging area where user funds are vulnerable before settlement.

**Implementation Notes**:

- Use event-based validation (`DepositRequest`, `DepositRequestCanceled`, `RedeemRequest`, `DepositSync`) as primary method
- Calculate: `pendingDeposits = Σ(DepositRequest.assets) - Σ(DepositRequestCanceled.assets)`
- Balance checks are secondary validation (allow >= for airdrops)
- After settlement, Silo may not be empty (new requests came in after last valuation)
- v0.5.0: Verify Safe balance increases (not Silo) after `syncDeposit()`

---

## 4. Synchronous Deposit Mode Integrity [TIER 1] - v0.5.0 ONLY

**Applies to**: v0.5.0 only

**HIGHEST PRIORITY for v0.5.0**

**Description**: v0.5.0 adds `syncDeposit()` - a synchronous deposit function that bypasses the epoch system when NAV is fresh. The vault operates in one of two mutually exclusive modes controlled by NAV validity. This is a high-frequency operation requiring robust runtime checks. Heavily used by Turtle Protocol.

**Invariant Rules**:

### A. Mode Mutual Exclusivity

- When `isTotalAssetsValid() == true` (sync mode):
  - `syncDeposit()` must succeed (if other conditions met: Open state, whitelisted, not paused)
  - `requestDeposit()` must revert with `OnlySyncDepositAllowed`
- When `isTotalAssetsValid() == false` (async mode):
  - `requestDeposit()` must succeed (if other conditions met)
  - `syncDeposit()` must revert with `OnlyAsyncDepositAllowed`
- `isTotalAssetsValid()` returns `block.timestamp < totalAssetsExpiration`

### B. Synchronous Deposit Accounting

- After `syncDeposit(assets)`:
  - `totalAssets_new = totalAssets_old + assets`
  - `totalSupply_new = totalSupply_old + shares_minted`
  - Shares minted: `shares = assets × (totalSupply + 10^decimalsOffset) / (totalAssets + 1)` (current rate, not epoch-based)
  - Assets transferred directly to Safe (NOT to Silo)
  - Receiver balance increases by `shares`
  - Event `DepositSync(sender, receiver, assets, shares)` emitted

### C. Epoch System Isolation

- `syncDeposit()` must NOT increment `depositEpochId` (only `updateNewTotalAssets()` does)
- `syncDeposit()` must NOT interact with Silo balances
- `syncDeposit()` must NOT create pending requests in epoch mappings
- Sync deposits are "instant settlement" - no request ID, no claimable amounts

### D. NAV Expiration State Machine

- After `settleDeposit()` or `settleRedeem()`: `totalAssetsExpiration = block.timestamp + totalAssetsLifespan`
- `totalAssetsLifespan` is set by Safe via `updateTotalAssetsLifespan(lifespan)`
- Safe can manually expire NAV via `expireTotalAssets()` (sets `totalAssetsExpiration = 0`)
- When NAV is valid, `updateNewTotalAssets()` must revert with `ValuationUpdateNotAllowed`
- Valuation manager can only update NAV after Safe expires it (forces async mode first)

### E. State and Access Control

- `syncDeposit()` requires `state == Open` (forbidden in Closing/Closed even if NAV valid)
- `syncDeposit()` requires whitelist check (same as async flow)
- `syncDeposit()` forbidden when paused
- Only Safe can call `updateTotalAssetsLifespan()` and `expireTotalAssets()`

**Why Critical**: High-frequency operation that bypasses epoch-based pricing safety nets. Mode confusion could enable arbitrage between instant and delayed pricing. Direct `totalAssets` mutation requires careful verification.

**Implementation Notes**:

- **High priority**: Check on every `syncDeposit()` call and every `requestDeposit()` call
- Event tracking: `DepositSync(sender, receiver, assets, shares)` for sync deposits
- Balance verification: Safe balance increases (not Silo) after `syncDeposit()`
- Compare `isTotalAssetsValid()` before and after operations to detect expiration changes
- Track `totalAssetsExpiration` and `totalAssetsLifespan` changes via `TotalAssetsLifespanUpdated` event
- Mode checks are more critical than state transition checks (high frequency vs rare events)

**Interaction with Other Tier 1 Invariants**:

- **Invariant 1 (Total Assets)**: Add check after `syncDeposit()` that `totalAssets` increased by `assets`
- **Invariant 2 (Epochs)**: Verify `syncDeposit()` does NOT increment `depositEpochId`
- **Invariant 3 (Silo)**: Verify `syncDeposit()` does NOT increase Silo asset balance
- Safe balance verification ties to accounting integrity

---

## 5. NAV Validity and Expiration Lifecycle [TIER 1] - v0.5.0 ONLY

**Applies to**: v0.5.0 only

**Description**: v0.5.0 introduces a time-based NAV expiration system that controls mode switching. The `totalAssetsExpiration` timestamp determines whether sync or async deposits are allowed. This is a frequently-checked invariant (on every deposit operation).

**Invariant Rules**:

### A. Expiration Timestamp Management

- After `settleDeposit()` completes: `totalAssetsExpiration = block.timestamp + totalAssetsLifespan`
- After `settleRedeem()` completes: `totalAssetsExpiration = block.timestamp + totalAssetsLifespan`
- `totalAssetsLifespan` defaults to 0 (async-only mode, like v0.4.0)
- Safe can set `totalAssetsLifespan` to non-zero value (e.g., 1000 seconds) to enable sync mode after next settlement
- Safe can call `expireTotalAssets()` to immediately set `totalAssetsExpiration = 0` (forces async mode)

### B. Validity Check Consistency

- `isTotalAssetsValid()` must return `block.timestamp < totalAssetsExpiration`
- When `totalAssetsExpiration == 0`: always returns `false` (async mode)
- When `totalAssetsExpiration > 0` and `block.timestamp >= totalAssetsExpiration`: returns `false` (expired)
- When `totalAssetsExpiration > block.timestamp`: returns `true` (sync mode active)

### C. Access Control for NAV Updates

- When `isTotalAssetsValid() == true`: `updateNewTotalAssets()` must revert with `ValuationUpdateNotAllowed`
- When `isTotalAssetsValid() == false`: `updateNewTotalAssets()` allowed (if called by valuationManager)
- Safe must call `expireTotalAssets()` before valuation manager can update NAV during sync window
- This prevents NAV updates while users are doing instant sync deposits at current rate

### D. Event Tracking

- `TotalAssetsLifespanUpdated(oldLifespan, newLifespan)` emitted when Safe changes lifespan
- `TotalAssetsUpdated(newTotalAssets)` emitted when NAV is updated and expiration is set

**Why Critical**: Mode checks happen on every deposit operation. Expiration state determines which deposit functions are available and prevents NAV updates during sync deposit window.

**Implementation Notes**:

- **High priority**: Check `isTotalAssetsValid()` result matches expected mode before deposit operations
- Verify `totalAssetsExpiration` is set correctly after settlements (if `totalAssetsLifespan > 0`)
- Track Safe's calls to `updateTotalAssetsLifespan()` and `expireTotalAssets()`
- Less critical: Deep validation of expiration math (trusted Safe controls this)
- Focus on: mode enforcement (sync/async mutual exclusivity) rather than timestamp arithmetic

---

## Implementation Priority Order

### Phase 1: v0.5.0 Tier 1 (Start Here)

1. **Synchronous Deposit Mode Integrity** (Invariant 4) - HIGHEST PRIORITY, most complex
2. **NAV Validity and Expiration Lifecycle** (Invariant 5) - Mode switching control
3. **Total Assets Accounting** (Invariant 1 with v0.5.0 syncDeposit additions)
4. **Epoch Settlement Ordering** (Invariant 2 with v0.5.0 syncDeposit checks)
5. **Silo Balance Consistency** (Invariant 3 with v0.5.0 Safe routing checks)

### Phase 2: v0.4.0 Tier 1 (Backport)

1. **Total Assets Accounting** (Invariant 1 without syncDeposit)
2. **Epoch Settlement Ordering** (Invariant 2 without syncDeposit checks)
3. **Silo Balance Consistency** (Invariant 3 async-only version)

---

## General Implementation Guidelines

### Induction-Based Verification Pattern

Many invariants reference global sums (e.g., "vault balance >= Σ(all users' claimable requests)") which are impossible to verify directly since we cannot enumerate all users from contract storage. Instead, we use **induction-based verification**: verify that each incremental change is consistent, which implies the global invariant holds over time.

**Pattern**: For each transaction, track only the users/state affected in THIS transaction (via events), and verify:

```
Δ(global_state) == Σ(individual_changes_from_events)
```

**Example**: To verify `siloBalance >= Σ(pending requests)`:

1. Parse events: DepositRequest (+assets), DepositRequestCanceled (-assets), SettleDeposit (-assets)
2. Calculate expected: `Δ(silo) = requests_added - requests_canceled - requests_settled`
3. Verify: `postSiloBalance - preSiloBalance == Δ(silo)`

If every transaction maintains consistency, the global invariant holds by induction. This approach only requires parsing events from the current transaction (~1-10 events), making it gas-efficient and feasible for runtime assertions.

### Trigger Functions

- **Invariant 1** (v0.4.0 & v0.5.0): Trigger on `settleDeposit()`, `settleRedeem()`, `close()`, and `syncDeposit()` (v0.5.0 only)
- **Invariant 2** (v0.4.0 & v0.5.0): Trigger on `updateNewTotalAssets()`, `settleDeposit()`, `settleRedeem()`, and `syncDeposit()` (v0.5.0 only)
- **Invariant 3** (v0.4.0 & v0.5.0): Trigger on `requestDeposit()`, `settleDeposit()`, `cancelRequestDeposit()`, and `syncDeposit()` (v0.5.0 only)
- **Invariant 4** (v0.5.0 only): Trigger on `syncDeposit()` and `requestDeposit()`
- **Invariant 5** (v0.5.0 only): Trigger on `settleDeposit()`, `settleRedeem()`, `updateTotalAssetsLifespan()`, and `expireTotalAssets()`
