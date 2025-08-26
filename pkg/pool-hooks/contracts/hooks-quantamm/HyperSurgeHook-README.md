# Hyperliquid Balancer Hook — Arb-Aware Surge Fees

> Dynamic, oracle-aware swap fees for Balancer V3 weighted pools, using Hyperliquid Core Reader spot prices. The hook measures pool-vs-oracle deviation, distinguishes **noise** vs **arbitrage** directions, and applies a direction-aware fee ramp. It also introduces a conservative guard for **single-asset withdrawals** (and more generally any non-proportional adds/removes).

---

## 1) Background: Balancer hooks, Hyperliquid, and Core Reader spot price

**Balancer V3 hooks.** Hooks let pool owners run custom logic during swaps and liquidity events (before/after swap, add/remove). This hook computes a dynamic, oracle-aware fee and enforces protective rules around non-proportional liquidity.

**Hyperliquid.** We use Hyperliquid’s on-chain price interface (Core Reader / precompile) as the external reference. Each market is addressed by a `pairIndex`, and its **spot price** is read as a fixed-point number that we internally normalize to $1e18$ precision for consistent math.

**Core Reader spot price.** Let `spot(pairIndex)` return a price scaled by $10^d$ (e.g., $d=6$). The hook caches a **price divisor** so that:

$$
px_k = \frac{spot(pairIndex_k)}{10^d}\times 10^{18}
$$

giving per-token oracle prices $px_k$ in $1e18$ scale. USD-quoted tokens can be set to $px_k = 10^{18}$.

---

## 2) Deviation: pool price vs Hyperliquid spot

Consider a weighted pool with balances $B_i$ and normalized weights $w_i$ for tokens $i\in\{1,\dots,n\}$.  
For any ordered pair $(i,j)$, the **pool-implied price of $j$ in units of $i$** is

$$
P_{pool}(j \rightarrow i) = \frac{B_j/w_j}{B_i/w_i}
= \frac{B_j w_i}{B_i w_j} \, .
$$

Let $px_k$ be the $1e18$-scaled Hyperliquid price for token $k$. The **external price ratio** is

$$
P_{ext}(j \rightarrow i) = \frac{px_j}{px_i} \, .
$$

We define the **relative deviation** for the pair $(i,j)$ as

$$
\delta(i,j) =
\frac{\left| P_{pool}(j \rightarrow i) - P_{ext}(j \rightarrow i) \right|}{P_{ext}(j \rightarrow i)} \, .
$$

For a **pool-wide** signal we take the **maximum** across all pairs:

$$
\delta_{max} = \max_{i<j} \delta(i,j)
$$

which is conservative and cheap for $n\le 8$.

### 2.1 Swap Modeling Specifics

To measure deviation directionality accurately, the hook simulates the **post-trade pool price**.  
- For **EXACT_IN** swaps, the output amount is computed from the input.  
- For **EXACT_OUT** swaps, the required input is computed from the output.  

This ensures Δδ is always measured against the correctly projected pool state.
This is done calling the pools onswap functionality. Given this is a view function and not 
all pools specify this function as view, this hook is specific to WeightedPools and another
deployment would need to be made for other pool types.

---

## 3) Why deviation helps separate **noise** from **arbitrage**

Let $\Delta$ denote a proposed trade that updates balances from $B$ to $B'$. Define the change in deviation:

$$
\Delta\delta = \delta(B') - \delta(B)
$$

Intuition:

- If $\Delta\delta < 0$, the trade **reduces** mispricing (brings the pool closer to oracle). This is characteristic of **arbitrage** flow.
- If $\Delta\delta > 0$, the trade **increases** mispricing (pushes the pool away). This is more consistent with **noise** flow.

Thus $\delta$ (and its directional change) is a natural **toxicity** proxy.

### Arb vs Noise Parameterization

The hook maintains **two independent parameter sets**: one for trades that **worsen deviation** ("noise") and one for trades that **improve deviation** ("arb"). Each has its own threshold, cap deviation, and maximum surge values.  
- **Noise path**: uses post-trade deviation to determine the fee.  
- **Arb path**: uses **pre-trade deviation** to determine the fee, rewarding price-improving flow with a distinct ramp profile.  
---

## 4) Fee model and directionality

### 4.1 Scalar surge as a function of deviation

Let:
- $f_{base}$ be the pool’s static fee,
- $f_{max}$ be the max fee cap,
- $\tau \in (0,1)$ be the threshold where surge begins,
- $capDev \in (\tau,1]$ be the deviation where the fee reaches $f_{max}$.

For a measured deviation $\delta$:

$$
span = capDev - \tau, \quad
prog = \min\!\left(1,\; \max\!\left(0, \frac{\delta - \tau}{span}\right)\right)
$$

$$
f_{scalar}(\delta) = f_{base} + (f_{max}-f_{base})\cdot prog
$$

This yields a **linear ramp** from $f_{base}$ (for $\delta\le\tau$) up to $f_{max}$ (for $\delta\ge capDev$).

### 4.2 Direction-aware application

Let $\Delta\delta$ be computed **with post-trade balances**. Define

$$
dir = sign(\Delta\delta) \in \{-1,0,+1\}
$$

We apply the scalar surge **only** when the trade worsens deviation:

$$
f(\delta,\Delta\delta) =
\begin{cases}
f_{scalar}(\delta), & \Delta\delta > 0 \\
\alpha \cdot f_{base}, & \Delta\delta \le 0
\end{cases}
$$

where $\alpha \in [0,1]$ is an optional **arbitrage discount**.  


### 4.3 Oracle Failure Handling

If any oracle price is unavailable or returned as zero, the hook **falls back to the pool's static fee**. In these cases, surge and add/remove guards are disabled, effectively failing open to maintain liveness.

---

## 5) Single-asset withdrawal and the **guard**

Single-asset withdraws (and adds) are **non-proportional** and can materially **alter relative prices**. The hook implements a **conservative guard**:

1. Reconstruct pre-change balances $\tilde{B}$ from post-change $B'$ and deltas $\Delta$.
   - Add: $\tilde{B} = B' - \Delta$
   - Remove: $\tilde{B} = B' + \Delta$
2. Compute $\delta_{before} = \delta(\tilde{B})$ and $\delta_{after} = \delta(B')$.
3. **Block** the operation if

$$
\delta_{after} > \delta_{before} \quad \text{and} \quad \delta_{after} > \tau
$$

Otherwise allow.

Why conservative?
- Only block when deviation worsens and ends above threshold.
- Proportional adds/removes are always allowed.

---

## 6) Practical configuration notes

- **Threshold $\tau$.** Lower values = more sensitivity.
- **capDev.** Where max fee saturates.
- **Arb discount $\alpha$.** Optional.
- **Price mapping.** Normalize all Hyperliquid spots to $1e18$.

---

## 7) Worked example

Parameters:

$$
f_{base}=0.30\%,\; f_{max}=2.00\%,\; \tau=2\%,\; capDev=20\%
$$

Observed $\delta = 11\%$:

$$
prog=\frac{11-2}{20-2}=0.5
$$

$$
f_{scalar} = 0.30\% + (2.00\%-0.30\%)\cdot 0.5 = 1.15\%
$$

- If $\Delta\delta > 0$: applied fee = **1.15%**
- If $\Delta\delta \le 0$: applied fee = **0.30%**

---

**Security note.** Protect setters with governance roles.