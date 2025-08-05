# HyperSurge Hook — README

> **Dynamic, market-aware swap fees for Balancer V3 pools (2–8 tokens) using Hyperliquid spot prices.**  
> HyperSurge raises the swap fee when a pool’s *implied* price diverges from an *external* price signal, deterring toxic flow and compensating LPs during volatility.

---

## Table of Contents

- [Core Concepts](#core-concepts)
- [Dependencies & Assumptions](#dependencies--assumptions)
- [Storage Model (Multitoken by Index)](#storage-model-multitoken-by-index)
- [Configuration (by Index)](#configuration-by-index)
- [Runtime Flow (Fee Computation)](#runtime-flow-fee-computation)
- [Mathematics](#mathematics)
- [Error Handling & Fallbacks](#error-handling--fallbacks)
- [Why Multitoken-by-Index](#why-multitokenbyindex)
- [Gas-Efficiency Design](#gas-efficiency-design)
- [Security & Operational Notes](#security--operational-notes)
- [Worked Example](#worked-example)
- [Quick Start](#quick-start)
- [Testing Notes](#testing-notes)

---

## Core Concepts

- **External Oracle (Hyperliquid):** Prices are read from Hyperliquid precompiles (6-decimal fixed point). Tokens can alternatively be flagged as **USD-quoted** (price ≡ 1e18).
- **Pool Implied Price:** For tokenIn → tokenOut, the pool’s price is computed from **post-trade balances** and **normalized weights** (WeightedPool model).
- **Deviation Trigger:** When the relative deviation between pool price and external price exceeds a configurable **threshold τ**, the swap fee increases above the pool’s **static fee** toward a **maximum cap**.
- **Monotone, Capped Ramp:** Fee increment grows linearly with excess deviation and is clamped at the cap; no change when deviation ≤ τ.
- **Multitoken-by-Index:** Pools with **2–8 tokens** are supported. Configuration is **by token index**, which is stable once the pool is created.

---

## Dependencies & Assumptions

- **Balancer V3 Vault + WeightedPool**
  - Uses `WeightedPool.onSwap(PoolSwapParams)` to compute the counter amount.
  - Uses `WeightedPool.getNormalizedWeights()` for weights.
  - `PoolSwapParams` (no token addresses): `kind`, `amountGivenScaled18`, `balancesScaled18[]`, `indexIn`, `indexOut`, `router`, `userData`.

- **Hyperliquid Precompiles**
  - **Price:** `HyperPrice.spot(pairIndex) → uint64` scaled **1e6**.
  - **Token Info:** `HyperTokenInfo.szDecimals(pairIndex) → uint8` in **[0..6]**.

- **Precision Conventions**
  - Pool math uses **1e18** fixed point.
  - Hyperliquid spot (1e6) is converted to 1e18 using a cached **price divisor**.

- **Operational Assumptions**
  - Token indices remain stable post-creation.
  - Authorized roles (governance/swapFeeManager) adjust **threshold τ** and **maximum fee cap**.
  - Precompiles are available and reliable on the target chain.

---

## Storage Model (Multitoken by Index)

- **`PoolDetails`** *(packed into a single slot)*  
  - `maxSurgeFeePercentage` (uint64, 18-dec)  
  - `thresholdPercentage` (uint64, 18-dec) ≡ τ  
  - `numTokens` (uint8) ∈ [2..8]  
  - `initialized` (bool)

- **`TokenPriceCfg[8]`** *(one slot per index)*  
  - `pairIndex` (uint32) — Hyperliquid market id (0 allowed only if `isUsd = 1`)  
  - `szDecimals` (uint8) — cached once from tokenInfo  
  - `isUsd` (uint8) — 1 if USD-quoted (price ≡ 1e18), else 0  
  - `priceDivisor` (uint32) — **precomputed** `10^(6 − sz)` (one of `{1,10,100,1e3,1e4,1e5,1e6}`)

- **Hot-Path SLOADs:**  
  Exactly **3 SLOADs** per fee computation:
  1) `details`  
  2) `tokenCfg[indexIn]`  
  3) `tokenCfg[indexOut]`

---

## Configuration (by Index)

- **Set token config**  
  `setTokenPriceConfigIndex(pool, tokenIndex, pairIdx, isUsd)`  
  - If `isUsd = true`: `(pairIndex=0, sz=0, isUsd=1, priceDivisor=1)`.
  - Else: require `pairIdx != 0`; cache `sz = szDecimals(pairIdx)` with `sz ∈ [0..6]`; compute and store `priceDivisor = 10^(6 − sz)` via LUT.

- **Batch configuration** mirrors single-index configuration for multiple indices.

- **Fee Parameters**  
  - `setMaxSurgeFeePercentage(pool, pct)` with `pct ≤ 1e18`.  
  - `setSurgeThresholdPercentage(pool, pct)` with `pct ≤ 1e18`.

> Precomputing `priceDivisor` eliminates exponentiation in the hot path and confines `sz` validation to config time.

---
# Hyper Surge Hook — Theory of Deviation & Liquidity Checks

This document explains the reasoning and math behind:

- `_computeOracleDeviationPct` — how the hook measures “how far the pool’s implied prices are from external/oracle prices.”
- `onAfterAddLiquidity` / `onAfterRemoveLiquidity` — how the hook decides whether a non-proportional liquidity action should be **blocked** to avoid worsening a surge.

The goal is to **discourage actions that *increase* price deviation when the pool is already beyond a configured surge threshold**, while allowing neutral or corrective actions.

---

## Notation & Scaling

- **Balances:** `balancesScaled18[i]` — token *i*’s balance in 18-decimals.
- **Weights:** `w[i]` — normalized weights from the weighted pool (`getNormalizedWeights()`), scaled to 1e18.
- **External price:** `px[i]` — 1e18-scaled external price for token *i*:
  - If `isUsd == 1`, then `px[i] = 1e18` (USD unit price).
  - Else `px[i] = (HyperPrice.spot(pairIndex) * 1e18) / priceDivisor`.
- **Fixed point:** All ratios are 1e18-scaled (Balancers’s `FixedPoint` math).
- **Threshold:** `threshold` is a 1e18-scaled fraction (e.g., `0.10e18` = 10%).

---

## `_computeOracleDeviationPct` — Measuring Pool-vs-Oracle Deviation

### Intuition

A weighted pool determines relative prices from **balances and weights**. For any two tokens _i_ and _j_, the **pool-implied price** for “j per i” is proportional to:
\[
P_{\text{pool}}(j \!\to\! i) \;=\; \frac{B_j / w_j}{B_i / w_i}
\;=\; \frac{B_j \cdot w_i}{B_i \cdot w_j}
\]
The **external price** from the oracle for “j per i” is:
\[
P_{\text{ext}}(j \!\to\! i) \;=\; \frac{px[j]}{px[i]}
\]

We define **relative deviation** as:
\[
\text{dev}(i,j) \;=\;
\frac{|P_{\text{pool}}(j \!\to\! i) - P_{\text{ext}}(j \!\to\! i)|}{P_{\text{ext}}(j \!\to\! i)}
\]

The function returns the **maximum** deviation across **all pairs** (i<j). Using the max catches the worst mispricing the pool is exhibiting relative to the oracle and is simple to reason about under risk constraints.

### Algorithm (high level)

1. **Preconditions & bounds**
   - If the pool is not initialized or `n < 2`, return `0`.
   - Use `n = min(numTokens, balances.length, weights.length)`.

2. **Fetch weights** once from the weighted pool.

3. **Build external prices `px[i]`** for each token (1e18-scaled).  
   - If any price is unavailable (`0`) or a balance/weight is `0`, **skip** that pair rather than reverting.

4. **Pairwise loop** over `i<j`:
   - Compute `P_pool(j→i) = (B_j * w_i) / (B_i * w_j)`.
   - Compute `P_ext(j→i) = px[j] / px[i]`.
   - Compute `dev(i,j) = |P_pool - P_ext| / P_ext`.
   - Track `maxDev = max(maxDev, dev(i,j))`.

5. **Return `maxDev`** (1e18-scaled fraction).

### Why “max pairwise deviation”?

- **Conservative**: protects against the single worst skew that can be exploited.
- **Stable**: avoids over-reacting to noise in tokens that are already in line (only the worst offender drives the decision).
- **Simple**: O(n²) for `n ≤ 8` is cheap and robust.

### Edge cases & safeguards

- **Zero or missing inputs** (balances, weights, or prices) ⇒ pair is **skipped**.
- **Arithmetic** uses Balancer fixed-point helpers (`mulDown/divDown`), consistent with fee logic.
- **No valid pairs** ⇒ returns `0`.

---

## Liquidity Checks: `onAfterAddLiquidity` & `onAfterRemoveLiquidity`

### Goal

Block **non-proportional** liquidity changes **only when** they **worsen** deviation and the **resulting** deviation is **above** the surge threshold. This mirrors the stable surge hook policy:

- **Proportional** add/remove: **always allowed**.
- **Non-proportional** add/remove:
  - Reconstruct **pre-change** balances.
  - Compare **before** vs **after** deviation.
  - **Block** only if:
    1. `afterDeviation > beforeDeviation`, **and**
    2. `afterDeviation > threshold`.

This ensures we don’t block helpful rebalancing that reduces deviation, and we ignore small deviations below the threshold.

### Proportional vs Non-Proportional

- A **proportional** add/remove scales all token balances by the same factor — it **does not** change relative prices implied by the constant-value formula, so we allow it.
- The Vault passes `kind` (`PROPORTIONAL` or not), so we **trust** the classification and skip any extra ratio checks.

### Reconstructing pre-change balances

- **Add liquidity**  
  Post-add balances: `B' = B_old + Δ`.  
  Reconstruct `B_old = B' - Δ`.  
  If any `Δ > B'` (underflow risk), **allow** (don’t block by mistake).

- **Remove liquidity**  
  Post-remove balances: `B' = B_old - Δ`.  
  Reconstruct `B_old = B' + Δ`.  
  If `B' + Δ` overflows (wrap), **allow**.

### Decision rule

Let:
- `beforeDev = _computeOracleDeviationPct(pool, B_old)`
- `afterDev  = _computeOracleDeviationPct(pool, B')`
- `threshold = getSurgeThresholdPercentage(pool)`

Then:

- **Block** iff `afterDev > beforeDev && afterDev > threshold`.
- **Allow** otherwise.

### Why compare “after > before”?

- Prevents **worsening** of an existing surge.  
- Allows actions that **reduce** or **maintain** deviation, even when above the threshold (helpful rebalancing).

### Why require “after > threshold”?

- Avoids blocking normal operations for small, benign deviations.
- The hook only intervenes during meaningful surges (configurable via `threshold`).

### Returned values

- Both functions return `(bool success, uint256[] memory hookAdjustedAmountsRaw)`.
- This implementation **does not modify** amounts; it only **allows or blocks**.  
  - On allow: `success = true`, amounts returned unchanged.  
  - On block: `success = false`, amounts returned unchanged (the Vault should abort the op).

### Edge cases & safety

- **Mismatched array lengths** (deltas vs balances): **allow** (defensive).
- **Small pools** (`n < 2`): **allow**.
- **Missing prices/weights/balances** for a pair: that pair is **ignored** in deviation.  
  If no pairs are usable, deviation is `0`, so the action will not be blocked.
- **Rounding** uses `mulDown/divDown` consistently with the fee path.

---

## How This Interacts With Dynamic Swap Fees

- The **dynamic swap fee** uses the same deviation measure (pool vs oracle) to ramp from a static fee up to `maxSurgeFeePercentage` once deviation exceeds `threshold`.
- The **liquidity checks** ensure LP actions do not **increase** that deviation when it is already above the threshold.  
  Together, they:
  - Charge traders more during mispricing (discourage taking imbalance-increasing routes).
  - Prevent LPs from worsening imbalance with non-proportional liquidity changes.
  - Allow corrective actions that bring the pool back toward oracle prices.

---

## Complexity

- `_computeOracleDeviationPct`: **O(n²)** pairwise over `n ≤ 8` tokens (cheap).
- `onAfter*`: one or two calls to `_computeOracleDeviationPct` + linear reconstruction of `B_old`.

---

## Practical Configuration Tips

- **Threshold** (`thresholdPercentage`):
  - Lower values make the system more sensitive; higher values reduce interventions.
  - Typical ranges: 2%–20% depending on pool volatility.

- **Oracle coverage**:
  - Ensure every token has a sensible `px` mapping (or is USD). Missing prices reduce sensitivity.

- **Weights**:
  - Extremely small weights make the pool-implied price more sensitive to balance changes; consider caps consistent with pool design.

---

## Summary

- `_computeOracleDeviationPct` measures **worst pairwise** mispricing between pool-implied prices and the external oracle.
- `onAfterAddLiquidity` / `onAfterRemoveLiquidity` **block only** non-proportional liquidity that **worsens** deviation and ends **above** the threshold.
- Proportional changes are **always allowed** because they do not change relative prices.
- This mirrors the **stable surge hook** protections while adapting the signal to **oracle-based deviation** for weighted, multi-token pools.

## Runtime Flow (Fee Computation)

Given `PoolSwapParams p` and a pool address:

1. **Early Exits**
   - Not initialized → return `(true, staticFee)`.
   - Index bounds: `p.indexIn`, `p.indexOut` `< numTokens` else **static**.
   - If `maxFee ≤ staticFee` → **static** (no headroom).
   - If `threshold ≥ 1e18` → **static** (no ramp).

2. **Provisional Amount**
   - Call `WeightedPool.onSwap(p)` to get the counter amount.
   - Build **post-trade** balances for **only** the two indices:
     - `EXACT_IN`:  
       `bIn'  = bIn  + amountGiven`  
       `bOut' = bOut − amountCalculated`
     - `EXACT_OUT`:  
       `bIn'  = bIn  + amountCalculated`  
       `bOut' = bOut − amountGiven`

3. **Weights & Pool Price**
   - Read `wIn`, `wOut` from `getNormalizedWeights()`.
   - Pool price (1e18 scale):  
     `P_pool = (B_out' * w_in) / (B_in' * w_out)`  
   - Guard: if `bIn' = 0` → revert `"bal0"`; if any factor is 0 → treat as no price (static).

4. **External Price (Hyperliquid/USD)**
   - If `isUsd = 1`: `px = 1e18`.  
   - Else: `raw = HyperPrice.spot(pairIndex)` (1e6), then `px = (raw * 1e18) / priceDivisor`.  
   - Pair price: `P_ext = px_out / px_in`.

5. **Deviation & Fee Ramp**
   - Relative deviation: `δ = |P_pool − P_ext| / P_ext`.
   - If `δ ≤ τ` → fee = `static`.  
   - Else:  
     `increment = (f_max − f_static) * (δ − τ) / (1 − τ)`  
     `fee = clamp(f_static + increment, ≤ f_max)`

6. **Return**
   - `(true, fee)`

*Continuity:* ramp is continuous at `δ = τ` (within rounding).  
*Monotonicity:* fee is non-decreasing in δ for fixed parameters.

---

## Mathematics

- **Scales:** internal math at **1e18**; HL spot at **1e6**; divisor converts 1e6 → 1e18.  
- **Complement:** `1 − τ` computed directly; guarded by early exit when `τ = 1e18`.  
- **Rounding:** uses fixed-point helpers (`mulDown`, `divDown`), bias toward zero.  
- **Pool Price:** WeightedPool pairwise formula from post-trade balances and normalized weights.

---

## Error Handling & Fallbacks

- **Static fee fallbacks** (non-reverting paths):
  - Uninitialized or invalid indices.
  - Pool `onSwap` / `getNormalizedWeights()` revert.
  - Weights array too short for indices.
  - Any zero/invalid intermediate implying no meaningful price.

- **Precompile failures**:
  - Short revert tags surface issues:
    - `"price"` — Hyperliquid price failure or invalid `pairIndex` for non-USD.
    - `"dec"` — invalid `szDecimals` (outside [0..6]) at config time.

> If preferred, wrap precompile calls with try/catch to fall back to static instead of reverting.

---

## Why Multitoken-by-Index

- Matches the Vault’s swap interface, which addresses tokens by **index**.
- Minimizes storage reads: **only two** token config slots per swap.
- Clearer auditability vs. global bit-packing while keeping gas low.

---

## Gas-Efficiency Design

- **3 SLOADs per swap:** `details` + `tokenCfg[in]` + `tokenCfg[out]`.
- **Precomputed `priceDivisor`:** no exponentiation in the hot path.
- **Read only the needed data:** two balances & two weights (no full array copies).
- **Early exits:** skip all external calls if no surge can occur.
- **Local caching:** read storage once; use stack locals thereafter.
- *(Optional)* Inline assembly for precompile calls to avoid ABI encode/decode overhead.

---

## Security & Operational Notes

- **Access Control:** Ensure only governance or the configured `swapFeeManager` can update `τ` and the fee cap.
- **Parameter Hygiene:** Excessive caps can make swaps uneconomical; very low τ can over-penalize benign flow.
- **USD-Quoted Tokens:** Useful for stables/pegs; otherwise provide a valid Hyperliquid `pairIndex`.
- **Oracle Availability:** If HL precompiles are unavailable, the hook may revert or fall back to static per integration policy.

---

## Worked Example

- **Pool:** 3 tokens (A,B,C).  
- **Config:**  
  - A: `pairIndex=101`, `sz=2` → `priceDivisor=10,000`  
  - B: USD (`isUsd=1`) → `price=1e18`  
  - τ = 2% (`0.02e18`), `f_static = 0.2%`, `f_max = 1%`
- **Swap:** A → B (EXACT_IN)
  1. `onSwap` gives provisional amountOut.
  2. Compute post-trade `bA'`, `bB'`.
  3. Read `wA`, `wB`; compute `P_pool`.
  4. `pxA = (spot(101) * 1e18) / 10,000`; `pxB = 1e18`; `P_ext = pxB/pxA`.
  5. If `δ = 5%`: excess = 3%, complement = 98% → increment ≈ `(1% − 0.2%) * 3/98 ≈ 0.02449%` → fee ≈ `0.22449%` (≤ `1%` cap).

---

## Quick Start

1. **Register** the hook with a Weighted pool (Vault lifecycle).
2. **Configure tokens (by index):**
   - For stables: set `isUsd = true`.
   - Otherwise: set `pairIndex`; the hook caches `szDecimals` and `priceDivisor`.
3. **Set fee parameters:** `thresholdPercentage (τ)` and `maxSurgeFeePercentage`.
4. **Monitor:** During volatility, deviation ↑ → realized fees ↑; otherwise fees revert to static.

---

## Testing Notes

- Token count bounds **[2..8]**; index bounds for in/out.  
- Admin guards: `max ≤ 1e18`, `threshold ≤ 1e18`; early exits when `max ≤ static` or `threshold = 1e18`.  
- EXACT_IN/OUT post-trade math; weighted price formula correctness.  
- USD vs. non-USD paths; divisor table `{1,10,100,1e3,1e4,1e5,1e6}`; precomputed divisor usage.  
- Deviation properties: `δ ≤ τ` unchanged; monotone in δ; clamp at `f_max`.  
- Fallbacks when pool calls revert or indices invalid; behavior on precompile failures per chosen policy.
