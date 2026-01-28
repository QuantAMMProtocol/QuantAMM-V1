// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import "../../../contracts/mock/MockRuleInvoker.sol";
import "../utils.t.sol";
import { CreUpdateRule } from "../../../contracts/rules/CreUpdateRule.sol";
import { MockCreUpdateRule } from "../../../contracts/mock/mockRules/MockCreUpdateRule.sol";
import { MockUpdateWeightRunner } from "../../../contracts/mock/MockUpdateWeightRunner.sol";
import { MockQuantAMMBasePool } from "../../../contracts/mock/MockQuantAMMBasePool.sol";
import { MockChainlinkOracle } from "../../../contracts/mock/MockChainlinkOracles.sol";

contract CreUpdateRuleTest is Test, QuantAMMTestUtils {
    MockCreUpdateRule public rule;
    MockUpdateWeightRunner public updateWeightRunner;
    MockQuantAMMBasePool public mockPool;

    address internal owner;
    address internal addr1;
    address internal addr2;
    MockChainlinkOracle internal chainlinkOracle;

    uint40 constant UPDATE_INTERVAL = 1800;

    event TargetWeightsForwarded(address indexed pool, address sender);
    event UpdateWeightRunnerChanged(address indexed newAddress, address indexed oldAddress, address indexed changer);

    function setUp() public {
        (address ownerLocal, address addr1Local, address addr2Local) = (vm.addr(1), vm.addr(2), vm.addr(3));
        owner = ownerLocal;
        addr1 = addr1Local;
        addr2 = addr2Local;
        // Deploying MockUpdateWeightRunner contract
        updateWeightRunner = new MockUpdateWeightRunner(owner, addr2, false);

        // Deploying MockCreUpdateRule contract
        rule = new MockCreUpdateRule(address(updateWeightRunner));
        rule.transferOwnership(owner);
        // Deploy MockPool contract with some mock parameters
        mockPool = new MockQuantAMMBasePool(UPDATE_INTERVAL, address(updateWeightRunner));
    }

    function testInitialiseIntermediateValueAlwaysPasses(
        uint256 numAssets,
        int256[] memory previousAlphas,
        int256[] memory prevMovingAverages
    ) public {
        // Simulate setting number of assets and calculating intermediate values
        vm.startPrank(owner);
        rule.initialisePoolRuleIntermediateValues(address(mockPool), prevMovingAverages, previousAlphas, numAssets);
        vm.stopPrank();
    }

    function testNoninitialisedParametersShouldBeAccepted() public view {
        int256[][] memory parameters;
        bool result = rule.validParameters(parameters);
        assertTrue(result);
    }

    function testEmptyParametersShouldNotBeAccepted() public view {
        int256[][] memory parameters = new int256[][](1);
        parameters[0] = new int256[](1);
        bool result = rule.validParameters(parameters);
        assertTrue(result);
    }

    function testEmpty1DParametersShouldBeAccepted() public view {
        int256[][] memory parameters = new int256[][](1);
        bool result = rule.validParameters(parameters);
        assertTrue(result);
    }

    function test0InitialisedParametersShouldBeAccepted() public view {
        int256[][] memory parameters = new int256[][](0);
        bool result = rule.validParameters(parameters);
        assertTrue(result);
    }

    function testZeroShouldBeAccepted() public view {
        int256[][] memory parameters = new int256[][](1);
        parameters[0] = new int256[](1);
        parameters[0][0] = PRBMathSD59x18.fromInt(0);
        bool result = rule.validParameters(parameters);
        assertTrue(result);
    }

    function test_setUpdateWeightRunner_revertsForNonOwner(address nonOwner) public {
        MockUpdateWeightRunner newRunner = new MockUpdateWeightRunner(owner, addr2, false);
        vm.assume(nonOwner != owner);
        vm.prank(nonOwner);
        vm.expectRevert();
        rule.setUpdateWeightRunner(address(newRunner));
    }

    function test_setUpdateWeightRunner_revertsOnZeroAddress() public {
        vm.startPrank(owner);

        vm.expectRevert(abi.encodeWithSelector(CreUpdateRule.InvalidAddress.selector, address(0)));
        rule.setUpdateWeightRunner(address(0));
        vm.stopPrank();
    }

    function test_setUpdateWeightRunner_emitsEventAndUpdatesOldAddress() public {
        MockUpdateWeightRunner newRunner = new MockUpdateWeightRunner(owner, addr2, false);
        // First set, oldAddress should be zero
        vm.expectEmit(false, false, false, true, address(rule));
        emit UpdateWeightRunnerChanged(address(newRunner), address(updateWeightRunner), address(owner));
        vm.prank(owner);
        rule.setUpdateWeightRunner(address(newRunner));
    }

    function test_CalculateNewWeights_revertsWithNotImplemented_forTestContractCaller(
        int256[] calldata prevWeights,
        int256[] calldata data,
        int256[][] calldata _parameters,
        uint64[] calldata lambdaStore
    ) public {
        vm.expectRevert(abi.encodeWithSelector(CreUpdateRule.NotImplemented.selector, address(this)));
        rule.CalculateNewWeights(prevWeights, data, address(0), _parameters, lambdaStore, 0, 0);
    }

    function test_CalculateNewWeights_revertsWithNotImplemented_forPrankedCaller(
        int256[] calldata prevWeights,
        int256[] calldata data,
        int256[][] calldata _parameters,
        uint64[] calldata lambdaStore
    ) public {
        vm.prank(addr1);
        vm.expectRevert(abi.encodeWithSelector(CreUpdateRule.NotImplemented.selector, addr1));
        rule.CalculateNewWeights(prevWeights, data, address(0xBEEF), _parameters, lambdaStore, 123, 456);
    }

    function test_ProcessReport(uint256 firstWeight, uint40 lastInterpolationTimePossible) public {
        int256[] memory initialWeights = new int256[](4);
        initialWeights[0] = 0.0000000005e18;
        initialWeights[1] = 0.0000000005e18;
        initialWeights[2] = 0;
        initialWeights[3] = 0;

        // Set initial weights
        mockPool.setInitialWeights(initialWeights);
        mockPool.setPoolRegistry(32);
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 32);
        vm.stopPrank();

        int216 fixedValue = 1000;
        chainlinkOracle = deployOracle(fixedValue, 0);

        vm.startPrank(owner);
        updateWeightRunner.addOracle(OracleWrapper(chainlinkOracle));
        vm.stopPrank();

        vm.startPrank(address(mockPool));

        address[][] memory oracles = new address[][](2);
        oracles[0] = new address[](1);
        oracles[0][0] = address(chainlinkOracle);
        oracles[1] = new address[](1);
        oracles[1][0] = address(chainlinkOracle);

        uint64[] memory lambda = new uint64[](1);
        uint40 updateInterval = uint40(bound(lastInterpolationTimePossible, 1, 15552000));
        updateWeightRunner.setRuleForPool(
            IQuantAMMWeightedPool.PoolSettings({
                assets: new IERC20[](0),
                rule: IUpdateRule(rule),
                oracles: oracles,
                updateInterval: updateInterval,
                lambda: lambda,
                epsilonMax: 0.9e18,
                absoluteWeightGuardRail: 0.2e18,
                maxTradeSizeRatio: 0.2e18,
                ruleParameters: new int256[][](0),
                poolManager: addr2
            })
        );
        vm.stopPrank();

        vm.startPrank(owner);
        uint256[] memory weights = new uint256[](2);
        weights[0] = bound(uint256(firstWeight), 0.2e18, 0.8e18);
        weights[1] = uint256(1e18) - weights[0];
        bytes memory metaData = abi.encode(
            CreUpdateRule.WorkflowMetadata({
                poolAddress: address(mockPool),
                weights: weights
            })
        );

        uint256[] memory currentPoolWeights = mockPool.getNormalizedWeights();
        assertEq(currentPoolWeights[0], uint256(initialWeights[0]));
        assertEq(currentPoolWeights[1], uint256(initialWeights[1]));

        vm.expectEmit(false, false, false, true, address(rule));
        emit TargetWeightsForwarded(address(mockPool), owner);
        rule.ProcessReport(metaData);

        int256[] memory newPoolWeights = mockPool.getWeights();
        assertEq(newPoolWeights[0], initialWeights[0]);
        assertEq(newPoolWeights[1], initialWeights[1]);

        //We dont need to test the mathguard. Epsilon max is high and the fuzzing is bound within the limits.
        //So we can just check that the multiplier is correctly calculated to make sure its goes through.
        int256 expectedMultiplier0 = (int256(weights[0]) - int256(initialWeights[0])) / int256(int40(updateInterval));

        int256 expectedMultiplier1 = (int256(weights[1]) - int256(initialWeights[1])) / int256(int40(updateInterval));

        assertEq(newPoolWeights[2], expectedMultiplier0);
        assertEq(newPoolWeights[3], expectedMultiplier1);

        vm.stopPrank();
    }

    function test_ProcessReport_revertsOnZeroPoolAddress() public {
        // Arrange: simple valid weights
        uint256[] memory weights = new uint256[](2);
        weights[0] = 0.5e18;
        weights[1] = 0.5e18;

        bytes memory metaData = abi.encode(
            CreUpdateRule.WorkflowMetadata({
                poolAddress: address(0),
                weights: weights
            })
        );

        // Act / Assert
        vm.expectRevert(abi.encodeWithSelector(CreUpdateRule.InvalidAddress.selector, address(0)));
        rule.ProcessReport(metaData);
    }

    function test_ProcessReport_revertsOnWeightsLengthMismatch(uint256 firstWeight, uint40 lastInterpolationTimePossible) public {
        int256[] memory initialWeights = new int256[](4);
        initialWeights[0] = 0.0000000005e18;
        initialWeights[1] = 0.0000000005e18;
        initialWeights[2] = 0;
        initialWeights[3] = 0;

        // Set initial weights
        mockPool.setInitialWeights(initialWeights);
        mockPool.setPoolRegistry(32);
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 32);
        vm.stopPrank();

        int216 fixedValue = 1000;
        chainlinkOracle = deployOracle(fixedValue, 0);

        vm.startPrank(owner);
        updateWeightRunner.addOracle(OracleWrapper(chainlinkOracle));
        vm.stopPrank();

        vm.startPrank(address(mockPool));

        address[][] memory oracles = new address[][](2);
        oracles[0] = new address[](1);
        oracles[0][0] = address(chainlinkOracle);
        oracles[1] = new address[](1);
        oracles[1][0] = address(chainlinkOracle);

        uint64[] memory lambda = new uint64[](1);
        uint40 updateInterval = uint40(bound(lastInterpolationTimePossible, 1, 15552000));
        updateWeightRunner.setRuleForPool(
            IQuantAMMWeightedPool.PoolSettings({
                assets: new IERC20[](0),
                rule: IUpdateRule(rule),
                oracles: oracles,
                updateInterval: updateInterval,
                lambda: lambda,
                epsilonMax: 0.9e18,
                absoluteWeightGuardRail: 0.2e18,
                maxTradeSizeRatio: 0.2e18,
                ruleParameters: new int256[][](0),
                poolManager: addr2
            })
        );
        vm.stopPrank();

        vm.startPrank(owner);
        uint256[] memory weights = new uint256[](1);
        weights[0] = bound(uint256(firstWeight), 0.2e18, 0.8e18);
        bytes memory metaData = abi.encode(
            CreUpdateRule.WorkflowMetadata({
                poolAddress: address(mockPool),
                weights: weights
            })
        );

        uint256[] memory currentPoolWeights = mockPool.getNormalizedWeights();
        assertEq(currentPoolWeights[0], uint256(initialWeights[0]));
        assertEq(currentPoolWeights[1], uint256(initialWeights[1]));

        vm.expectRevert(bytes("WRONGLENGTH"));
        rule.ProcessReport(metaData);

    }

    function test_ProcessReport_revertsWhenPoolNotConfiguredInRunner() public {
        // Arrange: create a brand-new pool that the runner doesn't know about
        // Adjust constructor args if your mock differs, but from the traces:
        // new MockQuantAMMBasePool(3600, 1 ether, address(rule));
        MockQuantAMMBasePool unconfiguredPool = new MockQuantAMMBasePool(UPDATE_INTERVAL, address(updateWeightRunner));

        // Give it some initial normalized weights so getNormalizedWeights() doesn't revert
        int256[] memory initialWeights = new int256[](2);
        initialWeights[0] = 0.5e18;
        initialWeights[1] = 0.5e18;
        unconfiguredPool.setInitialWeights(initialWeights);

        uint256[] memory weights = new uint256[](2);
        weights[0] = 0.5e18;
        weights[1] = 0.5e18;

        bytes memory metaData = abi.encode(
            CreUpdateRule.WorkflowMetadata({
                poolAddress: address(unconfiguredPool),
                weights: weights
            })
        );

        // Act / Assert
        // We don't care about the exact revert reason here (it could be from
        // getPoolRuleSettings or from calculateMultiplierAndSetWeightsFromRule),
        // we just assert that a non-configured pool can't be updated "successfully".
        vm.expectRevert();
        rule.ProcessReport(metaData);
    }

    function test_ProcessReport_revertsWhenRunnerConfiguredForDifferentRule(uint256 firstWeight, uint40 lastInterpolationTimePossible) public {
        int256[] memory initialWeights = new int256[](4);
        initialWeights[0] = 0.0000000005e18;
        initialWeights[1] = 0.0000000005e18;
        initialWeights[2] = 0;
        initialWeights[3] = 0;

        // Set initial weights
        mockPool.setInitialWeights(initialWeights);
        mockPool.setPoolRegistry(32);
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 32);
        vm.stopPrank();

        int216 fixedValue = 1000;
        chainlinkOracle = deployOracle(fixedValue, 0);

        vm.startPrank(owner);
        updateWeightRunner.addOracle(OracleWrapper(chainlinkOracle));
        vm.stopPrank();

        vm.startPrank(address(mockPool));

        address[][] memory oracles = new address[][](2);
        oracles[0] = new address[](1);
        oracles[0][0] = address(chainlinkOracle);
        oracles[1] = new address[](1);
        oracles[1][0] = address(chainlinkOracle);

        uint64[] memory lambda = new uint64[](1);
        uint40 updateInterval = uint40(bound(lastInterpolationTimePossible, 1, 15552000));
        MockCreUpdateRule differentRule = new MockCreUpdateRule(address(updateWeightRunner));
        updateWeightRunner.setRuleForPool(
            IQuantAMMWeightedPool.PoolSettings({
                assets: new IERC20[](0),
                rule: IUpdateRule(differentRule),
                oracles: oracles,
                updateInterval: updateInterval,
                lambda: lambda,
                epsilonMax: 0.9e18,
                absoluteWeightGuardRail: 0.2e18,
                maxTradeSizeRatio: 0.2e18,
                ruleParameters: new int256[][](0),
                poolManager: addr2
            })
        );
        vm.stopPrank();

        vm.startPrank(owner);
        uint256[] memory weights = new uint256[](2);
        weights[0] = bound(uint256(firstWeight), 0.2e18, 0.8e18);
        weights[1] = uint256(1e18) - weights[0];
        bytes memory metaData = abi.encode(
            CreUpdateRule.WorkflowMetadata({
                poolAddress: address(mockPool),
                weights: weights
            })
        );

        uint256[] memory currentPoolWeights = mockPool.getNormalizedWeights();
        assertEq(currentPoolWeights[0], uint256(initialWeights[0]));
        assertEq(currentPoolWeights[1], uint256(initialWeights[1]));


        // Act / Assert
        // Now, when `rule` tries to call calculateMultiplierAndSetWeightsFromRule,
        // UpdateWeightRunner should reject it because msg.sender != rules[pool].
        vm.expectRevert(abi.encodeWithSelector(CreUpdateRule.InvalidAddress.selector, address(mockPool)));
        vm.startPrank(owner);
        rule.ProcessReport(metaData);
        vm.stopPrank();
    }


    function test_ProcessReportUnauthorised(uint256 firstWeight, uint40 lastInterpolationTimePossible, uint256 permission) public {
        int256[] memory initialWeights = new int256[](4);
        initialWeights[0] = 0.0000000005e18;
        initialWeights[1] = 0.0000000005e18;
        initialWeights[2] = 0;
        initialWeights[3] = 0;

        vm.assume(permission & 32 == 0 && permission != 0);  // Ensure the permission bit for this function is not set

        // Set initial weights
        mockPool.setInitialWeights(initialWeights);
        mockPool.setPoolRegistry(permission);
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), permission);
        vm.stopPrank();

        int216 fixedValue = 1000;
        chainlinkOracle = deployOracle(fixedValue, 0);

        vm.startPrank(owner);
        updateWeightRunner.addOracle(OracleWrapper(chainlinkOracle));
        vm.stopPrank();

        vm.startPrank(address(mockPool));

        address[][] memory oracles = new address[][](2);
        oracles[0] = new address[](1);
        oracles[0][0] = address(chainlinkOracle);
        oracles[1] = new address[](1);
        oracles[1][0] = address(chainlinkOracle);

        uint64[] memory lambda = new uint64[](1);
        uint40 updateInterval = uint40(bound(lastInterpolationTimePossible, 1, 15552000));
        updateWeightRunner.setRuleForPool(
            IQuantAMMWeightedPool.PoolSettings({
                assets: new IERC20[](0),
                rule: IUpdateRule(rule),
                oracles: oracles,
                updateInterval: updateInterval,
                lambda: lambda,
                epsilonMax: 0.9e18,
                absoluteWeightGuardRail: 0.2e18,
                maxTradeSizeRatio: 0.2e18,
                ruleParameters: new int256[][](0),
                poolManager: addr2
            })
        );
        vm.stopPrank();

        vm.startPrank(owner);
        uint256[] memory weights = new uint256[](2);
        weights[0] = bound(uint256(firstWeight), 0.2e18, 0.8e18);
        weights[1] = uint256(1e18) - weights[0];
        bytes memory metaData = abi.encode(
            CreUpdateRule.WorkflowMetadata({
                poolAddress: address(mockPool),
                weights: weights
            })
        );

        uint256[] memory currentPoolWeights = mockPool.getNormalizedWeights();
        assertEq(currentPoolWeights[0], uint256(initialWeights[0]));
        assertEq(currentPoolWeights[1], uint256(initialWeights[1]));

        // Expect revert due to function not approved for pool.
        vm.expectRevert(bytes("FUNCTIONNOTAPPROVEDFORPOOL"));
        rule.ProcessReport(metaData);

        vm.stopPrank();
    }

    function deployOracle(int216 fixedValue, uint delay) internal returns (MockChainlinkOracle) {
        MockChainlinkOracle oracle = new MockChainlinkOracle(fixedValue, delay);
        return oracle;
    }
}
