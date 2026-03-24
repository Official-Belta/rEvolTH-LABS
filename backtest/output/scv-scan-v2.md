# SCV-Scan v2 — Post-Fix Audit

## Codebase: v2 (DEX-only, no EtherFi, funds→vault)

## Phase 2: Sweep Results
8 candidates from grep + semantic analysis.

## Phase 3: Deep Validation

| # | File | Suspected | Result |
|---|------|-----------|--------|
| 1 | LoopVault:230 | Reentrancy | FALSE POSITIVE — nonReentrant + CEI |
| 2 | KeeperModule:171 | Unchecked return | LOW — intentional |
| 3 | LoopVault:102 | Unsupported opcodes | INFO — Cancun check |
| 4 | LoopStrategy:81-84 | Approve race | FALSE POSITIVE — constructor only |
| 5 | UniV3Adapter:33 | Approve race | FALSE POSITIVE — single tx |
| 6 | LoopVault:255 | Timestamp | FALSE POSITIVE — 7-day window |
| 7 | LoopStrategy:298 | Oracle staleness | INFO — 24h matches heartbeat |
| 8 | LoopStrategy:172,202 | Fund destination | VERIFIED FIX — goes to vault |

## Confirmed Findings

### Missing Zero-Address Check on setVault

**File:** `src/LoopStrategy.sol` L87
**Severity:** Medium

**Description:** `setVault(address(0))` would cause all leverageDown/emergencyUnwind to send WETH to address(0), permanently burning user funds.

**Code:**
```solidity
function setVault(address _vault) external onlyOwner {
    vault = _vault; // no zero check
}
```

**Recommendation:** `require(_vault != address(0), "zero vault");`

### Keeper Tip Silent Failure

**File:** `src/KeeperModule.sol` L171
**Severity:** Low

**Description:** Tip payment can fail silently. Intentional design.

## Summary

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 1 |
| Low | 1 |
| Info | 2 |

## Key Verification: Fund Flow Fix
- leverageDown L172: `safeTransfer(vault, ethOut)` ✅
- emergencyUnwind L202: `safeTransfer(vault, bal)` ✅
- NO safeTransfer to msg.sender in strategy ✅
