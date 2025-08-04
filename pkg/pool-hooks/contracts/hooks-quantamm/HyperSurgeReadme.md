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
