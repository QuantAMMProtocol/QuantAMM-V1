// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {
    IERC165
} from "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v5.0.2/contracts/utils/introspection/IERC165.sol";
import { IReceiver } from "@chainlink/contracts/src/v0.8/keystone/interfaces/IReceiver.sol";

import { MockCreReceiver } from "../../../contracts/mock/mockRules/MockCreReceiver.sol";
import { CreReceiver } from "../../../contracts/rules/CreReceiver.sol";

contract CreReceiverFuzzTest is Test {
    MockCreReceiver internal receiver;

    // Re-declare events so we can use expectEmit
    event ExpectedAuthorChanged(address indexed newAuthor, address indexed oldAuthor, address indexed changer);
    event ExpectedWorkflowNameChanged(bytes10 indexed newName, bytes10 indexed oldName, address indexed changer);
    event ExpectedWorkflowIdChanged(bytes32 indexed newId, bytes32 indexed oldId, address indexed changer);
    event ForwarderAddressChanged(address indexed newForwarder, address indexed oldForwarder, address indexed changer);

    function setUp() public {
        receiver = new MockCreReceiver(address(this));
    }

    // -----------------------
    // Helpers
    // -----------------------

    function _encodeMetadata(
        bytes32 workflowId,
        bytes10 workflowName,
        address workflowOwner
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(workflowId, workflowName, workflowOwner);
    }

    function _invalidSenderSelector() internal pure returns (bytes4) {
        return bytes4(keccak256("InvalidSender(address,address)"));
    }

    function _invalidAuthorSelector() internal pure returns (bytes4) {
        return bytes4(keccak256("InvalidAuthor(address,address)"));
    }

    function _invalidWorkflowIdSelector() internal pure returns (bytes4) {
        return bytes4(keccak256("InvalidWorkflowId(bytes32,bytes32)"));
    }

    function _invalidWorkflowNameSelector() internal pure returns (bytes4) {
        return bytes4(keccak256("InvalidWorkflowName(bytes10,bytes10)"));
    }

    function _ownableUnauthorizedAccountSelector() internal pure returns (bytes4) {
        return bytes4(keccak256("OwnableUnauthorizedAccount(address)"));
    }

    // -----------------------
    // Fuzz: admin setters
    // -----------------------

    function testFuzz_SetForwarderAddressUpdatesStateAndEmitsEvent(address newForwarder) public {
        address oldForwarder = receiver.getForwarderAddress();

        vm.expectEmit(true, true, true, false);
        emit ForwarderAddressChanged(newForwarder, oldForwarder, address(this));

        receiver.setForwarderAddress(newForwarder);

        assertEq(receiver.getForwarderAddress(), newForwarder);
    }

    function testFuzz_SetForwarderAddressOnlyOwner(address nonOwner, address newForwarder) public {
        vm.assume(nonOwner != address(this));

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(_ownableUnauthorizedAccountSelector(), nonOwner));
        receiver.setForwarderAddress(newForwarder);
    }

    function testFuzz_SetExpectedAuthorUpdatesStateAndEmitsEvent(address newAuthor) public {
        address oldAuthor = receiver.getExpectedAuthor();

        vm.expectEmit(true, true, true, false);
        emit ExpectedAuthorChanged(newAuthor, oldAuthor, address(this));

        receiver.setExpectedAuthor(newAuthor);

        assertEq(receiver.getExpectedAuthor(), newAuthor);
    }

    function testFuzz_SetExpectedAuthorOnlyOwner(address nonOwner, address newAuthor) public {
        vm.assume(nonOwner != address(this));

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(_ownableUnauthorizedAccountSelector(), nonOwner));
        receiver.setExpectedAuthor(newAuthor);
    }

    function testFuzz_SetExpectedWorkflowNameUpdatesStateAndEmitsEvent(bytes10 newName) public {
        bytes10 oldName = receiver.getExpectedWorkflowName();

        vm.expectEmit(true, true, true, false);
        emit ExpectedWorkflowNameChanged(newName, oldName, address(this));

        string memory newNameStr = string(abi.encodePacked(newName));
        receiver.setExpectedWorkflowName(newNameStr);

        assertEq(receiver.getExpectedWorkflowName(), newName);
    }

    function testFuzz_SetExpectedWorkflowNameOnlyOwner(bytes10 newName, address nonOwner) public {
        vm.assume(nonOwner != address(this));

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(_ownableUnauthorizedAccountSelector(), nonOwner));

        string memory newNameStr = string(abi.encodePacked(newName));
        receiver.setExpectedWorkflowName(newNameStr);
    }

    function testFuzz_SetExpectedWorkflowIdUpdatesStateAndEmitsEvent(bytes32 newId) public {
        bytes32 oldId = receiver.getExpectedWorkflowId();

        vm.expectEmit(true, true, true, false);
        emit ExpectedWorkflowIdChanged(newId, oldId, address(this));

        receiver.setExpectedWorkflowId(newId);

        assertEq(receiver.getExpectedWorkflowId(), newId);
    }

    function testFuzz_SetExpectedWorkflowIdOnlyOwner(bytes32 newId, address nonOwner) public {
        vm.assume(nonOwner != address(this));

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(_ownableUnauthorizedAccountSelector(), nonOwner));
        receiver.setExpectedWorkflowId(newId);
    }

    function testFuzz_SetForwarderAddressEmitsWhenSettingSameValue(address forwarder) public {
        receiver.setForwarderAddress(forwarder);

        vm.expectEmit(true, true, true, false);
        emit ForwarderAddressChanged(forwarder, forwarder, address(this));

        receiver.setForwarderAddress(forwarder);
    }

    function testFuzz_SetExpectedAuthorEmitsWhenSettingSameValue(address author) public {
        receiver.setExpectedAuthor(author);

        vm.expectEmit(true, true, true, false);
        emit ExpectedAuthorChanged(author, author, address(this));

        receiver.setExpectedAuthor(author);
    }

    function testFuzz_SetExpectedWorkflowNameEmitsWhenSettingSameValue(bytes10 name) public {
        string memory nameStr = string(abi.encodePacked(name));
        receiver.setExpectedWorkflowName(nameStr);

        vm.expectEmit(true, true, true, false);
        emit ExpectedWorkflowNameChanged(name, name, address(this));

        receiver.setExpectedWorkflowName(nameStr);
    }

    function testFuzz_SetExpectedWorkflowIdEmitsWhenSettingSameValue(bytes32 id) public {
        receiver.setExpectedWorkflowId(id);

        vm.expectEmit(true, true, true, false);
        emit ExpectedWorkflowIdChanged(id, id, address(this));

        receiver.setExpectedWorkflowId(id);
    }

    function testFuzz_OnReportSucceedsWhenNoForwarderOrExpectationsSet(
        bytes32 workflowId,
        bytes10 workflowName,
        address workflowOwner,
        bytes memory report
    ) public {
        bytes memory metadata = _encodeMetadata(workflowId, workflowName, workflowOwner);

        receiver.onReport(metadata, report);
    }

    function testFuzz_OnReportRevertsForInvalidSenderWhenForwarderConfigured(
        address trustedForwarder,
        address badCaller,
        bytes32 workflowId,
        bytes10 workflowName,
        address workflowOwner,
        bytes memory report
    ) public {
        vm.assume(trustedForwarder != address(0));
        vm.assume(badCaller != trustedForwarder);

        receiver.setForwarderAddress(trustedForwarder);

        bytes memory metadata = _encodeMetadata(workflowId, workflowName, workflowOwner);

        vm.prank(badCaller);
        vm.expectRevert(abi.encodeWithSelector(_invalidSenderSelector(), badCaller, trustedForwarder));
        receiver.onReport(metadata, report);
    }

    function testFuzz_OnReportAllowsTrustedForwarder(
        address trustedForwarder,
        bytes32 workflowId,
        bytes10 workflowName,
        address workflowOwner,
        bytes memory report
    ) public {
        vm.assume(trustedForwarder != address(0));

        receiver.setForwarderAddress(trustedForwarder);

        bytes memory metadata = _encodeMetadata(workflowId, workflowName, workflowOwner);

        vm.prank(trustedForwarder);
        receiver.onReport(metadata, report);
    }

    function testFuzz_DisableForwarderAllowsAnySender(
        address trustedForwarder,
        address nonForwarder,
        bytes32 workflowId,
        bytes10 workflowName,
        address workflowOwner,
        bytes memory report
    ) public {
        vm.assume(trustedForwarder != address(0));
        vm.assume(nonForwarder != trustedForwarder);

        receiver.setForwarderAddress(trustedForwarder);
        bytes memory metadata = _encodeMetadata(workflowId, workflowName, workflowOwner);

        vm.prank(nonForwarder);
        vm.expectRevert(abi.encodeWithSelector(_invalidSenderSelector(), nonForwarder, trustedForwarder));
        receiver.onReport(metadata, report);

        receiver.setForwarderAddress(address(0));

        vm.prank(nonForwarder);
        receiver.onReport(metadata, report);
    }

    function testFuzz_OnReportRevertsForInvalidWorkflowId(
        bytes32 expectedId,
        bytes32 wrongId,
        bytes10 workflowName,
        address workflowOwner,
        bytes memory report
    ) public {
        vm.assume(expectedId != bytes32(0));
        vm.assume(wrongId != expectedId);

        receiver.setExpectedWorkflowId(expectedId);

        bytes memory metadata = _encodeMetadata(wrongId, workflowName, workflowOwner);

        vm.expectRevert(abi.encodeWithSelector(_invalidWorkflowIdSelector(), wrongId, expectedId));
        receiver.onReport(metadata, report);
    }

    function testFuzz_OnReportSucceedsWithCorrectWorkflowId(
        bytes32 expectedId,
        bytes10 workflowName,
        address workflowOwner,
        bytes memory report
    ) public {
        vm.assume(expectedId != bytes32(0));

        receiver.setExpectedWorkflowId(expectedId);

        bytes memory metadata = _encodeMetadata(expectedId, workflowName, workflowOwner);

        receiver.onReport(metadata, report);
    }

    function testFuzz_DisableExpectedWorkflowIdAllowsAnyWorkflowId(
        bytes32 expectedId,
        bytes32 wrongId,
        bytes10 workflowName,
        address workflowOwner,
        bytes memory report
    ) public {
        vm.assume(expectedId != bytes32(0));
        vm.assume(wrongId != expectedId);

        receiver.setExpectedWorkflowId(expectedId);

        bytes memory badMetadata = _encodeMetadata(wrongId, workflowName, workflowOwner);

        vm.expectRevert(abi.encodeWithSelector(_invalidWorkflowIdSelector(), wrongId, expectedId));
        receiver.onReport(badMetadata, report);

        receiver.setExpectedWorkflowId(bytes32(0));

        receiver.onReport(badMetadata, report);
    }

    function testFuzz_OnReportRevertsForInvalidAuthor(
        address expectedAuthor,
        address wrongOwner,
        bytes32 workflowId,
        bytes10 workflowName,
        bytes memory report
    ) public {
        vm.assume(expectedAuthor != address(0));
        vm.assume(wrongOwner != expectedAuthor);

        receiver.setExpectedAuthor(expectedAuthor);

        bytes memory metadata = _encodeMetadata(workflowId, workflowName, wrongOwner);

        vm.expectRevert(abi.encodeWithSelector(_invalidAuthorSelector(), wrongOwner, expectedAuthor));
        receiver.onReport(metadata, report);
    }

    function testFuzz_OnReportSucceedsWithCorrectAuthor(
        address expectedAuthor,
        bytes32 workflowId,
        bytes10 workflowName,
        bytes memory report
    ) public {
        vm.assume(expectedAuthor != address(0));

        receiver.setExpectedAuthor(expectedAuthor);

        bytes memory metadata = _encodeMetadata(workflowId, workflowName, expectedAuthor);

        receiver.onReport(metadata, report);
    }

    function testFuzz_DisableExpectedAuthorAllowsAnyAuthor(
        address expectedAuthor,
        address wrongOwner,
        bytes32 workflowId,
        bytes10 workflowName,
        bytes memory report
    ) public {
        vm.assume(expectedAuthor != address(0));
        vm.assume(wrongOwner != expectedAuthor);

        receiver.setExpectedAuthor(expectedAuthor);

        bytes memory metadata = _encodeMetadata(workflowId, workflowName, wrongOwner);

        vm.expectRevert(abi.encodeWithSelector(_invalidAuthorSelector(), wrongOwner, expectedAuthor));
        receiver.onReport(metadata, report);

        receiver.setExpectedAuthor(address(0));

        receiver.onReport(metadata, report);
    }

    function testFuzz_OnReportRevertsForInvalidWorkflowName(
        bytes10 expectedName,
        bytes10 wrongName,
        bytes32 workflowId,
        address workflowOwner,
        bytes memory report
    ) public {
        vm.assume(expectedName != bytes10(0));
        vm.assume(wrongName != expectedName);

        string memory wfNameStr = string(abi.encodePacked(expectedName));
        receiver.setExpectedWorkflowName(wfNameStr);

        bytes memory metadata = _encodeMetadata(workflowId, wrongName, workflowOwner);

        vm.expectRevert(abi.encodeWithSelector(_invalidWorkflowNameSelector(), wrongName, expectedName));
        receiver.onReport(metadata, report);
    }

    function testFuzz_OnReportSucceedsWithCorrectWorkflowName(
        bytes10 expectedName,
        bytes32 workflowId,
        address workflowOwner,
        bytes memory report
    ) public {
        vm.assume(expectedName != bytes10(0));

        string memory wfNameStr = string(abi.encodePacked(expectedName));
        receiver.setExpectedWorkflowName(wfNameStr);

        bytes memory metadata = _encodeMetadata(workflowId, expectedName, workflowOwner);

        receiver.onReport(metadata, report);
    }

    function testFuzz_DisableExpectedWorkflowNameAllowsAnyWorkflowName(
        bytes10 expectedName,
        bytes10 wrongName,
        bytes32 workflowId,
        address workflowOwner,
        bytes memory report
    ) public {
        vm.assume(expectedName != bytes10(0));
        vm.assume(wrongName != expectedName);

        string memory wfNameStr = string(abi.encodePacked(expectedName));
        receiver.setExpectedWorkflowName(wfNameStr);

        bytes memory badMetadata = _encodeMetadata(workflowId, wrongName, workflowOwner);

        vm.expectRevert(abi.encodeWithSelector(_invalidWorkflowNameSelector(), wrongName, expectedName));
        receiver.onReport(badMetadata, report);

        receiver.setExpectedWorkflowName(wfNameStr);

        receiver.onReport(badMetadata, report);
    }

    function testFuzz_OnReportIgnoresAllExpectationsWhenZero(
        bytes32 workflowId,
        bytes10 workflowName,
        address workflowOwner,
        bytes memory report
    ) public {
        assertEq(receiver.getForwarderAddress(), address(0));
        assertEq(receiver.getExpectedAuthor(), address(0));
        assertEq(receiver.getExpectedWorkflowName(), bytes10(0));
        assertEq(receiver.getExpectedWorkflowId(), bytes32(0));

        bytes memory metadata = _encodeMetadata(workflowId, workflowName, workflowOwner);

        receiver.onReport(metadata, report);
    }

    function testFuzz_OnReportRevertsWithInvalidWorkflowIdPrecedence(
        bytes32 expectedId,
        bytes32 wrongId,
        bytes10 expectedName,
        bytes10 wrongName,
        address expectedAuthor,
        address wrongAuthor,
        bytes memory report
    ) public {
        vm.assume(expectedId != bytes32(0));
        vm.assume(expectedName != bytes10(0));
        vm.assume(expectedAuthor != address(0));

        vm.assume(wrongId != expectedId);
        vm.assume(wrongName != expectedName);
        vm.assume(wrongAuthor != expectedAuthor);

        receiver.setExpectedWorkflowId(expectedId);
        receiver.setExpectedAuthor(expectedAuthor);
        string memory wfNameStr = string(abi.encodePacked(expectedName));
        receiver.setExpectedWorkflowName(wfNameStr);

        bytes memory metadata = _encodeMetadata(wrongId, wrongName, wrongAuthor);

        // WorkflowId is checked first
        vm.expectRevert(abi.encodeWithSelector(_invalidWorkflowIdSelector(), wrongId, expectedId));
        receiver.onReport(metadata, report);
    }

    function testFuzz_OnReportRevertsWithInvalidAuthorBeforeWorkflowName(
        address expectedAuthor,
        address wrongAuthor,
        bytes10 expectedName,
        bytes10 wrongName,
        bytes32 workflowId,
        bytes memory report
    ) public {
        vm.assume(expectedAuthor != address(0));
        vm.assume(expectedName != bytes10(0));

        vm.assume(wrongAuthor != expectedAuthor);
        vm.assume(wrongName != expectedName);

        receiver.setExpectedAuthor(expectedAuthor);
        string memory wfNameStr = string(abi.encodePacked(expectedName));
        receiver.setExpectedWorkflowName(wfNameStr);

        bytes memory metadata = _encodeMetadata(workflowId, wrongName, wrongAuthor);

        vm.expectRevert(abi.encodeWithSelector(_invalidAuthorSelector(), wrongAuthor, expectedAuthor));
        receiver.onReport(metadata, report);
    }

    function testFuzz_OnReportRevertsInvalidWorkflowIdEvenWhenForwarderCorrect(
        address trustedForwarder,
        bytes32 expectedId,
        bytes32 wrongId,
        bytes10 workflowName,
        address workflowOwner,
        bytes memory report
    ) public {
        vm.assume(trustedForwarder != address(0));
        vm.assume(expectedId != bytes32(0));
        vm.assume(wrongId != expectedId);

        receiver.setForwarderAddress(trustedForwarder);
        receiver.setExpectedWorkflowId(expectedId);

        bytes memory metadata = _encodeMetadata(wrongId, workflowName, workflowOwner);

        vm.prank(trustedForwarder);
        vm.expectRevert(abi.encodeWithSelector(_invalidWorkflowIdSelector(), wrongId, expectedId));
        receiver.onReport(metadata, report);
    }

    function testFuzz_OnReportSucceedsWhenAllChecksPass(
        address trustedForwarder,
        bytes32 workflowId,
        address workflowOwner,
        bytes memory report,
        bytes10 workflowName
    ) public {
        vm.assume(trustedForwarder != address(0));
        vm.assume(workflowId != bytes32(0));
        vm.assume(workflowOwner != address(0));

        string memory wfNameStr = string(abi.encodePacked(workflowName));

        receiver.setForwarderAddress(trustedForwarder);
        receiver.setExpectedWorkflowId(workflowId);
        receiver.setExpectedWorkflowName(wfNameStr);
        receiver.setExpectedAuthor(workflowOwner);

        bytes memory metadata = _encodeMetadata(workflowId, workflowName, workflowOwner);

        vm.prank(trustedForwarder);
        receiver.onReport(metadata, report);
    }

    function testFuzz_SupportsInterface(bytes4 interfaceId) public view {
        bool expected = interfaceId == type(IReceiver).interfaceId || interfaceId == type(IERC165).interfaceId;

        assertEq(receiver.supportsInterface(interfaceId), expected);
    }
}
