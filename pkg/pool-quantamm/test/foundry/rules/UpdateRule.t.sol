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
        updateRule = new MockUpdateRule(owner);
    }

    function testUpdateRuleUnAuthCalc() public {
        vm.expectRevert("UNAUTH_CALC");
        updateRule.CalculateNewWeights(
        new int256[](0),
        new int256[](0),
        address(mockPool),
        new int256[][](0),
        new uint64[](0),
        uint64(1),
        uint64(1));
    }

    function testUpdateRuleAuthCalc() public {

    }

    function testUpdateRuleMovingAverageStorageWithoutPrev() public {}

    function testUpdateRuleMovingAverageStorageWithPrev() public {}

    function testUpdateRuleGetWeights() public {}

    function testUpdateRuleGuardWights() public {}

    function testUpdateRuleInitialisePoolUnAuth() public {}

    function testUpdateRuleInitialisePoolPoolAuth() public {}

    function testUpdateRuleInitialisePoolUpdateWeightRunnerAuth() public {}

    function testUpdateRuleInitialisePoolAvergesAdminAuth() public {}

    function testUpdateRuleInitialisePoolAveragesOwnerAuth() public {}
}