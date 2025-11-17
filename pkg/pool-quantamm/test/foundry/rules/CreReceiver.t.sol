// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {
    IERC165
} from "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v5.0.2/contracts/utils/introspection/IERC165.sol";
import { IReceiver } from "@chainlink/contracts/src/v0.8/keystone/interfaces/IReceiver.sol";

import { MockCreReceiver } from "../../../contracts/mock/mockRules/MockCreReceiver.sol";
import { CreReceiver } from "../../../contracts/rules/CreReceiver.sol";

contract CreReceiverTest is Test {
    MockCreReceiver internal receiver;

    // Re-declare events so we can use expectEmit
    event ExpectedAuthorChanged(address indexed newAuthor, address indexed oldAuthor, address indexed changer);
    event ExpectedWorkflowNameChanged(bytes10 indexed newName, bytes10 indexed oldName, address indexed changer);
    event ExpectedWorkflowIdChanged(bytes32 indexed newId, bytes32 indexed oldId, address indexed changer);
    event ForwarderAddressChanged(address indexed newForwarder, address indexed oldForwarder, address indexed changer);

    function setUp() public {
        receiver = new MockCreReceiver();
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

    function testInitialState() public view {
        assertEq(receiver.forwarderAddress(), address(0));
        assertEq(receiver.expectedAuthor(), address(0));
        assertEq(receiver.expectedWorkflowName(), bytes10(0));
        assertEq(receiver.expectedWorkflowId(), bytes32(0));

        // CreReceiver constructor passes msg.sender into Ownable
        assertEq(receiver.owner(), address(this));
    }

    function testSetForwarderAddressUpdatesStateAndEmitsEvent() public {
        address newForwarder = address(0xF0F0);
        address oldForwarder = receiver.forwarderAddress();

        vm.expectEmit(true, true, true, false);
        emit ForwarderAddressChanged(newForwarder, oldForwarder, address(this));

        receiver.setForwarderAddress(newForwarder);

        assertEq(receiver.forwarderAddress(), newForwarder);
    }

    function testSetForwarderAddressOnlyOwner() public {
        address nonOwner = address(0xBEEF);
        address newForwarder = address(0xF0F0);

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(_ownableUnauthorizedAccountSelector(), nonOwner));
        receiver.setForwarderAddress(newForwarder);
    }

    function testSetExpectedAuthorUpdatesStateAndEmitsEvent() public {
        address newAuthor = address(0xA1);
        address oldAuthor = receiver.expectedAuthor();

        vm.expectEmit(true, true, true, false);
        emit ExpectedAuthorChanged(newAuthor, oldAuthor, address(this));

        receiver.setExpectedAuthor(newAuthor);

        assertEq(receiver.expectedAuthor(), newAuthor);
    }

    function testSetExpectedAuthorOnlyOwner() public {
        address nonOwner = address(0xBEEF);
        address newAuthor = address(0xA1);

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(_ownableUnauthorizedAccountSelector(), nonOwner));
        receiver.setExpectedAuthor(newAuthor);
    }

    function testSetExpectedWorkflowNameUpdatesStateAndEmitsEvent() public {
        bytes10 newName = bytes10("WF_LOW_001");
        bytes10 oldName = receiver.expectedWorkflowName();

        vm.expectEmit(true, true, true, false);
        emit ExpectedWorkflowNameChanged(newName, oldName, address(this));

        receiver.setExpectedWorkflowName(newName);

        assertEq(receiver.expectedWorkflowName(), newName);
    }

    function testSetExpectedWorkflowNameOnlyOwner() public {
        address nonOwner = address(0xBEEF);
        bytes10 newName = bytes10("WF_LOW_001");

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(_ownableUnauthorizedAccountSelector(), nonOwner));
        receiver.setExpectedWorkflowName(newName);
    }

    function testSetExpectedWorkflowIdUpdatesStateAndEmitsEvent() public {
        bytes32 newId = keccak256("new-workflow-id");
        bytes32 oldId = receiver.expectedWorkflowId();

        vm.expectEmit(true, true, true, false);
        emit ExpectedWorkflowIdChanged(newId, oldId, address(this));

        receiver.setExpectedWorkflowId(newId);

        assertEq(receiver.expectedWorkflowId(), newId);
    }

    function testSetExpectedWorkflowIdOnlyOwner() public {
        address nonOwner = address(0xBEEF);
        bytes32 newId = keccak256("new-workflow-id");

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(_ownableUnauthorizedAccountSelector(), nonOwner));
        receiver.setExpectedWorkflowId(newId);
    }

    function testOnReportSucceedsWhenNoForwarderOrExpectationsSet() public {
        bytes memory metadata = "";
        bytes memory report = abi.encodePacked(uint256(123));

        receiver.onReport(metadata, report);

        assertTrue(receiver.processCalled());
        assertEq(receiver.lastReport(), report);
    }

    function testOnReportRevertsForInvalidSenderWhenForwarderIsConfigured() public {
        address trustedForwarder = address(0xF0F0);
        receiver.setForwarderAddress(trustedForwarder);

        address badCaller = address(0xBAD);
        bytes memory metadata = "";
        bytes memory report = abi.encodePacked(uint256(123));

        vm.prank(badCaller);
        vm.expectRevert(abi.encodeWithSelector(_invalidSenderSelector(), badCaller, trustedForwarder));
        receiver.onReport(metadata, report);
    }

    function testOnReportAllowsTrustedForwarder() public {
        address trustedForwarder = address(0xF0F0);
        receiver.setForwarderAddress(trustedForwarder);

        bytes32 workflowId = keccak256("wf-id");
        bytes10 workflowName = bytes10("WF_LOW_001");
        address workflowOwner = address(this);

        bytes memory metadata = _encodeMetadata(workflowId, workflowName, workflowOwner);
        bytes memory report = abi.encodePacked(uint256(999));

        vm.prank(trustedForwarder);
        receiver.onReport(metadata, report);

        assertTrue(receiver.processCalled());
        assertEq(receiver.lastReport(), report);
    }

    function testOnReportRevertsForInvalidWorkflowId() public {
        bytes32 expectedId = keccak256("expected-id");
        receiver.setExpectedWorkflowId(expectedId);

        bytes32 wrongId = keccak256("wrong-id");
        bytes10 workflowName = bytes10("WF_LOW_001");
        address workflowOwner = address(this);

        bytes memory metadata = _encodeMetadata(wrongId, workflowName, workflowOwner);
        bytes memory report = abi.encodePacked(uint256(123));

        vm.expectRevert(abi.encodeWithSelector(_invalidWorkflowIdSelector(), wrongId, expectedId));
        receiver.onReport(metadata, report);
    }

    function testOnReportSucceedsWithCorrectWorkflowId() public {
        bytes32 expectedId = keccak256("expected-id");
        receiver.setExpectedWorkflowId(expectedId);

        bytes10 workflowName = bytes10("WF_LOW_001");
        address workflowOwner = address(this);

        bytes memory metadata = _encodeMetadata(expectedId, workflowName, workflowOwner);
        bytes memory report = abi.encodePacked(uint256(123));

        receiver.onReport(metadata, report);

        assertTrue(receiver.processCalled());
        assertEq(receiver.lastReport(), report);
    }

    function testOnReportRevertsForInvalidAuthor() public {
        address expectedAuthor = address(0xA1);
        receiver.setExpectedAuthor(expectedAuthor);

        bytes32 workflowId = keccak256("wf-id");
        bytes10 workflowName = bytes10("WF_LOW_001");
        address wrongOwner = address(0xDEAD);

        bytes memory metadata = _encodeMetadata(workflowId, workflowName, wrongOwner);
        bytes memory report = abi.encodePacked(uint256(123));

        vm.expectRevert(abi.encodeWithSelector(_invalidAuthorSelector(), wrongOwner, expectedAuthor));
        receiver.onReport(metadata, report);
    }

    function testOnReportSucceedsWithCorrectAuthor() public {
        address expectedAuthor = address(0xA1);
        receiver.setExpectedAuthor(expectedAuthor);

        bytes32 workflowId = keccak256("wf-id");
        bytes10 workflowName = bytes10("WF_LOW_001");

        bytes memory metadata = _encodeMetadata(workflowId, workflowName, expectedAuthor);
        bytes memory report = abi.encodePacked(uint256(123));

        receiver.onReport(metadata, report);

        assertTrue(receiver.processCalled());
        assertEq(receiver.lastReport(), report);
    }

    function testOnReportRevertsForInvalidWorkflowName() public {
        bytes10 expectedName = bytes10("WF_EXPECT");
        receiver.setExpectedWorkflowName(expectedName);

        bytes32 workflowId = keccak256("wf-id");
        bytes10 wrongName = bytes10("WF_WRONG");
        address workflowOwner = address(this);

        bytes memory metadata = _encodeMetadata(workflowId, wrongName, workflowOwner);
        bytes memory report = abi.encodePacked(uint256(123));

        vm.expectRevert(abi.encodeWithSelector(_invalidWorkflowNameSelector(), wrongName, expectedName));
        receiver.onReport(metadata, report);
    }

    function testOnReportSucceedsWithCorrectWorkflowName() public {
        bytes10 expectedName = bytes10("WF_EXPECT");
        receiver.setExpectedWorkflowName(expectedName);

        bytes32 workflowId = keccak256("wf-id");
        address workflowOwner = address(this);

        bytes memory metadata = _encodeMetadata(workflowId, expectedName, workflowOwner);
        bytes memory report = abi.encodePacked(uint256(123));

        receiver.onReport(metadata, report);

        assertTrue(receiver.processCalled());
        assertEq(receiver.lastReport(), report);
    }

    function testOnReportSucceedsWhenAllChecksPass() public {
        address trustedForwarder = address(0xF0F0);
        receiver.setForwarderAddress(trustedForwarder);

        bytes32 expectedId = keccak256("expected-id");
        bytes10 expectedName = bytes10("WF_EXPECT");
        address expectedAuthor = address(0xA1);

        receiver.setExpectedWorkflowId(expectedId);
        receiver.setExpectedWorkflowName(expectedName);
        receiver.setExpectedAuthor(expectedAuthor);

        bytes memory metadata = _encodeMetadata(expectedId, expectedName, expectedAuthor);
        bytes memory report = abi.encodePacked(uint256(777));

        vm.prank(trustedForwarder);
        receiver.onReport(metadata, report);

        assertTrue(receiver.processCalled());
        assertEq(receiver.lastReport(), report);
    }

    function testDisableForwarderAllowsAnySender() public {
        address trustedForwarder = address(0xF0F0);
        receiver.setForwarderAddress(trustedForwarder);

        address nonForwarder = address(0xBEEF);
        bytes memory metadata = "";
        bytes memory report = abi.encodePacked(uint256(111));

        vm.prank(nonForwarder);
        vm.expectRevert(abi.encodeWithSelector(_invalidSenderSelector(), nonForwarder, trustedForwarder));

        receiver.onReport(metadata, report);
        receiver.setForwarderAddress(address(0));

        vm.prank(nonForwarder);
        receiver.onReport(metadata, report);

        assertTrue(receiver.processCalled());
        assertEq(receiver.lastReport(), report);
    }

    function testDisableExpectedAuthorAllowsAnyAuthor() public {
        address expectedAuthor = address(0xA1);
        receiver.setExpectedAuthor(expectedAuthor);

        bytes32 workflowId = keccak256("wf-id");
        bytes10 workflowName = bytes10("WF_AUTH");
        address wrongOwner = address(0xDEAD);

        bytes memory metadata = _encodeMetadata(workflowId, workflowName, wrongOwner);
        bytes memory report = abi.encodePacked(uint256(222));

        vm.expectRevert(abi.encodeWithSelector(_invalidAuthorSelector(), wrongOwner, expectedAuthor));
        receiver.onReport(metadata, report);

        receiver.setExpectedAuthor(address(0));
        receiver.onReport(metadata, report);

        assertTrue(receiver.processCalled());
        assertEq(receiver.lastReport(), report);
    }

    function testDisableExpectedWorkflowIdAllowsAnyWorkflowId() public {
        bytes32 expectedId = keccak256("expected-id");
        receiver.setExpectedWorkflowId(expectedId);

        bytes32 wrongId = keccak256("wrong-id");
        bytes10 workflowName = bytes10("WF_ID");
        address workflowOwner = address(this);

        bytes memory badMetadata = _encodeMetadata(wrongId, workflowName, workflowOwner);
        bytes memory report = abi.encodePacked(uint256(333));

        vm.expectRevert(abi.encodeWithSelector(_invalidWorkflowIdSelector(), wrongId, expectedId));
        receiver.onReport(badMetadata, report);

        receiver.setExpectedWorkflowId(bytes32(0));

        receiver.onReport(badMetadata, report);
        assertTrue(receiver.processCalled());
        assertEq(receiver.lastReport(), report);
    }

    function testDisableExpectedWorkflowNameAllowsAnyWorkflowName() public {
        bytes10 expectedName = bytes10("WF_NAME_OK");
        receiver.setExpectedWorkflowName(expectedName);

        bytes32 workflowId = keccak256("wf-id");
        bytes10 wrongName = bytes10("BAD_NAME");
        address workflowOwner = address(this);

        bytes memory badMetadata = _encodeMetadata(workflowId, wrongName, workflowOwner);
        bytes memory report = abi.encodePacked(uint256(444));

        vm.expectRevert(abi.encodeWithSelector(_invalidWorkflowNameSelector(), wrongName, expectedName));
        receiver.onReport(badMetadata, report);

        receiver.setExpectedWorkflowName(bytes10(0));

        receiver.onReport(badMetadata, report);
        assertTrue(receiver.processCalled());
        assertEq(receiver.lastReport(), report);
    }

    function testOnReportIgnoresAuthorWhenExpectationZero() public {
        // Expectation is zero by default
        assertEq(receiver.expectedAuthor(), address(0));

        bytes32 workflowId = keccak256("wf-id");
        bytes10 workflowName = bytes10("WF_AUTH0");
        address arbitraryOwner = address(0xDEAD);

        bytes memory metadata = _encodeMetadata(workflowId, workflowName, arbitraryOwner);
        bytes memory report = abi.encodePacked(uint256(555));

        receiver.onReport(metadata, report);
        assertTrue(receiver.processCalled());
        assertEq(receiver.lastReport(), report);
    }

    function testOnReportIgnoresWorkflowIdWhenExpectationZero() public {
        assertEq(receiver.expectedWorkflowId(), bytes32(0));

        bytes32 anyId = keccak256("any-id");
        bytes10 workflowName = bytes10("WF_ID0");
        address workflowOwner = address(this);

        bytes memory metadata = _encodeMetadata(anyId, workflowName, workflowOwner);
        bytes memory report = abi.encodePacked(uint256(666));

        receiver.onReport(metadata, report);
        assertTrue(receiver.processCalled());
        assertEq(receiver.lastReport(), report);
    }

    function testOnReportIgnoresWorkflowNameWhenExpectationZero() public {
        assertEq(receiver.expectedWorkflowName(), bytes10(0));

        bytes32 workflowId = keccak256("wf-id");
        bytes10 anyName = bytes10("ANY_NAME");
        address workflowOwner = address(this);

        bytes memory metadata = _encodeMetadata(workflowId, anyName, workflowOwner);
        bytes memory report = abi.encodePacked(uint256(7777));

        receiver.onReport(metadata, report);
        assertTrue(receiver.processCalled());
        assertEq(receiver.lastReport(), report);
    }

    function testOnReportRevertsWithInvalidWorkflowIdPrecedence() public {
        bytes32 expectedId = keccak256("expected-id");
        receiver.setExpectedWorkflowId(expectedId);

        address expectedAuthor = address(0xA1);
        receiver.setExpectedAuthor(expectedAuthor);

        bytes10 expectedName = bytes10("WF_EXPECT");
        receiver.setExpectedWorkflowName(expectedName);

        // All three are wrong: id, author, name
        bytes32 wrongId = keccak256("wrong-id");
        address wrongAuthor = address(0xDEAD);
        bytes10 wrongName = bytes10("WF_WRONG");

        bytes memory metadata = _encodeMetadata(wrongId, wrongName, wrongAuthor);
        bytes memory report = abi.encodePacked(uint256(888));

        vm.expectRevert(abi.encodeWithSelector(_invalidWorkflowIdSelector(), wrongId, expectedId));
        receiver.onReport(metadata, report);
    }

    function testOnReportRevertsWithInvalidAuthorBeforeWorkflowName() public {
        address expectedAuthor = address(0xA1);
        receiver.setExpectedAuthor(expectedAuthor);

        bytes10 expectedName = bytes10("WF_EXPECT");
        receiver.setExpectedWorkflowName(expectedName);

        bytes32 workflowId = keccak256("wf-id");
        address wrongAuthor = address(0xDEAD);
        bytes10 wrongName = bytes10("WF_WRONG");

        bytes memory metadata = _encodeMetadata(workflowId, wrongName, wrongAuthor);
        bytes memory report = abi.encodePacked(uint256(999));

        vm.expectRevert(abi.encodeWithSelector(_invalidAuthorSelector(), wrongAuthor, expectedAuthor));
        receiver.onReport(metadata, report);
    }

    function testSupportsInterfaceERC165AndIReceiverAndUnknown() public view {
        assertTrue(receiver.supportsInterface(type(IERC165).interfaceId));
        assertTrue(receiver.supportsInterface(type(IReceiver).interfaceId));
        assertFalse(receiver.supportsInterface(0xffffffff));
    }

    function testOnReportRevertsInvalidWorkflowIdEvenWhenForwarderCorrect() public {
        address trustedForwarder = address(0xF0F0);
        receiver.setForwarderAddress(trustedForwarder);

        bytes32 expectedId = keccak256("expected-id");
        receiver.setExpectedWorkflowId(expectedId);

        bytes32 wrongId = keccak256("wrong-id");
        bytes10 workflowName = bytes10("WF_MIX");
        address workflowOwner = address(0xA1);

        bytes memory metadata = _encodeMetadata(wrongId, workflowName, workflowOwner);
        bytes memory report = abi.encodePacked(uint256(4242));

        vm.prank(trustedForwarder);
        vm.expectRevert(abi.encodeWithSelector(_invalidWorkflowIdSelector(), wrongId, expectedId));
        receiver.onReport(metadata, report);
    }

    function testSetForwarderAddressEmitsWhenSettingSameValue() public {
        address forwarder = address(0xF0F0);
        receiver.setForwarderAddress(forwarder);

        vm.expectEmit(true, true, true, false);
        emit ForwarderAddressChanged(forwarder, forwarder, address(this));

        receiver.setForwarderAddress(forwarder);
    }

    function testSetExpectedAuthorEmitsWhenSettingSameValue() public {
        address author = address(0xA1);
        receiver.setExpectedAuthor(author);

        vm.expectEmit(true, true, true, false);
        emit ExpectedAuthorChanged(author, author, address(this));

        receiver.setExpectedAuthor(author);
    }

    function testSetExpectedWorkflowNameEmitsWhenSettingSameValue() public {
        bytes10 name = bytes10("WF_REPEAT");
        receiver.setExpectedWorkflowName(name);

        vm.expectEmit(true, true, true, false);
        emit ExpectedWorkflowNameChanged(name, name, address(this));

        receiver.setExpectedWorkflowName(name);
    }

    function testSetExpectedWorkflowIdEmitsWhenSettingSameValue() public {
        bytes32 id = keccak256("same-id");
        receiver.setExpectedWorkflowId(id);

        vm.expectEmit(true, true, true, false);
        emit ExpectedWorkflowIdChanged(id, id, address(this));

        receiver.setExpectedWorkflowId(id);
    }
}
