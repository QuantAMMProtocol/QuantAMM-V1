// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.24;
import "../../rules/CreReceiver.sol";

contract MockCreReceiver is CreReceiver {
    bytes public lastReport;
    bool public processCalled;

    constructor(address forwarderAddress) CreReceiver(forwarderAddress) {}

    function ProcessReport(bytes calldata metaData) external {
        _processReport(metaData);
    }

    function _processReport(bytes calldata report) internal override {
        processCalled = true;
        lastReport = report;
    }
}
