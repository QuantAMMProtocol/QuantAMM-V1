# 2025-03-10 Cyfrin `QuantAMMWeightedPool` Contract Size Refactoring Audit

Auditor: [Immeas](https://x.com/0ximmeas)

During deployment testing, it was identified that the contract size of `QuantAMMWeightedPool` exceeded the contract size limit. To address this, refactoring was performed to reduce its size. The primary change involved moving the constructor and initialization checks from the pool contract to the factory.

The modifications in this [PR](https://github.com/QuantAMMProtocol/QuantAMM-V1/pull/51) were reviewed and no issues were identified.
