# Lagoon Protocol Invariants

> **Coverage**: This document covers both **v0.4.0** (async-only) and **v0.5.0** (adds synchronous deposits and NAV expiration). v0.4.0-specific invariants are in sections 1-10. v0.5.0 additions are in section 11.

## Protocol Overview

### v0.4.0 (Async-Only)

Lagoon v0.4.0 is an **ERC7540 asynchronous tokenized vault** that implements a request-settle-claim pattern for deposits and redemptions. The protocol uses an epoch-based system where users request deposits/redeems, a trusted Safe settles these requests after valuation updates, and users can then claim their shares or assets.

### v0.5.0 (Adds Synchronous Deposits)

Version v0.5.0 adds a **synchronous deposit mode** that allows instant deposits when the NAV is fresh and valid. The vault operates in one of two mutually exclusive modes:

- **Sync Mode**: When NAV is valid (not expired), users call `syncDeposit()` for instant share minting. Async `requestDeposit()` is forbidden.
- **Async Mode**: When NAV is expired/invalid, users must use the traditional `requestDeposit()` → settle → claim flow. `syncDeposit()` is forbidden.

The Safe controls mode switching via `updateTotalAssetsLifespan()` (sets NAV validity duration) and `expireTotalAssets()` (manually expires NAV). This feature is heavily used by Turtle Protocol.

### Key Components

1. **Vault.sol** - Main vault contract combining ERC4626, ERC7540, fee management, and access control
2. **ERC7540.sol** - Core async deposit/redeem logic with epoch-based settlement
3. **FeeManager.sol** - Handles management fees (time-based) and performance fees (high water mark)
4. **Roles.sol** - Access control for Safe, Valuation Manager, Whitelist Manager, and Owner
5. **Silo.sol** - Temporary holding contract for pending deposits (assets) and redeems (shares)
6. **State System** - Vault transitions through Open → Closing → Closed states

### Architecture Patterns

- **ERC4626** (Tokenized Vault Standard) + **ERC7540** (Async Vaults)
- **OpenZeppelin Upgradeable** contracts with ERC7201 storage namespacing
- **Safe Pattern** - External Safe multisig holds protocol assets
- **Epoch-based Settlement** - Odd epochs for deposits (1, 3, 5...), even for redeems (2, 4, 6...)
- **Request-Settle-Claim Pattern** - Three-phase user flow for async operations

---

## Critical Invariants

### 1. Total Assets Accounting Integrity [TIER 1]

**Description**: The vault's `totalAssets` is an accounting variable representing Net Asset Value (NAV), set by the valuation manager. During Open/Closing states, it does NOT equal physical balances since the Safe invests assets into external strategies (DeFi protocols, RWAs, etc.). We verify accounting consistency across settlements, not physical balance equality (except when Closed).

**Invariant Rules**:

**A. Accounting Conservation (All States)**

- After `_settleDeposit()`: `totalAssets_new = totalAssets_old + pendingAssets`
- After `_settleRedeem()`: `totalAssets_new = totalAssets_old - assetsWithdrawn`
- Track settlement events (`SettleDeposit`, `SettleRedeem`) to verify accounting changes match event data
- Fee minting increases `totalSupply` but does not directly change `totalAssets` (fees dilute via share issuance)
- Use `_settleDeposit()` and `_settleRedeem()` internal functions for better coverage since they're called by both `settleDeposit()` and `settleRedeem()`

**B. Solvency (Can Fulfill Claimable Redemptions)**

- After `_settleRedeem()`, assets are transferred from Safe to Vault and totalAssets is reduced or stays equal
- Use `_settleRedeem()` for better coverage (called by both `settleRedeem()` and `settleDeposit()`)
- Vault balance must cover all claimable redemptions: `vaultBalance >= Σ(claimableRedeemRequest(user))`
- When Closed, vault balance must cover all potential redemptions at fixed price

**Why Critical**: Accounting mismatches compound over time, breaking share pricing. Insolvency means users cannot claim assets they're entitled to. Physical balance verification in Closed state prevents Safe from withdrawing user funds.

**Attack Vectors**:

- Settlement math errors accumulating across epochs
- Safe withdrawing vault balance below claimable redemptions (insolvency)
- Upgrade bugs corrupting totalAssets storage
- Valuation manager manipulation (inherent high trust assumption)

**Implementation Notes**:

- Use event tracking (`getLogs`) as primary verification method
- Compare pre-tx and post-tx totalAssets values
- Only verify vault balance equals totalAssets during `close()` function execution (not after)
- Monitor solvency: vault balance must cover claimable redemptions
- Note: Assertions cannot trigger on internal functions like `_settleDeposit()` and `_settleRedeem()`. Instead, trigger on the public/external functions that call them: `settleDeposit()`, `settleRedeem()`, and `close()`
  - This allows for specific checks for the invoking functions, if needed

---

### 2. Epoch Settlement Ordering and Claimability [TIER 1]

**Description**: The epoch-based settlement system must maintain strict ordering and state consistency. Users can only claim from settled epochs. This is especially critical for upgrade protection - ensures logic upgrades don't introduce bugs that violate epoch mechanics.

**Invariant Rules**:

- Current epoch always at least 2 ahead of last settled: `lastDepositEpochIdSettled <= depositEpochId - 2` and `lastRedeemEpochIdSettled <= redeemEpochId - 2`
- Deposit epochs must always be odd: `depositEpochId % 2 == 1`
- Redeem epochs must always be even: `redeemEpochId % 2 == 0`
- Users cannot claim from epochs where `requestId > lastEpochIdSettled`
- Once an epoch is settled, its conversion rate (totalAssets/totalSupply at settlement) is locked forever
- Calling `updateNewTotalAssets()` increments epoch IDs by 2 if there are pending requests

**Why Critical**: Epoch ordering violations allow users to claim assets/shares at incorrect conversion rates, enabling front-running attacks where users can choose favorable pricing by timing their claims. Double-claiming via epoch manipulation.

**Attack Vectors**:

- Claiming from unsettled epochs at stale prices
- Double-claiming by manipulating epoch counters
- Settlement order manipulation to cherry-pick favorable conversion rates
- Upgrade bugs that break epoch incrementing logic

**Implementation Notes**:

- These checks are especially valuable after contract upgrades
- Verify epoch parity (odd/even) is maintained across all transactions
- Check ordering invariants hold in every state transition

---

### 3. Fee Calculation Integrity [TIER 2]

**Description**: Management and performance fees must be calculated correctly and bounded by maximum rates. Fees are taken during settlement and minted as shares (dilutes existing holders). High trust assumption - the valuation manager controls inputs to fee calculations.

**Invariant Rules**:

- Management fee rate: `0 <= managementRate <= MAX_MANAGEMENT_RATE` (1000 bps = 10%)
- Performance fee rate: `0 <= performanceRate <= MAX_PERFORMANCE_RATE` (5000 bps = 50%)
- Protocol fee rate: `0 <= protocolRate <= MAX_PROTOCOL_RATE` (3000 bps = 30%)
- Management fees (in assets): `managementFeeAssets = totalAssets × managementRate × timeElapsed / (BPS_DIVIDER × ONE_YEAR)`
- Management fees converted to shares: `managementFeeShares = managementFeeAssets × totalSupply / (totalAssets - managementFeeAssets)`
- Performance fees only taken when: `pricePerShare > highWaterMark`
- Performance fees: `performanceFees = (pricePerShare - highWaterMark) × totalSupply × performanceRate / BPS_DIVIDER`
- `highWaterMark` must be monotonically increasing (never decreases)
- Total fees minted as shares: `totalShares = totalFees × totalSupply / (totalAssets - totalFees)`
- Protocol receives: `protocolShares = totalShares × protocolRate / BPS_DIVIDER`
- Manager receives: `managerShares = totalShares - protocolShares`
- Fee minting verified by checking feeReceiver and protocolFeeReceiver balance increases

**Why Critical**: Fee calculation errors can drain user funds through excessive dilution. High water mark manipulation allows double-charging performance fees. Rate bounds prevent exploitative fee structures.

**Attack Vectors**:

- Manipulating `lastFeeTime` to charge excessive management fees
- Resetting or lowering high water mark to charge duplicate performance fees
- Rounding exploitation to mint extra fee shares
- Rate cooldown bypass to apply higher rates immediately
- Valuation manager manipulation of NAV inputs (inherent trust assumption)

**Implementation Notes**:

- Event-based tracking (`HighWaterMarkUpdated`) more reliable than recalculating fees
- Cannot verify fee math is "correct" without trusting NAV inputs from valuation manager
- Focus on: rates within bounds, shares actually minted to fee receivers, high water mark never decreases
- Accept high trust in valuation manager (inherent to protocol design)

---

### 4. Silo Balance Consistency [TIER 1]

**Description**: The Silo contract is an immutable, trustless component that temporarily holds assets (for pending deposits) and shares (for pending redeems). Its balances must equal or exceed the sum of all pending requests, with tolerance for airdrops/donations.

**Invariant Rules**:

- Silo asset balance must be at least: `Σ(epochs[depositEpochId].depositRequest[user])` for all users
- Silo share balance must be at least: `Σ(epochs[redeemEpochId].redeemRequest[user])` for all users
- Silo balances can exceed sum of requests (allows for airdrops/donations)
- After `settleDeposit()`: Deposits from settled epoch transferred to Safe, but new deposits (after last valuation) remain in Silo
- After `settleRedeem()`: Shares from settled epoch burned, but shares from current epoch remain in Silo
- Users can only have one pending request per type (deposit OR redeem) at a time
- `cancelRequestDeposit()` must only work in the same epoch: `requestId == depositEpochId`

**Why Critical**: Silo accounting mismatches allow users to withdraw more than they deposited or claim shares they didn't pay for. The Silo is the staging area where user funds are vulnerable before settlement.

**Attack Vectors**:

- Claiming assets from Silo without corresponding request
- Double-spending by requesting, settling, then requesting again without claiming
- Canceling requests after epoch changes to get assets back while keeping shares

**Implementation Notes**:

- Use event-based validation (`DepositRequest`, `DepositRequestCanceled`, `RedeemRequest`) as primary method
- Calculate: `pendingDeposits = Σ(DepositRequest.assets) - Σ(DepositRequestCanceled.assets)`
- Balance checks are secondary validation (allow >= for airdrops)
- After settlement, Silo may not be empty (new requests came in after last valuation)

---

### 5. State Transition and Access Control [TIER 2]

**Description**: The vault progresses through three states (Open → Closing → Closed) with strict unidirectional transitions. Critical functions must only be callable by authorized roles. Runtime checks valuable for detecting upgrade-introduced bugs.

**Invariant Rules**:

- **State Transitions**: `Open → Closing → Closed` (unidirectional, no reversals or skipping)
- State can only increase or stay same: `stateAfter >= stateBefore`
- Cannot skip states: if `stateAfter > stateBefore`, then `stateAfter == stateBefore + 1`

**State-Specific Restrictions**:

- **Open State**: Async deposits and redeems allowed, settlements process normally
- **Closing State**: Initiated by Owner via `initiateClosing()`, no new deposit settlements allowed, redeems still allowed
- **Closed State**: All assets transferred from Safe to Vault, users can synchronously redeem/withdraw at fixed price per share, no async operations
  - Note: `requestDeposit()` is still callable when Closed (users can request and cancel), but requests cannot be settled

**Access Control**:

- Only `safe` can call: `settleDeposit()`, `settleRedeem()`, `close()`, `claimSharesOnBehalf()`
- Only `valuationManager` can call: `updateNewTotalAssets()`
- Only `owner` can call: `initiateClosing()`, `pause()`, `unpause()`, `updateRates()`, role updates

**Settlement Requirements**:

- `settleDeposit()` and `settleRedeem()` require: `newTotalAssets != type(uint256).max` (valuation manager must have updated)
- `settleDeposit()` requires: `state == Open`
- `settleRedeem()` requires: `state == Open`
- `close()` requires: `state == Closing`

**Upgrade Protection**:

- After upgrade, verify critical storage variables properly initialized (safe, valuationManager, owner not zero address)
- Verify epoch IDs maintain parity after upgrade (deposit odd, redeem even)
- Behavioral invariants ensure upgrade didn't introduce logic bugs

**Why Critical**: State transition violations allow reopening closed vaults or settling deposits after closure, breaking finality guarantees. Access control bypasses enable unauthorized settlements at manipulated prices.

**Attack Vectors**:

- Bypassing state checks to settle deposits when Closed
- Unauthorized valuation updates to manipulate share prices
- Calling settlement functions without proper authorization
- Transitioning from Closed back to Open to avoid fixed pricing
- Upgrade introducing bugs in state checks or access control

---

### 6. ERC4626 Max Function Bounds [TIER 2]

**Description**: The vault's `max*` view functions (`maxDeposit`, `maxMint`, `maxWithdraw`, `maxRedeem`) promise users the maximum amount they can claim. Users must never be able to exceed these bounds.

**Invariant Rules**:

- After claiming via `deposit()`: `assetsClaimed <= maxDeposit(controller)`
- After claiming via `mint()`: `sharesClaimed <= maxMint(controller)`
- After claiming via `withdraw()`: `assetsClaimed <= maxWithdraw(controller)`
- After claiming via `redeem()`: `sharesClaimed <= maxRedeem(controller)`
- These bounds must account for claimable requests from settled epochs
- When paused, all max functions return 0 (no operations allowed)
- When Closed and no claimable requests, max functions return user's share balance (synchronous redemption)

**Why Critical**: These functions are user-facing promises required by the ERC4626 standard. If users can exceed these limits, they can claim more than their fair share, potentially draining the vault or breaking accounting. UIs and integrations rely on these functions for correctness. The production code does NOT explicitly validate claims against max function bounds - it relies on implicit underflow protection when decrementing request amounts. This makes runtime assertion checks essential to catch edge cases in the complex max function logic (especially around state transitions and epoch conversions).

**Attack Vectors**:

- Claiming more shares/assets than promised by max functions
- Manipulating claimable request accounting to inflate max values
- Exploiting state transitions (Open → Closed) where max function logic changes
- Double-claiming by bypassing max checks through different claim paths

**Implementation Notes**:

- Production code does not explicitly check `max*()` bounds - only tests verify this invariant
- Check on every `deposit()`, `mint()`, `redeem()`, `withdraw()` call
- Compare actual claimed amount vs pre-call `max*` return value
- Account for epoch-specific conversion rates when comparing
- Verify paused state returns 0 for all max functions

---

## Additional Invariants (Secondary)

### 7. Share-to-Asset Conversion Rate Locking and Rounding [TIER 2]

- Conversion rates at a specific epoch must remain constant after settlement
- `convertToShares(assets, epochId)` and `convertToAssets(shares, epochId)` must be inverse operations within 1 wei rounding
- Rounding must favor the vault: users may receive up to 1 wei less, never more (vault keeps dust)
- Prevents rounding exploitation for arbitrage attacks

### 8. Request Uniqueness [TIER 2]

- Users can only have one pending deposit request at a time: `pendingDepositRequest(0, user) > 0` prevents new requests
- Users can only have one pending redeem request at a time: `pendingRedeemRequest(0, user) > 0` prevents new requests
- Prevents accounting confusion and potential double-spending attacks

### 9. Pausability [TIER 3]

- When paused, all deposit, redeem, settlement, and request operations must revert
- Only owner can call `pause()` and `unpause()`
- Emergency brake to halt operations during incidents

### 10. Whitelist Enforcement [TIER 3]

- When `enableWhitelist == true`, only whitelisted addresses can deposit or redeem
- Protocol fee receiver is always whitelisted (runtime check, not initialization)
- Whitelist can be disabled by Owner but not re-enabled once disabled (one-way operation)
- KYC/AML compliance for regulated vaults

---

## Implementation Guidelines for Phylax Assertions

### Reference Implementation

- Review `test/v0.4.0/Base.sol` for additional invariant examples
- Base test contract contains assertions that verify invariants after each operation:
  - `requestDeposit()`: checks pending balances and Silo accounting
  - `deposit()`/`mint()`: verifies `maxDeposit` and `maxMint` invariants
  - `settle()`: confirms epoch IDs increment correctly (by 2 when pending requests exist)
  - `redeem()`/`withdraw()`: validates `maxWithdraw` and balance changes
- These test-level checks serve as practical examples of what should hold true
- Particularly useful for understanding pre/post-state expectations

### Event-Based Validation (Primary Method)

- Use `ph.getLogs()` from credible-std to track protocol events
- More reliable than recalculating or balance checks
- Track v0.4.0 events: `SettleDeposit`, `SettleRedeem`, `DepositRequest`, `RedeemRequest`, `HighWaterMarkUpdated`, `StateUpdated`
- Track v0.5.0 events: `DepositSync`, `TotalAssetsLifespanUpdated` (see section 11-12 for details)

### Balance Checks (Secondary Method)

- Use as sanity checks with tolerance for edge cases
- Allow `>=` for airdrops/donations to Silo
- Vault balance equality checks are subject to airdrops even when Closed - use with caution

### Gas Optimization

- Check basic invariants first (fail fast with early returns)
- Avoid expensive operations in loops
- Target < 100k gas per assertion function

### Upgrade Protection Focus

- Critical variable initialization checks
- Storage slot preservation verification
- State machine integrity
- Access control consistency

---

## v0.5.0 Additional Invariants

> **Note**: These invariants apply only to v0.5.0, which introduces synchronous deposits and NAV expiration. These features are heavily used by Turtle Protocol. Focus on high-frequency checks (every `syncDeposit()`, every NAV validity check) rather than rare events.

### 11. Synchronous Deposit Mode Integrity [TIER 1 - v0.5.0 ONLY]

**Description**: v0.5.0 adds `syncDeposit()` - a synchronous deposit function that bypasses the epoch system when NAV is fresh. The vault operates in one of two mutually exclusive modes controlled by NAV validity. This is a high-frequency operation requiring robust runtime checks.

**Invariant Rules**:

**A. Mode Mutual Exclusivity**

- When `isTotalAssetsValid() == true` (sync mode):
  - `syncDeposit()` must succeed (if other conditions met: Open state, whitelisted, not paused)
  - `requestDeposit()` must revert with `OnlySyncDepositAllowed`
- When `isTotalAssetsValid() == false` (async mode):
  - `requestDeposit()` must succeed (if other conditions met)
  - `syncDeposit()` must revert with `OnlyAsyncDepositAllowed`
- `isTotalAssetsValid()` returns `block.timestamp < totalAssetsExpiration`

**B. Synchronous Deposit Accounting**

- After `syncDeposit(assets)`:
  - `totalAssets_new = totalAssets_old + assets`
  - `totalSupply_new = totalSupply_old + shares_minted`
  - Shares minted: `shares = assets × (totalSupply + 10^decimalsOffset) / (totalAssets + 1)` (current rate, not epoch-based)
  - Assets transferred directly to Safe (NOT to Silo)
  - Receiver balance increases by `shares`
  - Event `DepositSync(sender, receiver, assets, shares)` emitted

**C. Epoch System Isolation**

- `syncDeposit()` must NOT increment `depositEpochId` (only `updateNewTotalAssets()` does)
- `syncDeposit()` must NOT interact with Silo balances
- `syncDeposit()` must NOT create pending requests in epoch mappings
- Sync deposits are "instant settlement" - no request ID, no claimable amounts

**D. NAV Expiration State Machine**

- After `settleDeposit()` or `settleRedeem()`: `totalAssetsExpiration = block.timestamp + totalAssetsLifespan`
- `totalAssetsLifespan` is set by Safe via `updateTotalAssetsLifespan(lifespan)`
- Safe can manually expire NAV via `expireTotalAssets()` (sets `totalAssetsExpiration = 0`)
- When NAV is valid, `updateNewTotalAssets()` must revert with `ValuationUpdateNotAllowed`
- Valuation manager can only update NAV after Safe expires it (forces async mode first)

**E. State and Access Control**

- `syncDeposit()` requires `state == Open` (forbidden in Closing/Closed even if NAV valid)
- `syncDeposit()` requires whitelist check (same as async flow)
- `syncDeposit()` forbidden when paused
- Only Safe can call `updateTotalAssetsLifespan()` and `expireTotalAssets()`

**Why Critical**:

- **High frequency**: `syncDeposit()` is the primary deposit path when enabled (Turtle Protocol usage)
- **Immediate settlement**: Bypasses epoch-based pricing safety nets, direct exposure to NAV
- **Mode confusion**: If mutual exclusivity breaks, users can arbitrage between instant and delayed pricing
- **Accounting bypass**: Direct `totalAssets` mutation without settlement events could break accounting integrity
- **NAV manipulation**: If expiration is bypassed, valuation manager cannot update stale prices

**Attack Vectors**:

- Calling both `syncDeposit()` and `requestDeposit()` in same block (arbitrage instant vs future pricing)
- Manipulating `totalAssetsExpiration` to extend sync window indefinitely
- Using `syncDeposit()` to increment epochs (would corrupt async settlement)
- Bypassing `isTotalAssetsValid()` check to update NAV during sync mode
- Sync deposits sending assets to Silo instead of Safe (accounting mismatch)

**Implementation Notes**:

- **High priority**: Check on every `syncDeposit()` call and every `requestDeposit()` call
- Event tracking: `DepositSync(sender, receiver, assets, shares)` for sync deposits
- Balance verification: Safe balance increases (not Silo) after `syncDeposit()`
- Compare `isTotalAssetsValid()` before and after operations to detect expiration changes
- Track `totalAssetsExpiration` and `totalAssetsLifespan` changes via `TotalAssetsLifespanUpdated` event
- Mode checks are more critical than state transition checks (high frequency vs rare events)

**Interaction with v0.4.0 Invariants**:

- **Invariant 1 (Total Assets)**: Add check after `syncDeposit()` that `totalAssets` increased by `assets`
- **Invariant 2 (Epochs)**: Verify `syncDeposit()` does NOT increment `depositEpochId`
- **Invariant 4 (Silo)**: Verify `syncDeposit()` does NOT increase Silo asset balance
- **Invariant 5 (State)**: `syncDeposit()` only allowed in Open state (stricter than async)

---

### 12. NAV Validity and Expiration Lifecycle [TIER 1 - v0.5.0 ONLY]

**Description**: v0.5.0 introduces a time-based NAV expiration system that controls mode switching. The `totalAssetsExpiration` timestamp determines whether sync or async deposits are allowed. This is a frequently-checked invariant (on every deposit operation).

**Invariant Rules**:

**A. Expiration Timestamp Management**

- After `settleDeposit()` completes: `totalAssetsExpiration = block.timestamp + totalAssetsLifespan`
- After `settleRedeem()` completes: `totalAssetsExpiration = block.timestamp + totalAssetsLifespan`
- `totalAssetsLifespan` defaults to 0 (async-only mode, like v0.4.0)
- Safe can set `totalAssetsLifespan` to non-zero value (e.g., 1000 seconds) to enable sync mode after next settlement
- Safe can call `expireTotalAssets()` to immediately set `totalAssetsExpiration = 0` (forces async mode)

**B. Validity Check Consistency**

- `isTotalAssetsValid()` must return `block.timestamp < totalAssetsExpiration`
- When `totalAssetsExpiration == 0`: always returns `false` (async mode)
- When `totalAssetsExpiration > 0` and `block.timestamp >= totalAssetsExpiration`: returns `false` (expired)
- When `totalAssetsExpiration > block.timestamp`: returns `true` (sync mode active)

**C. Access Control for NAV Updates**

- When `isTotalAssetsValid() == true`: `updateNewTotalAssets()` must revert
- When `isTotalAssetsValid() == false`: `updateNewTotalAssets()` allowed (if called by valuationManager)
- Safe must call `expireTotalAssets()` before valuation manager can update NAV during sync window
- This prevents NAV updates while users are doing instant sync deposits at current rate

**D. Event Tracking**

- `TotalAssetsLifespanUpdated(oldLifespan, newLifespan)` emitted when Safe changes lifespan
- `TotalAssetsUpdated(newTotalAssets)` emitted when NAV is updated and expiration is set

**Why Critical**:

- **High frequency**: Mode checks happen on every deposit operation
- **Security boundary**: Prevents NAV updates during sync deposit window (manipulation risk)
- **Mode switching**: Expiration state determines which deposit functions are available
- If checks fail, users could be locked out of deposits or use wrong deposit method

**Attack Vectors**:

- Updating NAV while `isTotalAssetsValid() == true` (breaks sync deposit pricing)
- Preventing NAV expiration to block async settlements indefinitely
- Manipulating block.timestamp comparisons to bypass validity checks

**Implementation Notes**:

- **High priority**: Check `isTotalAssetsValid()` result matches expected mode before deposit operations
- Verify `totalAssetsExpiration` is set correctly after settlements (if `totalAssetsLifespan > 0`)
- Track Safe's calls to `updateTotalAssetsLifespan()` and `expireTotalAssets()`
- Less critical: Deep validation of expiration math (trusted Safe controls this)
- Focus on: mode enforcement (sync/async mutual exclusivity) rather than timestamp arithmetic

---

## v0.5.0 Implementation Guidelines

### High-Frequency Checks (Priority)

These checks trigger on every deposit operation and should be optimized:

1. **Mode mutual exclusivity**: Before `syncDeposit()` or `requestDeposit()`, verify only one is allowed based on `isTotalAssetsValid()`
2. **Sync deposit accounting**: After `syncDeposit()`, verify `totalAssets` increased and Safe balance increased (not Silo)
3. **Epoch isolation**: After `syncDeposit()`, verify `depositEpochId` did NOT change
4. **NAV validity check**: Verify `isTotalAssetsValid()` returns correct boolean based on `block.timestamp < totalAssetsExpiration`

### Medium-Frequency Checks

These checks trigger during settlements and Safe operations:

1. **NAV expiration update**: After settlements, verify `totalAssetsExpiration` is set correctly if `totalAssetsLifespan > 0`
2. **Lifespan updates**: Track `TotalAssetsLifespanUpdated` events from Safe
3. **Manual expiration**: Track Safe's `expireTotalAssets()` calls

### Low-Frequency Checks (Lower Priority)

These are rare or can be covered by other checks:

1. State transition checks during sync deposits (already covered by high-frequency mode checks)
2. Deep validation of timestamp arithmetic (trusted Safe controls)

### Event Tracking for v0.5.0

Add to event tracking list:

- `DepositSync(sender, receiver, assets, shares)` - every sync deposit
- `TotalAssetsLifespanUpdated(oldLifespan, newLifespan)` - Safe configuration changes
