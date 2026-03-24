# SCV-Scan Report — weETH Looping Vault

## Phase 1: Cheatsheet Loaded
36 vulnerability classes scanned against 4 contracts.

## Phase 2: Codebase Sweep

### Pass A: Syntactic Grep Results
| Pattern | Matches | Files |
|---------|---------|-------|
| `.call{value}` | 2 | LoopVault:228, KeeperModule:168 |
| `nonReentrant` | 8 | LoopVault(6), LoopStrategy(3) |
| `assembly` | 1 | LoopVault:102 (tload) |
| `block.timestamp` | 8 | LoopVault(4), KeeperModule(3), LoopStrategy(1) |
| `approve(max)` | 4 | LoopStrategy:91-94, LoopVault:124 |
| `initializer` | 1 | LoopVault:111 |
| `safeTransfer` | 3 | LoopStrategy:116,182,214 |
| `delegatecall/tx.origin/selfdestruct` | 0 | — |
| `ecrecover/abi.encodePacked` | 0 | — |
| `unchecked/uint8(` | 0 | — |

### Pass B: Semantic Analysis
9 candidates identified for deep validation.

## Phase 3: Deep Validation

### Candidate 1: LoopVault.sol L228 — ETH transfer via .call{value}
- **Suspected:** Reentrancy
- **Validation:** `completeWithdraw` has `nonReentrant`. State updated BEFORE call (delete queue, burn shares, update idle). CEI pattern followed.
- **Result:** FALSE POSITIVE — guarded by nonReentrant + CEI.

### Candidate 2: KeeperModule.sol L168 — Tip via .call{value}
- **Suspected:** Unchecked return value, Unbounded return data
- **Validation:** Return value checked (`if (ok)`), silent failure intentional (comment L172). State already finalized before tip. No reentrancy risk (state updated before call).
- **Result:** LOW — intentional design. Keeper could grief by reverting receive() but only harms themselves.

### Candidate 3: LoopVault.sol L102 — assembly { tload }
- **Suspected:** Unsupported opcodes
- **Validation:** `tload` is Cancun-only. Constructor checks this — if deployed on non-Cancun chain, deployment reverts. Documented in comments.
- **Result:** INFORMATIONAL — deployment guard present.

### Candidate 4: LoopVault.sol L253 — block.timestamp for epoch
- **Suspected:** Timestamp dependence
- **Validation:** Used for 7-day epoch windows. Validator manipulation (~15s) is irrelevant for 7-day periods. No randomness involved.
- **Result:** FALSE POSITIVE — safe for large time windows.

### Candidate 5: LoopStrategy.sol L91-94 — approve(type(uint256).max)
- **Suspected:** Approve race condition
- **Validation:** Approvals set in constructor to immutable trusted contracts (Morpho, EtherFi, swap router). No user-controlled approval targets. Standard pattern.
- **Result:** FALSE POSITIVE — trusted immutable targets.

### Candidate 6: LoopStrategy.sol L224 — Flashloan callback
- **Suspected:** Reentrancy via callback
- **Validation:** `onMorphoFlashLoan` called by Morpho during active `nonReentrant` lock on parent function. Callback has `msg.sender == morpho` check. No nonReentrant on callback itself — correct, since it runs within parent's lock scope.
- **Result:** FALSE POSITIVE — by design. Morpho is trusted immutable.

### Candidate 7: LoopVault.sol L188 — Round-up division
- **Suspected:** Precision / off-by-one
- **Validation:** `(shares * 10000 + totalSupply() - 1) / totalSupply()`. Division by zero impossible (shares > 0 implies totalSupply > 0). Round-up is intentional (H-4 fix). Max error: 1 bps.
- **Result:** FALSE POSITIVE — correct implementation.

### Candidate 8: LoopVault.sol L111 — initializer
- **Suspected:** Missing access control on initialize
- **Validation:** `initializer` modifier present from OZ. Can only be called once. UUPS proxy pattern correctly disables initializers in constructor.
- **Result:** FALSE POSITIVE — properly guarded.

### Candidate 9: LoopStrategy.sol L274-276 — Swap minAmountOut
- **Suspected:** Frontrunning / insufficient slippage protection
- **Validation:** `minOut = collToWithdraw * peg / WAD * 97 / 100`. Uses Chainlink oracle peg (manipulation-resistant). 3% tolerance. Multiplication before division (correct precision order).
- **Result:** FALSE POSITIVE — oracle-based slippage protection adequate.

## Phase 4: Report

### Confirmed Findings

### Unchecked Return Value — Keeper Tip

**File:** `src/KeeperModule.sol` L168
**Severity:** Low

**Description:** `_payTip()` sends ETH via `.call{value}` and silently ignores failure. A keeper contract that reverts on receive() would execute actions without receiving tips.

**Code:**
```solidity
(bool ok,) = msg.sender.call{value: KEEPER_TIP}("");
if (ok) {
    emit TipPaid(msg.sender, KEEPER_TIP);
}
// Don't revert if tip fails
```

**Recommendation:** Intentional design choice (documented). No fix needed — keeper is whitelisted and trusted.

---

### Cancun EVM Dependency

**File:** `src/LoopVault.sol` L102
**Severity:** Informational

**Description:** Contract uses `tload` opcode which requires Cancun EVM. Deployment on non-Cancun chains will revert.

**Recommendation:** Already guarded in constructor. Document deployment requirement.

---

## Summary

| Severity | Count |
|----------|-------|
| Critical | 0     |
| High     | 0     |
| Medium   | 0     |
| Low      | 1     |
| Info     | 1     |

**Overall:** Codebase is well-hardened. All major vulnerability classes checked — no exploitable findings. Previous audit rounds (Round 1: 25 fixes, Round 2: 5 fixes) effectively addressed all critical patterns.
