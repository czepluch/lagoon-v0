# Lagoon v0.4.0 Protocol Invariants

> **Note**: These invariants are specific to **v0.4.0**. Version v0.5.0 introduces synchronous deposits and NAV expiration features that are not covered here.

## Protocol Overview

Lagoon v0.4.0 is an **ERC7540 asynchronous tokenized vault** that implements a request-settle-claim pattern for deposits and redemptions. The protocol uses an epoch-based system where users request deposits/redeems, a trusted Safe settles these requests after valuation updates, and users can then claim their shares or assets.

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

### 1. Total Assets Accounting Integrity

**Description**: The vault's `totalAssets` is an accounting variable representing Net Asset Value (NAV), set by the valuation manager. During Open/Closing states, it does NOT equal physical balances since the Safe invests assets into external strategies (DeFi protocols, RWAs, etc.). We verify accounting consistency across settlements, not physical balance equality (except when Closed).

**Invariant Rules**:

**A. Accounting Conservation (All States)**

- After `settleDeposit()`: `totalAssets_new = totalAssets_old + pendingAssets`
- After `settleRedeem()`: `totalAssets_new = totalAssets_old - assetsWithdrawn`
- Track settlement events (`SettleDeposit`, `SettleRedeem`) to verify accounting changes match event data
- Fee minting increases `totalSupply` but does not directly change `totalAssets` (fees dilute via share issuance)

**B. Physical Balance Verification (Closed State Only)**

- When `state == Closed`: `IERC20(asset).balanceOf(vault) == totalAssets`
- When `state == Open` or `Closing`: No relationship between Safe balance and totalAssets (Safe invests in strategies)

**C. Solvency (Can Fulfill Claimable Redemptions)**

- After `settleRedeem()`, assets are transferred from Safe to Vault and totalAssets is reduced
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
- Only verify vault balance equals totalAssets when state is Closed
- Monitor solvency: vault balance must cover claimable redemptions

---

### 2. Epoch Settlement Ordering and Claimability

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

### 3. Fee Calculation Integrity

**Description**: Management and performance fees must be calculated correctly and bounded by maximum rates. Fees are taken during settlement and minted as shares (dilutes existing holders). High trust assumption - the valuation manager controls inputs to fee calculations.

**Invariant Rules**:

- Management fee rate: `0 <= managementRate <= MAX_MANAGEMENT_RATE` (1000 bps = 10%)
- Performance fee rate: `0 <= performanceRate <= MAX_PERFORMANCE_RATE` (5000 bps = 50%)
- Protocol fee rate: `0 <= protocolRate <= MAX_PROTOCOL_RATE` (3000 bps = 30%)
- Management fees: `managementFees = totalAssets × managementRate × timeElapsed / (BPS_DIVIDER × ONE_YEAR)`
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

### 4. Silo Balance Consistency

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

### 5. State Transition and Access Control

**Description**: The vault progresses through three states (Open → Closing → Closed) with strict unidirectional transitions. Critical functions must only be callable by authorized roles. Runtime checks valuable for detecting upgrade-introduced bugs.

**Invariant Rules**:

- **State Transitions**: `Open → Closing → Closed` (unidirectional, no reversals or skipping)
- State can only increase or stay same: `stateAfter >= stateBefore`
- Cannot skip states: if `stateAfter > stateBefore`, then `stateAfter == stateBefore + 1`

**State-Specific Restrictions**:

- **Open State**: Async deposits and redeems allowed, settlements process normally
- **Closing State**: Initiated by Owner via `initiateClosing()`, no new deposit settlements allowed, redeems still allowed
- **Closed State**: All assets transferred from Safe to Vault (`vault.balanceOf(asset) == totalAssets`), users can synchronously redeem/withdraw at fixed price per share, no async operations

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

### 6. ERC4626 Max Function Bounds

**Description**: The vault's `max*` view functions (`maxDeposit`, `maxMint`, `maxWithdraw`, `maxRedeem`) promise users the maximum amount they can claim. Users must never be able to exceed these bounds.

**Invariant Rules**:

- After claiming via `deposit()`: `sharesClaimed <= maxDeposit(controller)` (converted to shares)
- After claiming via `mint()`: `sharesClaimed <= maxMint(controller)`
- After claiming via `withdraw()`: `assetsClaimed <= maxWithdraw(controller)`
- After claiming via `redeem()`: `assetsClaimed <= maxRedeem(controller)` (converted to assets)
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

### 7. Share-to-Asset Conversion Rate Locking and Rounding

- Conversion rates at a specific epoch must remain constant after settlement
- `convertToShares(assets, epochId)` and `convertToAssets(shares, epochId)` must be inverse operations within 1 wei rounding
- Rounding must favor the vault: users may receive up to 1 wei less, never more (vault keeps dust)
- Prevents rounding exploitation for arbitrage attacks

### 8. Request Uniqueness

- Users can only have one pending deposit request at a time: `pendingDepositRequest(0, user) > 0` prevents new requests
- Users can only have one pending redeem request at a time: `pendingRedeemRequest(0, user) > 0` prevents new requests
- Prevents accounting confusion and potential double-spending attacks

### 9. Pausability

- When paused, all deposit, redeem, settlement, and request operations must revert
- Only owner can call `pause()` and `unpause()`
- Emergency brake to halt operations during incidents

### 10. Whitelist Enforcement

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
- Track: `SettleDeposit`, `SettleRedeem`, `DepositRequest`, `RedeemRequest`, `HighWaterMarkUpdated`, `StateUpdated`

### Balance Checks (Secondary Method)

- Use as sanity checks with tolerance for edge cases
- Allow `>=` for airdrops/donations to Silo
- Only exact equality for Closed state vault balance

### Gas Optimization

- Check basic invariants first (fail fast with early returns)
- Avoid expensive operations in loops
- Target < 100k gas per assertion function

### Upgrade Protection Focus

- Critical variable initialization checks
- Storage slot preservation verification
- State machine integrity
- Access control consistency
