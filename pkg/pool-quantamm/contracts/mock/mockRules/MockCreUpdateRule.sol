// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.24;
import "../../rules/CreUpdateRule.sol";

contract MockCreUpdateRule is CreUpdateRule {
    constructor(address _updateWeightRunner) CreUpdateRule(_updateWeightRunner) {}

    function ProcessReport(bytes memory metaData) external {
        _processReportMemory(metaData);
    }
}
