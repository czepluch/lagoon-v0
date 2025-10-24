# Lagoon v0.5.0 Assertions - Test Coverage Plan

## Current Coverage: ~70%
- ✅ Happy paths: 95% (64 tests)
- ⚠️ Edge cases: 50% (30 tests)
- ⚠️ Stress testing: 10%
- ❌ Fuzzing: 0%

---

## Phase 1: Critical Gaps (Priority 1)

### 1. Fee Integration Testing
**File:** `FeesIntegrationAssertion.t.sol` (new file created)

- [x] Test settleDeposit accounting with management fees enabled ✅ **DONE**
- [x] Test settleRedeem accounting with management fees enabled ✅ **DONE**
- [x] Test settleDeposit accounting with performance fees enabled ✅ **DONE**
- [x] Test settleRedeem accounting with performance fees enabled ✅ **DONE**
- [x] Test vault solvency with both fee types enabled ✅ **DONE**
- [x] Test syncDeposit accounting with fees (verify fees don't affect sync deposits) ✅ **DONE**
- [ ] Fuzz: Fee rates (0-10000 basis points) on deposit/redeem

**Rationale:** All current tests use 0% fees. Production vaults will have fees, and accounting must remain correct.

**Key Learnings:**
- Fees are calculated on NEW totalAssets after `_updateTotalAssets()`, not baseline
- Settlement flow: `_updateTotalAssets(newVal)` → `_takeFees()` → `_settle*()`
- Fees use share dilution model (mints shares, totalAssets unchanged)
- Need two-settlement baseline approach to establish clean lastFeeTime
- Simplified test pattern works well: focus on assertion passing, not detailed fee validation (90 lines vs 160 lines)
- For fresh vaults via factory: must whitelist users, safe, silo, feeReceiver, dao, and feeRegistry
- syncDeposit requires valid NAV: extend totalAssetsLifespan before warping time

---

### 2. Batched Operations
**Files:** `BatchedOperations.t.sol` (new file created)

- [x] Test multiple syncDeposit calls in single transaction ✅ **DONE**
- [x] Test multiple requestDeposit calls in single transaction ✅ **DONE**
- [x] Test deposit (claim) + requestRedeem in single transaction ✅ **DONE**
- [x] Test settle + new requests in same transaction ✅ **SKIPPED** - Safe doesn't batch transactions
- [ ] Fuzz: Number of batched operations (1-10 operations)

**Rationale:** Code has TODOs about batched operations. Verify assertions handle multiple calls correctly.

**Coverage:** 3 tests using helper contract pattern. Assertions correctly accumulate changes across batched calls.

**Key Finding:** Assertions monitor single function selector and cannot track multi-operation interactions (e.g., syncDeposit + claimSharesAndRequestRedeem). This is a fundamental design limitation requiring multi-selector support to address.

---

### 3. Multi-Decimal Token Support
**File:** `MultiDecimalTokenSupport.t.sol` (new file created)

- [x] Test 18-decimal tokens (WETH-like) ✅ **DONE**
- [x] Test 8-decimal tokens (WBTC-like) ✅ **DONE**
- [x] Test 0-decimal tokens (edge case) ✅ **DONE**
- [x] Test decimalsOffset calculation ✅ **DONE**
- [ ] Fuzz: Asset decimals (0-18) on all operations

**Rationale:** Only 6-decimal USDC tested. Validate assertions work with varying token decimals.

**Coverage:** 13 tests covering settleDeposit, settleRedeem, syncDeposit, and SiloBalance assertions across 0, 6, 8, and 18-decimal tokens. All tests pass.

**Key Finding:** Vault stores `decimalsOffset` as exponent (e.g., 18 for 0-decimal token), calculated as `18 - tokenDecimals`. The actual offset used in formulas is `10 ** decimalsOffset`. All shares normalized to 18 decimals regardless of underlying asset decimals.

---

### 4. Time Boundary Conditions
**Files:** `SyncDepositModeAssertion_v0.5.0.t.sol`, `NAVValidityAssertion_v0.5.0.t.sol`

- [ ] Test syncDeposit at exact expiration moment (block.timestamp == expiration)
- [ ] Test isTotalAssetsValid() at exact boundary
- [ ] Test mode switch at exact expiration
- [ ] Test settlement at epoch transition boundaries
- [ ] Test NAV update at exact expiration moment
- [ ] Fuzz: Timestamps around expiration (±10 seconds)

**Rationale:** Boundary conditions often reveal off-by-one errors and edge case bugs.

---

## Phase 2: Important Edge Cases (Priority 2)

### 5. Airdrop/Donation Scenarios
**File:** `SiloBalanceConsistencyAssertion.t.sol`

- [x] Test Silo asset balance with airdropped tokens ✅ **DONE**
- [x] Test Silo share balance with donated shares ✅ **DONE**
- [x] Test Safe balance with airdrops ✅ **DONE**
- [x] Test settlement with airdropped tokens ✅ **DONE**
- [x] Test airdrop during requestDeposit ✅ **DONE**
- [ ] Fuzz: Airdrop amounts (0-1000e6)

**Rationale:** Ensure assertions tolerate airdrops/donations without false positives.

**Coverage:** 5 tests covering asset airdrops, share donations, and various timing scenarios. All 18 SiloBalanceConsistency tests pass (15 main + 3 mock).

**Key Finding:** Fixed assertion bug by changing `==` to `>=` in settle deposit/redeem checks. Vault takes ALL Silo assets during settlement (including airdrops). The `>=` operator allows Silo to have MORE than expected (airdrops) while still catching LESS than expected (theft/bugs).

---

### 6. Partial Settlement Testing
**Files:** `SiloBalanceConsistencyAssertion.t.sol`, `TotalAssetsAccountingAssertion_v0.5.0.t.sol`

- [ ] Test settleDeposit with only partial requests settled (some remain)
- [ ] Test settleRedeem with only partial redeems settled
- [ ] Test Silo balance consistency during partial settlements
- [ ] Test multiple partial settlements in sequence
- [ ] Fuzz: Percentage of requests settled (10-100%)

**Rationale:** Current tests only cover full settlements or zero settlements, not partial.

---

### 7. Rapid State Transitions
**Files:** `EpochInvariantsAssertion.t.sol`, `SyncDepositModeAssertion_v0.5.0.t.sol`, `NAVValidityAssertion_v0.5.0.t.sol`

- [ ] Test 5+ sequential epoch increments
- [ ] Test rapid sync ↔ async mode switching
- [ ] Test multiple NAV updates in quick succession
- [ ] Test epoch parity maintained across 10+ transitions
- [ ] Test mixed sync/async operations in same epoch
- [ ] Fuzz: Number of state transitions (1-20)

**Rationale:** Stress test state machine logic to ensure no corruption during rapid changes.

---

### 8. Extreme Value Testing
**Files:** All test files

- [ ] Test totalSupply near uint256 max
- [ ] Test totalAssets near uint256 max
- [ ] Test share calculation precision with extreme values
- [ ] Test epoch IDs near uint40 max (overflow edge)
- [ ] Test lifespan near uint128 max
- [ ] Test zero amount operations (edge case)
- [ ] Fuzz: Large values (1e30 to 1e50)

**Rationale:** Overflow and precision errors often occur at extreme values.

---

## Phase 3: Fuzzing Campaign (Priority 1.5 - Revised)

### 9. Fuzz Assertion-Specific Logic (Not Protocol Logic)
**New File:** `FuzzCriticalAssertions.t.sol`

**Fuzzing Philosophy**: Focus on assertions that contain **complex arithmetic, boundary checks, or accumulation logic**. Skip assertions that are simple comparisons of protocol values (those test protocol correctness, not assertion correctness).

#### Priority 1: Share Calculation Arithmetic ⭐⭐⭐
**File**: `SyncDepositModeAssertion_v0.5.0.t.sol`
- [ ] Fuzz `assertionSyncDepositAccounting`: share calculation with varying `assets` (1-1e30), `totalSupply` (1e6-1e30), `totalAssets` (1e6-1e30)
- [ ] Fuzz extreme ratios: `totalSupply/totalAssets` ratios from 0.001 to 1000
- [ ] Fuzz decimalsOffset: test with 0, 6, 8, 18-decimal tokens
- [ ] Fuzz edge case: `totalSupply` or `totalAssets` near zero
- [ ] Fuzz rounding: amounts that trigger different `Math.Rounding` behaviors

**Rationale**: Complex share math `assets * (totalSupply + decimalsOffset) / totalAssets` is prone to precision errors, overflow, and rounding issues. **This is assertion-specific logic.**

---

#### Priority 2: Time Boundary Conditions ⭐⭐⭐
**Files**: `NAVValidityAssertion_v0.5.0.t.sol`, `SyncDepositModeAssertion_v0.5.0.t.sol`
- [ ] Fuzz `assertionNAVValidity`: `timestamp` vs `expiration` boundary (expiration ± 1000 seconds)
- [ ] Fuzz `assertionSyncDepositMode`: NAV expiration exactly at `block.timestamp`
- [ ] Fuzz `assertionRequestDepositMode`: mode switching at exact boundary
- [ ] Fuzz lifespan edge cases: 0, 1, `type(uint128).max`
- [ ] Fuzz timestamp wraparound: test with `block.timestamp` near `type(uint256).max`

**Rationale**: Boundary checks (`<=` vs `<`) are common bug sources. Off-by-one errors could allow invalid operations. **Assertions contain the boundary logic.**

---

#### Priority 3: Silo Balance Accumulation ⭐⭐
**File**: `SiloBalanceConsistencyAssertion.t.sol`
- [ ] Fuzz `assertionSyncDepositSiloIsolation`: multiple deposits (1-100), varying amounts (1-1e12 each)
- [ ] Fuzz `assertionRequestDepositSilo`: 1-1000 pending requests, random amounts
- [ ] Fuzz partial settlements: settle random percentage (10-100%) of requests
- [ ] Fuzz with airdrops: add random airdrop (0-1e12) to Silo before settlement
- [ ] Fuzz accumulation errors: many small amounts (1 wei each) vs few large amounts

**Rationale**: Summing many requests risks accumulation errors. Silo >= sum(requests) logic is in the assertion. **Tests assertion's calculation logic.**

---

#### Priority 4: Multi-Decimal Token Support ⭐⭐
**Files**: All assertion test files
- [ ] Fuzz decimalsOffset calculation: asset decimals (0-18), verify `10^(18-decimals)` correctness
- [ ] Fuzz share/asset conversions: test with 0, 2, 6, 8, 12, 18-decimal tokens
- [ ] Fuzz precision loss: extreme amounts with different decimals (1 wei to 1e30)
- [ ] Fuzz edge case: 0-decimal token (rare but valid ERC20)

**Rationale**: Decimal conversions can lose precision. While not many calculations in assertions, decimalsOffset is used in share math. **Tests assertion's handling of decimals.**

---

#### ~~Priority 5: Simple Comparisons~~ ❌ **SKIP**
**Why Skip**: The following are **simple equality checks** that test **protocol correctness**, not assertion logic:
- ❌ Total Assets Accounting: `postTotalAssets == newTotalAssets ± delta` (no assertion math)
- ❌ Epoch Increments: `postEpochId == preEpochId + 1` (trivial check)
- ❌ Vault Solvency: `totalAssets >= minRequired` (protocol provides values)
- ❌ Fee rates: All fee logic is in protocol, assertions just check totals

---

### Fuzzing Strategy (Revised)
1. **Foundry Invariant Testing**: Use `forge-std/InvariantTest.sol` for stateful fuzzing
2. **Runs**: 10,000+ runs per fuzz test (use `--runs` flag)
3. **Seed Failures**: Use `vm.assume()` to skip invalid inputs, save failing seeds
4. **Focus**: Fuzz inputs that **assertions calculate with**, not inputs assertions just compare
5. **Bounded Fuzzing**: Use `bound()` to constrain values to realistic ranges (avoid pure random noise)

Example structure:
```solidity
function testFuzz_SyncDepositShareCalculation(
    uint256 assets,
    uint256 totalSupply,
    uint256 totalAssets
) public {
    // Bound inputs to realistic ranges
    assets = bound(assets, 1, 1e30);
    totalSupply = bound(totalSupply, 1e6, 1e30);
    totalAssets = bound(totalAssets, 1e6, 1e30);

    // Setup vault state
    // ...

    // Execute syncDeposit with assertion
    // ...

    // Assertion should pass for all valid inputs
}
```

---

## Phase 4: Optional Enhancements (Priority 3)

### 10. Stress Testing
**New File:** `StressTestAssertions.t.sol`

- [ ] Test 100+ users with concurrent deposit requests
- [ ] Test 100+ users with concurrent redeem requests
- [ ] Test gas consumption on large operations
- [ ] Test event log parsing with 1000+ events
- [ ] Test settlement of 100+ pending requests

---

### 11. Upgrade Scenario Testing
**New File:** `UpgradeScenarioAssertions.t.sol`

- [ ] Test assertions run correctly post-upgrade
- [ ] Test state migration doesn't break invariants
- [ ] Test v0.4.0 → v0.5.0 upgrade path
- [ ] Test assertions against upgraded mock implementations

---

### 12. Additional Edge Cases
**Files:** Various

- [ ] Test exact cancel amount verification (addresses TODO in SiloBalanceConsistency)
- [ ] Test multiple users canceling in same epoch
- [ ] Test reentrancy scenarios (if applicable)
- [ ] Test assertions with paused vault
- [ ] Test assertions with whitelisting enabled/disabled

---

## Test File Organization

**Existing files to extend:**
- `TotalAssetsAccountingAssertion_v0.5.0.t.sol` (add #1, #2, #3)
- `TotalAssetsAccountingAssertion_v0.5.0Mock.t.sol` (extend with new violations)
- `EpochInvariantsAssertion.t.sol` (add #7)
- `EpochInvariantsAssertionMock.t.sol` (extend with new violations)
- `SiloBalanceConsistencyAssertion.t.sol` (add #5, #6, #12)
- `SiloBalanceConsistencyAssertionMock.t.sol` (extend with new violations)
- `SyncDepositModeAssertion_v0.5.0.t.sol` (add #2, #4, #7)
- `SyncDepositModeAssertion_v0.5.0Mock.t.sol` (extend with new violations)
- `NAVValidityAssertion_v0.5.0.t.sol` (add #4, #7, #8)
- `NAVValidityAssertionMock_v0.5.0.t.sol` (extend with new violations)

**New files to create:**
- `FuzzCriticalAssertions.t.sol` (#9 - fuzzing campaign)
- `FeesIntegrationAssertion.t.sol` (#1 - fee-specific tests)
- `StressTestAssertions.t.sol` (#10 - stress testing)
- `UpgradeScenarioAssertions.t.sol` (#11 - upgrade testing)

---

## Execution Timeline

**Week 1-2: Phase 1 (Critical)**
- Days 1-3: Fee integration tests (#1)
- Days 4-5: Batched operations (#2)
- Days 6-7: Multi-decimal tokens (#3)
- Days 8-10: Time boundaries (#4)

**Week 3: Phase 3 (Fuzzing)**
- Days 1-3: Set up fuzzing infrastructure
- Days 4-7: Implement all fuzz tests (#9)

**Week 4: Phase 2 (Important)**
- Days 1-2: Airdrop scenarios (#5)
- Days 3-4: Partial settlements (#6)
- Days 5-6: Rapid transitions (#7)
- Day 7: Extreme values (#8)

**Week 5+: Phase 4 (Optional)**
- As needed for production readiness

---

## Success Metrics

- [ ] All Phase 1 tests passing (100% coverage of critical gaps)
- [ ] Fuzzing campaign complete (1000+ runs per invariant)
- [ ] All Phase 2 tests passing (80% edge case coverage)
- [ ] No assertion false positives found
- [ ] No assertion false negatives found (mock tests catch all violations)
- [ ] Test suite runs in < 5 minutes

**Target Overall Coverage: 90%+**
