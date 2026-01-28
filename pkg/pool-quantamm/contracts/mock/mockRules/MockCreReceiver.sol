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

  bytes private constant HEX_CHARS = "0123456789abcdef";

  /// @notice Helper function to convert bytes to hex string
  /// @param data The bytes to convert
  /// @return The hex string representation
  function _creReceiverBytesToHexString(
    bytes memory data
  ) private pure returns (bytes memory) {
    bytes memory hexString = new bytes(data.length * 2);

    for (uint256 i = 0; i < data.length; i++) {
      hexString[i * 2] = HEX_CHARS[uint8(data[i] >> 4)];
      hexString[i * 2 + 1] = HEX_CHARS[uint8(data[i] & 0x0f)];
    }

    return hexString;
  }

    function encodeWorkflowName(string memory _name) external pure returns (bytes10) {
        if (bytes(_name).length == 0) {
            return bytes10(0);
        }

        // Convert workflow name to bytes10:
        // SHA256 hash → hex encode → take first 10 chars → hex encode those chars
        bytes32 hash = sha256(bytes(_name));
        bytes memory hexString = _creReceiverBytesToHexString(abi.encodePacked(hash));
        bytes memory first10 = new bytes(10);
        for (uint256 i = 0; i < 10; i++) {
            first10[i] = hexString[i];
        }
        return bytes10(first10);
    }
}
