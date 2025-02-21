# 2025-02-21 QuantAMM Codehawks contest fix review:

[Link](https://codehawks.cyfrin.io/c/2024-12-quantamm/results?lt=contest&page=1&sc=xp&sj=reward&t=report) to the codehawks report.

* The issues in the hook contracts (`UpliftOnlyExample` and `LPNFT`) were not addressed as the team decided to push the release of these.

| Codehawks Issue | Cyfrin: |
| --- | --- |
| H-01. Out-of-Bounds Array Access in `_calculateQuantAMMVariance` with Odd Number of Assets and Vector Lambda | Fixed in [`b44ffcc`](https://github.com/QuantAMMProtocol/QuantAMM-V1/commit/b44ffcc5562ec254d081d72ad0251d87db74b7a7)|
| H-02. Critical: Malicious user can delete all Users Deposited Liquidity. | See comment on hooks above |
| H-03. Fee Evasion via LP Token Transfer Resets Deposit Value | See comment on hooks above |
| H-04. Denial of service when calculating the new weights if the rule requires previous moving averages | Fixed in [`249a922`](https://github.com/QuantAMMProtocol/QuantAMM-V1/commit/249a922ed64dc95be7f3579e44b9914f5d70becc) |
| H-05. Loss of Fees for Router `UpliftOnlyExample` due to Division Rounding in Admin Fee Calculation, Causing Unfair Fee Distribution | See comment on hooks above |
| H-06. Owner fee will be locked in `UpliftOnlyExample` contract due to incorrect recipient address in `UpliftOnlyExample::onAfterSwap` | See comment on hooks above |
| H-07. Missing Fee Normalization Leads to 1e18x Fee Overcharge in UpliftOnlyExample | See comment on hooks above |
| H-08. GradientBasedRules will not work for >=4 assets with vector lambdas | Fixed in [`de05c11`](https://github.com/QuantAMMProtocol/QuantAMM-V1/commit/de05c11ca411a487a1ba7db311b32c17fbb2e987) |
| H-09. Locked Protocol Fees Due to Incorrect Fee Collection Method | See comment on hooks above |
| H-10. Donations are sanwichable to steal funds from LP | See comment on hooks above |
| H-11. Users transferring their NFT position will retroactively get the new `upliftFeeBps` | See comment on hooks above |
| H-12. fees sent to QuantAMMAdmin is stuck forever as there is no function to retrieve them | See comment on hooks above |
| H-13. Incorrect uplift fee calculation leads to LPs incurring more fees than expected | See comment on hooks above |
| M-01. quantAMMSwapFeeTake used for both getQuantAMMSwapFeeTake and getQuantAMMUpliftFeeTake. | See comment on hooks above |
| M-02. `setUpdateWeightRunnerAddress` could break the protocol  | Fixed in [`dc51f9b`](https://github.com/QuantAMMProtocol/QuantAMM-V1/commit/dc51f9b223c5c003aca79e673e1608b30b7faa17), [`de4ada6`](https://github.com/QuantAMMProtocol/QuantAMM-V1/commit/de4ada6d62abce81a1def6e39921856f5bcb8322) and [`128ac43`](https://github.com/QuantAMMProtocol/QuantAMM-V1/commit/128ac4393a1163a9f916e88ff3c32203b00f37c0) |
| M-03. “Uplift Fee” Incorrectly Falls Back to Minimum Fee Due to Integer Division | See comment on hooks above |
| M-04. The user will lost his liquidity if he transfers the LP NFT to himself | See comment on hooks above |
| M-05. formula Deviation from White Paper and Weighted Pool `performUpdate` unintended revert | Fixed in [`7d8b445`](https://github.com/QuantAMMProtocol/QuantAMM-V1/commit/7d8b44538f57cf11048a31f4738d47e6ff155ed7) |
| M-06. Slight miscalculation in maxAmountsIn for Admin Fee Logic in UpliftOnlyExample::onAfterRemoveLiquidity Causes Lock of All Funds | See comment on hooks above |
| M-07. Transferring deposit NFT doesn't check if the receiver exceeds the 100 deposit limit | See comment on hooks above |
| M-08. The `computeBalance` function may revert because the `setWeights` function doesn't check the boundary of the normalized weight | Fixed in [`baacf91`](https://github.com/QuantAMMProtocol/QuantAMM-V1/commit/baacf918d1dd6f8d08f70fce465a380a77feb651) |
| M-09. The `maxTradeSizeRatio` can be bypassed due to incorrect logic in `onSwap` function | Fixed in [`f9c4026`](https://github.com/QuantAMMProtocol/QuantAMM-V1/commit/f9c4026ea2307f7e89e601d407b9937f0af61838) |
| M-10. Users are charged too much `exitFee` in `UpliftOnlyExample::onAfterRemoveLiquidity` function when `localData.lpTokenDepositValueChange > 0` and can cause underflow error if `lpTokenDepositValueChange` increase too much. | See comment on hooks above |
| M-11. If main oracle is removed from approved list it will keep returning not stale but invalid data (0 value) | Fixed in [`e7052d5`](https://github.com/QuantAMMProtocol/QuantAMM-V1/commit/e7052d5d0a3fb5f2f438225a361901bc5d733d99) |
| M-12. Getting data from pool can be reverted when one of the oracle is not live | Fixed in [`f82172f`](https://github.com/QuantAMMProtocol/QuantAMM-V1/commit/f82172fa33b45f6c591db23821efc99a3b69f0fb) |
| M-13. Protocol Fees Diminished Due to Admin Fee Payment on Liquidity Removal | See comment on hooks above |
| M-14. Incorrect implementation of `QuantammMathGuard.sol#_clampWeights`. | Fixed in [`814702f`](https://github.com/QuantAMMProtocol/QuantAMM-V1/commit/814702f4139e619b926cd4f723de3e7bd83ec633) |
| M-15. Wrong Fee Take Function Called in UpliftOnlyExample Causing Incorrect Fee Distribution | See comment on hooks above |
| M-16. Liquidity Removal Reverts in `onAfterRemoveLiquidity` Callback Triggered by `removeLiquidityProportional` | See comment on hooks above |
| M-17. Stale Weights Due to Improper Weight Normalization and Guard Rail Violation | Fixed in [`2aa146d`](https://github.com/QuantAMMProtocol/QuantAMM-V1/commit/2aa146d41745d210563aafc0d991c709ee446a1d) |
| M-18. incorrect length check in `_setIntermediateVariance` will DOS manual setting of `intermediateVarianceStates` after pool initialization | Fixed in [`866ee0a`](https://github.com/QuantAMMProtocol/QuantAMM-V1/commit/866ee0aad3b6a5096d61559dd4d91cad30192fd7) |
| L-01. Inconsistent timestamp storage when the LPNFT is transferred.| See comment on hooks above |
| L-02. Critical Precision Loss in MultiHopOracle Price Calculations| Acknowledged (Invalid) |
| L-03. Using front-run or a reorg attack it is possible steal higher value deposits from the sender by shifting NFT ID | See comment on hooks above |
| L-04. Incorrect event emitted in `setUpdateWeightRunnerAddress()` function| Fixed in [`e2283944`](https://github.com/QuantAMMProtocol/QuantAMM-V1/commit/e2283944a0e0743d69fe58c31356c4b549232524) |
| L-05. Inconsistent event data in `WeightsUpdated` emissions| Fixed in [`6bff0e0`](https://github.com/QuantAMMProtocol/QuantAMM-V1/commit/6bff0e0ace407b1136c91f9a8709f78afd9411e9) |
| L-06. Fee Bypass Through Precision Loss in Low-Decimal Tokens| See comment on hooks above |
| L-07. `minWithdrawalFeeBps` are not added to `upliftFeeBps` causing loss of fees and allowing MEV actions| See comment on hooks above |
| L-08. The `QuantammCovarianceBasedRule::_calculateQuantAMMCovariance` returns a two dimensional array with a wrong dimension| Fixed in [`b7e9a87`](https://github.com/QuantAMMProtocol/QuantAMM-V1/commit/b7e9a875305d26f332201978d43726a4312597c4) |
| L-09. Incorrect event emission can be done as a griefing attack| Fixed in [`437ef97`](https://github.com/QuantAMMProtocol/QuantAMM-V1/commit/437ef9764357adfc58478996cfedce665701c486)|
| L-10. Potential Mismatch Between `setWeightsManually` and `setWeights` Functionality| Acknowledged |
| L-11. `_clampWeights` does not consider values equal to `absoluteMin` and `absoluteMax`| Acknowledged |
| L-12. incorrect length check in `_setIntermediateCovariance` will DOS manual setting of `intermediateCovarianceStates` after pool initialization| Fixed in [`145fc35`](https://github.com/QuantAMMProtocol/QuantAMM-V1/commit/145fc35daca6c8c2a8a21b44286c6d1226bd7afc) |
