# HyperSurge Hook — README $current$

**Dynamic, oracle-aware swap fees for Balancer V3 weighted pools (2–8 tokens).**  
HyperSurge raises swap fees when the pool’s **implied price** departs from an **external price** $Hyperliquid$. This version introduces a configurable **cap deviation** so you can choose the deviation level at which the fee reaches the **max surge fee**, while preserving the stable-surge style **after-liquidity protections**.

---

## Table of Contents

- [Core Concepts](#core-concepts)
- [Dependencies & Assumptions](#dependencies--assumptions)
- [Storage Model (Multitoken by Index)](#storage-model-multitoken-by-index)
- [Configuration (by Index)](#configuration-by-index)
- [Runtime Flow (Fee Computation)](#runtime-flow-fee-computation)
- [Mathematics](#mathematics)
  - [Pool & Oracle Prices](#pool--oracle-prices)
  - [Deviation](#deviation)
  - [Fee Ramp](#fee-ramp)
  - [Pool‑Wide Deviation for Liquidity Checks](#poolwide-deviation-for-liquidity-checks)
- [Error Handling & Fallbacks](#error-handling--fallbacks)
- [Why Multitoken‑by‑Index](#why-multitokenbyindex)
- [Gas‑Efficiency Design](#gas-efficiency-design)
- [Security & Operational Notes](#security--operational-notes)
- [Worked Examples](#worked-examples)
- [Quick Start](#quick-start)
- [Testing Notes](#testing-notes)
- [Versioning & Changelog](#versioning--changelog)

---

## Core Concepts

**What problem this solves.**  
In volatile markets, AMM balances can drift away from external prices. Traders can exploit mispricings (“toxic flow”), and LPs bear the cost. HyperSurge measures **how far** the pool’s implied price is from an external reference and **ramps up** fees as mispricing grows. The ramp is **linear** between a **threshold** (start of action) and a **cap deviation** (reach the max fee), then **clamped** at the max.

**Why this design.**  
A linear ramp gives predictable economics, avoids discontinuities, and is easy to reason about. The separate **cap deviation** lets operators decide **how early** the fee should saturate — e.g., reach the max at 20% deviation instead of 100% if you expect liquidity to thin out quickly. Finally, **after‑liquidity protections** prevent non‑proportional adds/removes from **worsening** a deviation that is already above threshold, without blocking corrective actions.

---

## Dependencies & Assumptions

- **Balancer V3 Vault + WeightedPool**
  - Uses `WeightedPool.onSwap$PoolSwapParams$` to compute the counter amount.
  - Uses `WeightedPool.getNormalizedWeights()` for weights.
  - `PoolSwapParams` (no token addresses): `kind`, `amountGivenScaled18`, `balancesScaled18[]`, `indexIn`, `indexOut`, `router`, `userData`.

- **Hyperliquid Precompiles**
  - **Price:** `HyperPrice.spot$pairIndex$ → uint64` scaled **1e6**.
  - **Token Info:** `HyperTokenInfo.szDecimals$pairIndex$ → uint8` in **[0..6]**.

- **Precision Conventions**
  - Pool math uses **1e18** fixed point.
  - Hyperliquid spot (1e6) is converted to 1e18 using a cached **price divisor**.

- **Operational Assumptions**
  - Token indices remain stable post-creation.
  - Authorized roles (governance/swapFeeManager) adjust **threshold τ** and **maximum fee cap**.
  - Precompiles are available and reliable on the target chain.

---

## Storage Model (Multitoken by Index)

Each pool has an entry with:
- **PoolDetails:**  
  - `maxSurgeFeePercentage` — cap on the dynamic fee.  
  - `surgeThresholdPercentage` — deviation threshold **τ** where the ramp starts.  
  - `capDeviationPercentage` — deviation **capDev** where the ramp ends (fee hits max).  
  - `numTokens`, `initialized`.
- **TokenPriceCfg[8] by token index (0..7):**  
  - `isUsd` (1 = USD price),  
  - `pairIndex` (Hyperliquid market id if not USD),  
  - `priceDivisor` (cached scale factor so spot → 1e18).

**Why index‑based.**  
Using pool token indices is compact and avoids mapping by address. Indices are canonical, stable for a given pool, and match Balancer’s internal representation.

---

## Configuration (by Index)

All setters are expected to be permissioned (e.g., governance / swap‑fee manager):

- **Token prices**  
  - `setTokenPriceConfigIndex(pool, tokenIndex, pairIdx, isUsd)`  
  - `setTokenPriceConfigBatchIndex(pool, tokenIndices[], pairIdx[], isUsd[])`
- **Fee parameters**  
  - `setMaxSurgeFeePercentage(pool, pct)`  
  - `setSurgeThresholdPercentage(pool, pct)` — must keep `pct < capDeviationPercentage`  
  - `setCapDeviationPercentage(pool, capDevPct)` — must keep `capDevPct > surgeThresholdPercentage` and `≤ 1`
- **Typical getters**  
  - `getMaxSurgeFeePercentage$pool$`, `getSurgeThresholdPercentage$pool$`, `getCapDeviationPercentage$pool$`  
  - Defaults (if exposed): `getDefaultMaxSurgeFeePercentage()`, `getDefaultSurgeThresholdPercentage()`, `getDefaultCapDeviationPercentage()`  
  - Token configs: `getTokenPriceConfigIndex`, `getTokenPriceConfigs`  
  - Pool state: `getNumTokens`, `isPoolInitialized`
- **Events**  
  - `TokenPriceConfiguredIndex`, `MaxSurgeFeePercentageChanged`, `ThresholdPercentageChanged`,  
    `CapDeviationPercentageChanged`, `PoolRegistered`.

---

---
# Hyper Surge Hook — Theory of Deviation & Add/Remove Liquidity Checks

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
  - Else `px[i] = (HyperPrice.spot$pairIndex$ * 1e18) / priceDivisor`.
- **Fixed point:** All ratios are 1e18-scaled (Balancers’s `FixedPoint` math).
- **Threshold:** `threshold` is a 1e18-scaled fraction (e.g., `0.10e18` = 10%).

---

## `_computeOracleDeviationPct` — Measuring Pool-vs-Oracle Deviation

### Intuition
A weighted pool determines relative prices from balances and weights. For any two tokens *i* and *j*, the **pool-implied price** for “j per i” is:

$$
P_{\text{pool}}(j \rightarrow i)
= \frac{B_j / w_j}{B_i / w_i}
= \frac{B_j \cdot w_i}{B_i \cdot w_j}.
$$

The **external $oracle$ price** for “j per i” is:

$$
P_{\text{ext}}(j \rightarrow i) = \frac{px_j}{px_i}.
$$

We define the **relative deviation** as:

$$
\operatorname{dev}(i,j) =
\frac{\left| P_{\text{pool}}(j \rightarrow i) - P_{\text{ext}}(j \rightarrow i) \right|}
     {P_{\text{ext}}(j \rightarrow i)}.
$$


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
  If `B' + Δ` overflows $wrap$, **allow**.

### Decision rule

Let:
- `beforeDev = _computeOracleDeviationPct(pool, B_old)`
- `afterDev  = _computeOracleDeviationPct(pool, B')`
- `threshold = getSurgeThresholdPercentage$pool$`

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

- **Mismatched array lengths** (deltas vs balances): **allow** $defensive$.
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

- `_computeOracleDeviationPct`: **O(n²)** pairwise over `n ≤ 8` tokens $cheap$.
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

1. **Early exits.**  
   Abort surge logic and return **static fee** if: pool not initialized; indexes out of range; `max ≤ static`; `τ ≥ 1`; missing weights; `px_in == 0` or `px_out/px_in == 0`. If `capDev ≤ τ` $misconfig$, treat as `capDev = 1` defensively.
2. **Post‑trade balances.**  
   Call the pool’s `onSwap` to get the counter‑amount. Update only the two balances participating in the swap, using the exact `EXACT_IN`/`EXACT_OUT` rules that the pool expects.
3. **Pool‑implied price.**  
   Read normalized weights; compute the price implied by balances and weights (see math below).
4. **External price.**  
   Build per‑token prices (USD = 1e18 or Hyperliquid spot scaled by `priceDivisor`) and take the ratio.
5. **Deviation and fee.**  
   Compute relative deviation; if above threshold, apply the **linear ramp** over `[τ, capDev]`; clamp to `max`.

---

## Mathematics

### Pool & Oracle Prices

**Pool‑implied price** (for “j per i”, after the provisional trade) comes from balances and normalized weights:

$$
P_{\text{pool}}(j \rightarrow i) \;=\; \frac{B'_j/w_j}{B'_i/w_i}
\;=\; \frac{B'_j \cdot w_i}{B'_i \cdot w_j}
$$

**External price ratio** uses per‑token oracle prices:

$$
P_{\text{ext}}(j \rightarrow i) \;=\; \frac{px_j}{px_i}
$$

### Deviation

**Relative deviation** is measured as:

$$
\delta(j,i) \;=\; \frac{\left|\,P_{\text{pool}}(j \rightarrow i) - P_{\text{ext}}(j \rightarrow i)\,\right|}
{P_{\text{ext}}(j \rightarrow i)}
$$

A value of $\delta = 0.10$ means the pool is 10% away from the oracle for that pair.

### Fee Ramp

Let `static` be the pool’s base fee, `max` the cap, $\tau$ the threshold, and `capDev` the deviation at which the max fee is reached. For measured deviation $\delta$:

- If $\delta \le \tau$, the fee remains the **static** fee.
- Otherwise, compute a normalized progress and ramp linearly:

```text
span = capDev − τ                # > 0
norm = (δ − τ) / span            # linear progress in [0, 1]
norm = min(norm, 1)
fee  = static + (max − static) * norm
fee  = min(fee, max)
```

**Slope interpretation.**  
The marginal slope in the active region is $(\text{max} - \text{static}) / (\text{capDev} - \tau)$.  
Choosing smaller `capDev` reaches the max sooner; choosing larger `capDev` spreads the ramp over a wider range.

### Pool‑Wide Deviation for Add/Remove Liquidity Checks

For **multi‑token** pools, the liquidity checks use a conservative **max‑pair** deviation:

1. Build 1e18‑scaled per‑token prices ($px_k$).
2. For every pair $(i, j)$, compute $P_{\text{pool}}(j \rightarrow i)$ and $P_{\text{ext}}(j \rightarrow i)$, then $\delta(j,i)$.
3. Take $\delta_{\max} = \max_{i<j} \delta(j,i)$.

This captures the *worst* mispricing. It is cheap ($O(n^2)$ with $n \le 8$) and effective at preventing outlier‑token blowups.

---

## Error Handling & Fallbacks

- **Fail‑open to static fee** on most uncertainty: uninitialized pool, bad indices, zero weights/price, or zero external ratio.  
- **Defensive cap**: if `capDev ≤ τ`, fee logic treats `capDev = 1` for that computation; the setter enforces proper ordering so misconfig should be rare.  
- **External calls**: if the underlying pool or precompiles revert, the transaction can still fail upstream; the hook avoids adding additional reverts beyond explicit `require`s for invalid configuration.

---

## Why Multitoken‑by‑Index

- **Compact and gas‑efficient**: indices avoid mapping by address and match Balancer’s internal ordering.
- **Clear operational story**: pool operators think in “slot i” and “slot j” terms when configuring weightings and token lists.
- **Deterministic layout**: fixed `TokenPriceCfg[8]` bounds the cost and simplifies scanning.

---

## Gas‑Efficiency Design

- **Cached divisors**: convert Hyperliquid spot to 1e18 with a simple multiply/divide (no exponentiation).
- **Two‑token hot path**: fee computation touches only the two swap tokens; no large array copies.
- **O(n²) but n ≤ 8** for the pool‑wide deviation used in liquidity checks, keeping it practical.
- **Guarded early returns**: most “bad state” cases exit early with the static fee, avoiding wasted work.

---

## Security & Operational Notes

- **Access control**: setters should be protected (governance / fee manager). Consider timelocks or rate limits for parameter changes in production.
- **Observability**: events fire on every parameter change and token price mapping update; consider complementing with metrics on how often after‑liquidity checks block.
- **Policy clarity**: proportional liquidity is *always allowed*; non‑proportional is blocked *only* if it **worsens** deviation **and** the resulting deviation is **above** threshold — corrective actions are allowed.

---

## Worked Examples

### Example A — Reach max earlier

Parameters:
- `static = 0.30%`, `max = 2.00%`, `τ = 2%`, `capDev = 20%`.

For measured deviation `δ = 11%`:

```text
span = 20% − 2% = 18%
norm = (11% − 2%) / 18% = 0.50
fee  = 0.30% + (2.00% − 0.30%) * 0.50
     = 0.30% + 0.85% = 1.15%
```

At `δ ≥ 20%`, fee = `2.00%`.

### Example B — Legacy behavior

Set `capDev = 100%`.  
You now reach `max` only when `δ ≈ 100%`; the ramp is flatter for the same `(max − static)` and `τ`.

---

## Quick Start

1. **Register** the pool with the hook (done by the Vault during pool creation).
2. **Configure token prices by index**  
   - USD tokens: `isUsd = true`.  
   - Non‑USD tokens: find the Hyperliquid `pairIndex`, call `setTokenPriceConfigIndex` (or the batch variant). The hook caches the `priceDivisor`.
3. **Set fee parameters**  
   - `setMaxSurgeFeePercentage(pool, …)`  
   - `setSurgeThresholdPercentage(pool, τ)`  
   - `setCapDeviationPercentage(pool, capDev)` — choose capDev to control where max fees kick in.
4. **Verify** with a dry‑run / simulation: small swaps around the threshold, then above `capDev` to confirm clamping at `max`.

---

## Testing Notes

- **Guards**: uninitialized, bad indices, `max ≤ static`, `τ ≥ 1`, missing weights, missing or zero price, zero external ratio.  
- **Swap math**: both `EXACT_IN` and `EXACT_OUT` branches update balances correctly for the chosen pool.  
- **Ramp**: continuity at `δ = τ`, monotonic increase until `capDev`, clamped at `max`.  
- **After‑liquidity**: proportional always allowed; non‑proportional blocked iff `(after > before) && (after > τ)`; array length mismatch and balance reconstruction under/overflow paths covered.  
- **Edge cases**: `n = 2` and `n = 8`, tiny weights, a token with zero balance, USD‑quoted tokens mixed with non‑USD.


---