// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../../contracts/mock/mockRules/MockUpdateRule.sol";
import "../../../contracts/mock/MockPool.sol";
import "../utils.t.sol";

contract UpdateRuleTest is Test, QuantAMMTestUtils {
    address internal owner;
    address internal addr1;
    address internal addr2;

    MockPool public mockPool;
    MockUpdateRule updateRule;

    function setUp() public {
        (address ownerLocal, address addr1Local, address addr2Local) = (vm.addr(1), vm.addr(2), vm.addr(3));
        owner = ownerLocal;
        addr1 = addr1Local;
        addr2 = addr2Local;
        updateRule = new MockUpdateRule(address(this));
    }

    function testUnAuthCalc() public {

    }

    function testAuthCalc() public {

    }

    function testMovingAverageStorageWithoutPrev() public {}

    function testMovingAverageStorageWithPrev() public {}

    function testGetWeights() public {}

    function testGuardWights() public {}

    function testInitialisePoolUnAuth() public {}

    function testInitialisePoolPoolAuth() public {}

    function testInitialisePoolUpdateWeightRunnerAuth() public {}

    function testInitialisePoolAvergesAdminAuth() public {}

    function testInitialisePoolAveragesOwnerAuth() public {}
}