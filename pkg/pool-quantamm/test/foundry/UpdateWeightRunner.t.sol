// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../contracts/mock/MockUpdateWeightRunner.sol"; // Update with your actual path
import "../../contracts/mock/MockChainlinkOracles.sol"; // Update with your actual path
import "../../contracts/mock/MockIdentityRules.sol"; // Update with your actual path
import "../../contracts/mock/MockQuantAMMBasePool.sol"; // Update with your actual path
import "../../contracts/IQuantAMMWeightedPool.sol"; // Update with your actual path
import "./utils.t.sol";

contract UpdateWeightRunnerTest is Test, QuantAMMTestUtils {
    MockUpdateWeightRunner internal updateWeightRunner;
    MockChainlinkOracle internal chainlinkOracle;
    address internal owner;
    address internal addr1;
    address internal addr2;

    MockChainlinkOracle chainlinkOracle1;
    MockChainlinkOracle chainlinkOracle2;
    MockChainlinkOracle chainlinkOracle3;

    MockIdentityRule mockRule;
    MockQuantAMMBasePool mockPool;

    uint256 constant FIXED_VALUE_1 = 1000;
    uint256 constant FIXED_VALUE_2 = 1001;
    uint256 constant FIXED_VALUE_3 = 1002;
    uint256 constant DELAY = 3600;
    uint16 constant UPDATE_INTERVAL = 1800;
    // Deploy UpdateWeightRunner contract before each test
    function setUp() public {
        (address ownerLocal, address addr1Local, address addr2Local) = (vm.addr(1), vm.addr(2), vm.addr(3));
        owner = ownerLocal;
        addr1 = addr1Local;
        addr2 = addr2Local;
        // Deploy UpdateWeightRunner contract
        vm.startPrank(owner);
        updateWeightRunner = new MockUpdateWeightRunner(owner, addr2);
        
        vm.stopPrank();
        // Deploy Mock Rule and Pool

        mockRule = new MockIdentityRule();
        mockPool = new MockQuantAMMBasePool(UPDATE_INTERVAL, address(updateWeightRunner));
    }

    function deployOracle(int216 fixedValue, uint delay) internal returns (MockChainlinkOracle) {
        MockChainlinkOracle oracle = new MockChainlinkOracle(fixedValue, delay);
        return oracle;
    }

    // Test for adding oracles
    function testUpdateWeightRunnerOwnerCanAddOracle() public {
        int216 fixedValue = 1000;
        uint delay = 3600;

        chainlinkOracle = deployOracle(fixedValue, delay);
        vm.startPrank(owner);
        updateWeightRunner.addOracle(OracleWrapper(chainlinkOracle));
        vm.stopPrank();
        assertEq(updateWeightRunner.approvedOracles(address(chainlinkOracle)), true);
    }

    function testUpdateWeightRunnerNonOwnerCannotAddOracle() public {
        int216 fixedValue = 1000;
        uint delay = 3600;

        chainlinkOracle = deployOracle(fixedValue, delay);
        vm.startPrank(owner);
        updateWeightRunner.addOracle(OracleWrapper(chainlinkOracle));
        vm.stopPrank();
        vm.startPrank(addr1);
        vm.expectRevert("ONLYADMIN");
        updateWeightRunner.addOracle(OracleWrapper(chainlinkOracle));
    }

    function testUpdateWeightRunnerOracleCannotBeAddedTwice() public {
        int216 fixedValue = 1000;
        uint delay = 3600;

        chainlinkOracle = deployOracle(fixedValue, delay);
        vm.startPrank(owner);
        updateWeightRunner.addOracle(OracleWrapper(chainlinkOracle));
        vm.expectRevert("Oracle already added");
        updateWeightRunner.addOracle(OracleWrapper(chainlinkOracle));
        vm.stopPrank();
    }

    function testUpdateWeightRunnerOwnerCanRemoveOracle() public {
        int216 fixedValue = 1000;
        uint delay = 3600;

        chainlinkOracle = deployOracle(fixedValue, delay);
        vm.startPrank(owner);
        updateWeightRunner.addOracle(OracleWrapper(chainlinkOracle));

        updateWeightRunner.removeOracle(OracleWrapper(chainlinkOracle));

        assertEq(updateWeightRunner.approvedOracles(address(chainlinkOracle)), false);
    }

    function testUpdateWeightRunnerNonOwnerCannotRemoveOracle() public {
        int216 fixedValue = 1000;
        uint delay = 3600;

        chainlinkOracle = deployOracle(fixedValue, delay);
        vm.startPrank(owner);
        updateWeightRunner.addOracle(OracleWrapper(chainlinkOracle));
        vm.stopPrank();
        vm.startPrank(addr1);
        vm.expectRevert("ONLYADMIN");
        updateWeightRunner.removeOracle(OracleWrapper(chainlinkOracle));
        vm.stopPrank();
    }

    function tesUpdateWeightRunnerOwnableCanApprovePoolUses() public {
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 3);
        vm.stopPrank();
        assertEq(updateWeightRunner.getPoolApprovedActions(address(mockPool)), 3);
    }

    function testUpdateWeightRunnerNonOwnabeCannotApprovePoolUses() public {
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 3);
        vm.stopPrank();
        vm.startPrank(addr1);
        vm.expectRevert("ONLYADMIN");
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 1);
        vm.stopPrank();
        assertEq(updateWeightRunner.getPoolApprovedActions(address(mockPool)), 3);
    }

    function testUpdateWeightRunnerCannotRunUpdateForNonExistingPool() public {
        address nonPool = address(0xdead);
        vm.expectRevert("Pool not registered");
        updateWeightRunner.performUpdate(nonPool);
    }

    function testUpdateWeightRunnerCannotRunUpdateBeforeUpdateInterval() public {
        uint40 blockTime = uint40(block.timestamp);
        int216 fixedValue = 1000;
        uint delay = 3600;
        chainlinkOracle = deployOracle(fixedValue, delay);

        vm.startPrank(owner);
        updateWeightRunner.addOracle(OracleWrapper(chainlinkOracle));
        vm.stopPrank();

        vm.startPrank(address(mockPool));
        address[][] memory oracles = new address[][](1);
        oracles[0] = new address[](1);
        oracles[0][0] = address(chainlinkOracle);

        uint64[] memory lambda = new uint64[](1);
        lambda[0] = 0.0000000005e18;
        updateWeightRunner.setRuleForPool(
            IQuantAMMWeightedPool.PoolSettings({
                assets: new IERC20[](0),
                rule: mockRule,
                oracles: oracles,
                updateInterval: 1,
                lambda: lambda,
                epsilonMax: 0.2e18,
                absoluteWeightGuardRail: 0.2e18,
                maxTradeSizeRatio: 0.2e18,
                ruleParameters: new int256[][](0),
                poolManager: addr2
            })
        );
        vm.stopPrank();

        vm.startPrank(addr2);
        updateWeightRunner.InitialisePoolLastRunTime(address(mockPool), blockTime);
        vm.stopPrank();

        vm.expectRevert("Update not allowed");
        updateWeightRunner.performUpdate(address(mockPool));
    }

    function testUpdateWeightRunnerUpdatesSuccessfullyAfterUpdateInterval() public {
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 3);
        vm.stopPrank();
        int256[] memory initialWeights = new int256[](4);
        initialWeights[0] = 0.0000000005e18;
        initialWeights[1] = 0.0000000005e18;
        initialWeights[2] = 0;
        initialWeights[3] = 0;

        // Set initial weights
        mockPool.setInitialWeights(initialWeights);

        int216 fixedValue = 1000;
        chainlinkOracle = deployOracle(fixedValue, 3601);

        vm.startPrank(owner);
        updateWeightRunner.addOracle(OracleWrapper(chainlinkOracle));
        vm.stopPrank();

        vm.startPrank(address(mockPool));

        address[][] memory oracles = new address[][](1);
        oracles[0] = new address[](1);
        oracles[0][0] = address(chainlinkOracle);

        uint64[] memory lambda = new uint64[](1);
        lambda[0] = 0.0000000005e18;
        updateWeightRunner.setRuleForPool(
            IQuantAMMWeightedPool.PoolSettings({
                assets: new IERC20[](0),
                rule: IUpdateRule(mockRule),
                oracles: oracles,
                updateInterval: 1,
                lambda: lambda,
                epsilonMax: 0.2e18,
                absoluteWeightGuardRail: 0.2e18,
                maxTradeSizeRatio: 0.2e18,
                ruleParameters: new int256[][](0),
                poolManager: addr2
            })
        );
        vm.stopPrank();

        vm.startPrank(addr2);
        updateWeightRunner.InitialisePoolLastRunTime(address(mockPool), 1);
        vm.stopPrank();

        vm.warp(block.timestamp + 10000000);
        mockRule.CalculateNewWeights(
            initialWeights,
            new int256[](0),
            address(mockPool),
            new int256[][](0),
            new uint64[](0),
            0.2e18,
            0.2e18
        );
        updateWeightRunner.performUpdate(address(mockPool));

        uint40 timeNow = uint40(block.timestamp);

        assertEq(updateWeightRunner.getPoolRuleSettings(address(mockPool)).timingSettings.lastPoolUpdateRun, timeNow);

        assertTrue(mockRule.CalculateNewWeightsCalled());
    }

    function testUpdateWeightRunnerMultipleConsecutiveUpdatesSuccessful() public {
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 3);
        vm.stopPrank();
        vm.warp(block.timestamp + UPDATE_INTERVAL);
        int256[] memory initialWeights = new int256[](4);
        initialWeights[0] = 0.0000000005e18;
        initialWeights[1] = 0.0000000005e18;
        initialWeights[2] = 0;
        initialWeights[3] = 0;
        // Set initial weights
        mockPool.setInitialWeights(initialWeights);

        int216 fixedValue1 = 1000;
        int216 fixedValue2 = 1001;
        int216 fixedValue3 = 1002;

        int216 fixedValue = 1000;

        chainlinkOracle = deployOracle(fixedValue, 0);

        vm.startPrank(owner);
        // Deploy oracles with fixed values and delay
        chainlinkOracle1 = deployOracle(fixedValue1, 0);
        chainlinkOracle2 = deployOracle(fixedValue2, 0);
        chainlinkOracle3 = deployOracle(fixedValue3, 0);

        updateWeightRunner.addOracle(chainlinkOracle1);
        updateWeightRunner.addOracle(chainlinkOracle2);
        updateWeightRunner.addOracle(chainlinkOracle3);

        // Deploy MockIdentityRule contract
        mockRule = new MockIdentityRule();

        vm.stopPrank();

        vm.startPrank(address(mockPool));
        address[][] memory oracles = new address[][](3);
        oracles[0] = new address[](1);
        oracles[0][0] = address(chainlinkOracle1);
        oracles[1] = new address[](1);
        oracles[1][0] = address(chainlinkOracle2);
        oracles[2] = new address[](1);
        oracles[2][0] = address(chainlinkOracle3);

        uint64[] memory lambda = new uint64[](1);
        lambda[0] = 0.0000000005e18;
        updateWeightRunner.setRuleForPool(
            IQuantAMMWeightedPool.PoolSettings({
                assets: new IERC20[](0),
                rule: IUpdateRule(mockRule),
                oracles: oracles,
                updateInterval: 1,
                lambda: lambda,
                epsilonMax: 0.2e18,
                absoluteWeightGuardRail: 0.2e18,
                maxTradeSizeRatio: 0.2e18,
                ruleParameters: new int256[][](0),
                poolManager: addr2
            })
        );
        vm.stopPrank();

        // First update
        vm.warp(block.timestamp + UPDATE_INTERVAL);
        updateWeightRunner.performUpdate(address(mockPool));

        uint40 timeNow = uint40(block.timestamp);

        assertEq(updateWeightRunner.getPoolRuleSettings(address(mockPool)).timingSettings.lastPoolUpdateRun, timeNow);
        assertTrue(mockRule.CalculateNewWeightsCalled());

        // Reset the mock
        mockRule.SetCalculateNewWeightsCalled(false);
        assertFalse(mockRule.CalculateNewWeightsCalled());

        // Second update
        vm.warp(block.timestamp + UPDATE_INTERVAL);
        updateWeightRunner.performUpdate(address(mockPool));

        timeNow = uint40(block.timestamp);

        assertEq(updateWeightRunner.getPoolRuleSettings(address(mockPool)).timingSettings.lastPoolUpdateRun, timeNow);
        assertTrue(mockRule.CalculateNewWeightsCalled());
    }


    function testUpdateWeightRunnerCalculateBlockMultiplierCorrectly() public {
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 3);
        vm.stopPrank();
        int256[] memory initialWeights = new int256[](4);
        initialWeights[0] = 0.5e18;
        initialWeights[1] = 0.5e18;
        initialWeights[2] = 0;
        initialWeights[3] = 0;

        // Set initial weights
        mockPool.setInitialWeights(initialWeights);
        
        int256[] memory newCalculatedWeights = new int256[](2);
        newCalculatedWeights[0] = 0.7e18;
        newCalculatedWeights[1] = 0.3e18;

        mockRule.setWeights(newCalculatedWeights);

        int216 fixedValue1 = 1000;
        int216 fixedValue2 = 1001;

        int216 fixedValue = 1000;

        chainlinkOracle = deployOracle(fixedValue, 0);

        vm.startPrank(owner);
        // Deploy oracles with fixed values and delay
        chainlinkOracle1 = deployOracle(fixedValue1, 0);
        chainlinkOracle2 = deployOracle(fixedValue2, 0);

        updateWeightRunner.addOracle(chainlinkOracle1);
        updateWeightRunner.addOracle(chainlinkOracle2);
        vm.stopPrank();

        vm.startPrank(address(mockPool));

        address[][] memory oracles = new address[][](2);
        oracles[0] = new address[](1);
        oracles[0][0] = address(chainlinkOracle1);
        oracles[1] = new address[](1);
        oracles[1][0] = address(chainlinkOracle2);

        uint64[] memory lambda = new uint64[](1);
        lambda[0] = 0.0000000005e18;
        updateWeightRunner.setRuleForPool(
            IQuantAMMWeightedPool.PoolSettings({
                assets: new IERC20[](0),
                rule: IUpdateRule(mockRule),
                oracles: oracles,
                updateInterval: 10,
                lambda: lambda,
                epsilonMax: 0.2e18,
                absoluteWeightGuardRail: 0.2e18,
                maxTradeSizeRatio: 0.2e18,
                ruleParameters: new int256[][](0),
                poolManager: addr2
            })
        );
        vm.stopPrank();

        vm.startPrank(addr2);
        updateWeightRunner.InitialisePoolLastRunTime(address(mockPool), 1);
        vm.stopPrank();

        vm.warp(block.timestamp + 10);

        updateWeightRunner.performUpdate(address(mockPool));
        int256[] memory expectedWeights = new int256[](4);
        expectedWeights[0] = 0.5e18;
        expectedWeights[1] = 0.5e18;
        expectedWeights[2] = 0.02e18;
        expectedWeights[3] = -0.02e18;

        uint40 timeNow = uint40(block.timestamp);
        int256[] memory calcWeights = mockPool.getWeights();
        assertEq(updateWeightRunner.getPoolRuleSettings(address(mockPool)).timingSettings.lastPoolUpdateRun, timeNow);
        assertTrue(mockRule.CalculateNewWeightsCalled());
        checkResult(calcWeights, expectedWeights);

        //new calculated weight 0.7
        //abs weight guard rail 0.2
        //diff = 0.1
        //block multiplier = 0.02
        //blocks after update interval before first guard rail hit: 5
        // timestamp = 11
        // update interval = 10
        //block timestamp when guard rail hit 26

        assertEq(mockPool.lastInterpolationTimePossible(), uint40(26));
    }


    function testUpdateWeightRunnerCalculateBlockMultiplierBeyondLimit() public {
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 3);
        vm.stopPrank();
        int256[] memory initialWeights = new int256[](4);
        initialWeights[0] = 0.5e18;
        initialWeights[1] = 0.5e18;
        initialWeights[2] = 0;
        initialWeights[3] = 0;

        // Set initial weights
        mockPool.setInitialWeights(initialWeights);
        
        int256[] memory newCalculatedWeights = new int256[](2);
        newCalculatedWeights[0] = 0.9e18;
        newCalculatedWeights[1] = 0.1e18;

        mockRule.setWeights(newCalculatedWeights);

        int216 fixedValue1 = 1000;
        int216 fixedValue2 = 1001;

        int216 fixedValue = 1000;

        chainlinkOracle = deployOracle(fixedValue, 0);

        vm.startPrank(owner);
        // Deploy oracles with fixed values and delay
        chainlinkOracle1 = deployOracle(fixedValue1, 0);
        chainlinkOracle2 = deployOracle(fixedValue2, 0);

        updateWeightRunner.addOracle(chainlinkOracle1);
        updateWeightRunner.addOracle(chainlinkOracle2);
        vm.stopPrank();

        vm.startPrank(address(mockPool));

        address[][] memory oracles = new address[][](2);
        oracles[0] = new address[](1);
        oracles[0][0] = address(chainlinkOracle1);
        oracles[1] = new address[](1);
        oracles[1][0] = address(chainlinkOracle2);

        uint64[] memory lambda = new uint64[](1);
        lambda[0] = 0.0000000005e18;
        updateWeightRunner.setRuleForPool(
            IQuantAMMWeightedPool.PoolSettings({
                assets: new IERC20[](0),
                rule: IUpdateRule(mockRule),
                oracles: oracles,
                updateInterval: 20,
                lambda: lambda,
                epsilonMax: 0.2e18,
                absoluteWeightGuardRail: 0.2e18,
                maxTradeSizeRatio: 0.2e18,
                ruleParameters: new int256[][](0),
                poolManager: addr2
            })
        );
        vm.stopPrank();

        vm.startPrank(addr2);
        updateWeightRunner.InitialisePoolLastRunTime(address(mockPool), 1);
        vm.stopPrank();

        vm.warp(block.timestamp + 20);

        updateWeightRunner.performUpdate(address(mockPool));
        int256[] memory expectedWeights = new int256[](4);
        expectedWeights[0] = 0.5e18;
        expectedWeights[1] = 0.5e18;
        expectedWeights[2] = 0.02e18;
        expectedWeights[3] = -0.02e18;

        uint40 timeNow = uint40(block.timestamp);
        int256[] memory calcWeights = mockPool.getWeights();
        assertEq(updateWeightRunner.getPoolRuleSettings(address(mockPool)).timingSettings.lastPoolUpdateRun, timeNow);
        assertTrue(mockRule.CalculateNewWeightsCalled());
        checkResult(calcWeights, expectedWeights);

        //new calculated weight 0.9
        //abs weight guard rail 0.2
        //diff = -0.1
        //block multiplier = 0.02
        //blocks after update interval before first guard rail hit: 5
        // timestamp = 11
        // update interval = 20
        //block timestamp when guard rail hit 36

        assertEq(mockPool.lastInterpolationTimePossible(), uint40(36));
    }


    function testUpdateWeightRunnerCalculateBlockMultiplierLastInterpolationTimeBeforeUpdateInterval() public {
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 3);
        vm.stopPrank();
        int256[] memory initialWeights = new int256[](4);
        initialWeights[0] = 0.6e18;
        initialWeights[1] = 0.4e18;
        initialWeights[2] = 0;
        initialWeights[3] = 0;

        // Set initial weights
        mockPool.setInitialWeights(initialWeights);
        
        int256[] memory newCalculatedWeights = new int256[](2);
        newCalculatedWeights[0] = 0.9e18;
        newCalculatedWeights[1] = 0.1e18;

        mockRule.setWeights(newCalculatedWeights);

        int216 fixedValue1 = 1000;
        int216 fixedValue2 = 1001;

        int216 fixedValue = 1000;

        chainlinkOracle = deployOracle(fixedValue, 0);

        vm.startPrank(owner);
        // Deploy oracles with fixed values and delay
        chainlinkOracle1 = deployOracle(fixedValue1, 0);
        chainlinkOracle2 = deployOracle(fixedValue2, 0);

        updateWeightRunner.addOracle(chainlinkOracle1);
        updateWeightRunner.addOracle(chainlinkOracle2);
        vm.stopPrank();

        vm.startPrank(address(mockPool));

        address[][] memory oracles = new address[][](2);
        oracles[0] = new address[](1);
        oracles[0][0] = address(chainlinkOracle1);
        oracles[1] = new address[](1);
        oracles[1][0] = address(chainlinkOracle2);

        uint64[] memory lambda = new uint64[](1);
        lambda[0] = 0.0000000005e18;
        updateWeightRunner.setRuleForPool(
            IQuantAMMWeightedPool.PoolSettings({
                assets: new IERC20[](0),
                rule: IUpdateRule(mockRule),
                oracles: oracles,
                updateInterval: 10,
                lambda: lambda,
                epsilonMax: 0.2e18,
                absoluteWeightGuardRail: 0.35e18,
                maxTradeSizeRatio: 0.2e18,
                ruleParameters: new int256[][](0),
                poolManager: addr2
            })
        );
        vm.stopPrank();

        vm.startPrank(addr2);
        updateWeightRunner.InitialisePoolLastRunTime(address(mockPool), 1);
        vm.stopPrank();

        vm.warp(block.timestamp + 10);

        updateWeightRunner.performUpdate(address(mockPool));
        int256[] memory expectedWeights = new int256[](4);
        expectedWeights[0] = 0.6e18;
        expectedWeights[1] = 0.4e18;
        expectedWeights[2] = 0.03e18;
        expectedWeights[3] = -0.03e18;

        uint40 timeNow = uint40(block.timestamp);
        int256[] memory calcWeights = mockPool.getWeights();
        assertEq(updateWeightRunner.getPoolRuleSettings(address(mockPool)).timingSettings.lastPoolUpdateRun, timeNow);
        assertTrue(mockRule.CalculateNewWeightsCalled());
        checkResult(calcWeights, expectedWeights);

        //new calculated weight 0.9
        //abs weight guard rail 0.35
        //diff = -0.25
        //current weight = 0.65
        //block multiplier = 0.03
        //blocks after update interval before first guard rail hit: 5
        // timestamp = 11
        // update interval = 10
        //block timestamp when guard rail hit 12

        assertEq(mockPool.lastInterpolationTimePossible(), uint40(12));
    }

    function testUpdateWeightRunnerMultipleConsecutiveUpdatesFailsIfNotApproved() public {
        vm.warp(block.timestamp + UPDATE_INTERVAL);
        int256[] memory initialWeights = new int256[](4);
        initialWeights[0] = 0.0000000005e18;
        initialWeights[1] = 0.0000000005e18;
        initialWeights[2] = 0;
        initialWeights[3] = 0;
        // Set initial weights
        mockPool.setInitialWeights(initialWeights);

        int216 fixedValue1 = 1000;
        int216 fixedValue2 = 1001;
        int216 fixedValue3 = 1002;

        int216 fixedValue = 1000;

        chainlinkOracle = deployOracle(fixedValue, 0);

        vm.startPrank(owner);
        // Deploy oracles with fixed values and delay
        chainlinkOracle1 = deployOracle(fixedValue1, 0);
        chainlinkOracle2 = deployOracle(fixedValue2, 0);
        chainlinkOracle3 = deployOracle(fixedValue3, 0);

        updateWeightRunner.addOracle(chainlinkOracle1);
        updateWeightRunner.addOracle(chainlinkOracle2);
        updateWeightRunner.addOracle(chainlinkOracle3);

        // Deploy MockIdentityRule contract
        mockRule = new MockIdentityRule();

        vm.stopPrank();

        vm.startPrank(address(mockPool));
        address[][] memory oracles = new address[][](3);
        oracles[0] = new address[](1);
        oracles[0][0] = address(chainlinkOracle1);
        oracles[1] = new address[](1);
        oracles[1][0] = address(chainlinkOracle2);
        oracles[2] = new address[](1);
        oracles[2][0] = address(chainlinkOracle3);

        uint64[] memory lambda = new uint64[](1);
        lambda[0] = 0.0000000005e18;
        updateWeightRunner.setRuleForPool(
            IQuantAMMWeightedPool.PoolSettings({
                assets: new IERC20[](0),
                rule: IUpdateRule(mockRule),
                oracles: oracles,
                updateInterval: 1,
                lambda: lambda,
                epsilonMax: 0.2e18,
                absoluteWeightGuardRail: 0.2e18,
                maxTradeSizeRatio: 0.2e18,
                ruleParameters: new int256[][](0),
                poolManager: addr2
            })
        );
        vm.stopPrank();

        // First update
        vm.warp(block.timestamp + UPDATE_INTERVAL);

        vm.expectRevert("Pool not approved to perform update");
        updateWeightRunner.performUpdate(address(mockPool));

    }

    function testUpdateWeightRunnerSetWeightsManuallyAdmin() public {
        int256[] memory weights = new int256[](4);
        weights[0] = 0.0000000005e18;
        weights[1] = 0.0000000005e18;
        weights[2] = 0;
        weights[3] = 0;
        mockPool.setPoolRegistry(16);

        vm.startPrank(owner);
        updateWeightRunner.setWeightsManually(weights, address(mockPool), 6);
        vm.stopPrank();
        uint256[] memory poolWeights = new uint256[](2);
        poolWeights[0] = 0.0000000005e18;
        poolWeights[1] = 0.0000000005e18;
        assertEq(IWeightedPool(address(mockPool)).getNormalizedWeights(), poolWeights);
    }


    function testUpdateWeightRunnerSetWeightsManuallyFailsAdminPermOwnerFails() public {
        int256[] memory weights = new int256[](4);
        weights[0] = 0.0000000005e18;
        weights[1] = 0.0000000005e18;
        weights[2] = 0;
        weights[3] = 0;
        mockPool.setPoolRegistry(16);

        vm.startPrank(addr2);
        vm.expectRevert("ONLYADMIN");
        updateWeightRunner.setWeightsManually(weights, address(mockPool), 6);
        vm.stopPrank();
    }

    function testUpdateWeightRunnerSetWeightsManuallyPoolOwner() public {
        int256[] memory weights = new int256[](4);
        weights[0] = 0.0000000005e18;
        weights[1] = 0.0000000005e18;
        weights[2] = 0;
        weights[3] = 0;
        mockPool.setPoolRegistry(8);
        
        uint40 blockTime = uint40(block.timestamp);
        int216 fixedValue = 1000;
        uint delay = 3600;
        chainlinkOracle = deployOracle(fixedValue, delay);

        vm.startPrank(owner);
        updateWeightRunner.addOracle(OracleWrapper(chainlinkOracle));
        vm.stopPrank();

        vm.startPrank(address(mockPool));
        address[][] memory oracles = new address[][](1);
        oracles[0] = new address[](1);
        oracles[0][0] = address(chainlinkOracle);

        uint64[] memory lambda = new uint64[](1);
        lambda[0] = 0.0000000005e18;
        updateWeightRunner.setRuleForPool(
            IQuantAMMWeightedPool.PoolSettings({
                assets: new IERC20[](0),
                rule: mockRule,
                oracles: oracles,
                updateInterval: 1,
                lambda: lambda,
                epsilonMax: 0.2e18,
                absoluteWeightGuardRail: 0.2e18,
                maxTradeSizeRatio: 0.2e18,
                ruleParameters: new int256[][](0),
                poolManager: addr2
            })
        );
        vm.stopPrank();

        vm.startPrank(addr2);
        updateWeightRunner.InitialisePoolLastRunTime(address(mockPool), blockTime);
        vm.stopPrank();
        
        vm.startPrank(addr2);
        updateWeightRunner.setWeightsManually(weights, address(mockPool), 6);
        vm.stopPrank();
        uint256[] memory poolWeights = new uint256[](2);
        poolWeights[0] = 0.0000000005e18;
        poolWeights[1] = 0.0000000005e18;
        assertEq(IWeightedPool(address(mockPool)).getNormalizedWeights(), poolWeights);
    }


    function testUpdateWeightRunnerSetWeightsManuallyFailsOwnerPermAdminFails() public {
        int256[] memory weights = new int256[](4);
        weights[0] = 0.0000000005e18;
        weights[1] = 0.0000000005e18;
        weights[2] = 0;
        weights[3] = 0;
        mockPool.setPoolRegistry(8);

        vm.startPrank(owner);
        vm.expectRevert("ONLYMANAGER");
        updateWeightRunner.setWeightsManually(weights, address(mockPool), 6);
        vm.stopPrank();
    }

    function testUpdateWeightRunnerSetWeightsManuallyInitiallyNonOwnerFails() public {
        int256[] memory weights = new int256[](4);
        weights[0] = 0.0000000005e18;
        weights[1] = 0.0000000005e18;
        weights[2] = 0;
        weights[3] = 0;

        vm.startPrank(addr1);
        vm.expectRevert("No permission to set weight values");
        updateWeightRunner.setWeightsManually(weights, address(mockPool), 6);
    }

    function testUpdateWeightRunnerSetWeightsManuallyOwnerPermedNonOwnerFails() public {
        int256[] memory weights = new int256[](4);
        weights[0] = 0.0000000005e18;
        weights[1] = 0.0000000005e18;
        weights[2] = 0;
        weights[3] = 0;
        mockPool.setPoolRegistry(8);

        vm.startPrank(addr1);
        vm.expectRevert("ONLYMANAGER");
        updateWeightRunner.setWeightsManually(weights, address(mockPool), 6);
    }

    function testUpdateWeightRunnerSetWeightsManuallyAdminPermedNonOwnerFails() public {
        int256[] memory weights = new int256[](4);
        weights[0] = 0.0000000005e18;
        weights[1] = 0.0000000005e18;
        weights[2] = 0;
        weights[3] = 0;
        mockPool.setPoolRegistry(16);

        vm.startPrank(addr1);
        vm.expectRevert("ONLYADMIN");
        updateWeightRunner.setWeightsManually(weights, address(mockPool), 6);
    }

    function testUpdateWeightRunnerSetIntermediateValuesManually() public {
        int256[] memory newMovingAverages = new int256[](4);
        newMovingAverages[0] = 0.0000000005e18;
        newMovingAverages[1] = 0.0000000005e18;
        newMovingAverages[2] = 0;
        newMovingAverages[3] = 0;

        int256[] memory newParameters = new int256[](4);
        newParameters[0] = 0.0000000005e18;
        newParameters[1] = 0.0000000005e18;
        newParameters[2] = 0;
        newParameters[3] = 0;

        mockPool.setPoolRegistry(16);

        int216 fixedValue = 1000;
        uint delay = 3600;
        chainlinkOracle = deployOracle(fixedValue, delay);

        vm.startPrank(owner);
        updateWeightRunner.addOracle(OracleWrapper(chainlinkOracle));
        vm.stopPrank();

        vm.startPrank(address(mockPool));
        address[][] memory oracles = new address[][](1);
        oracles[0] = new address[](1);
        oracles[0][0] = address(chainlinkOracle);

        uint64[] memory lambda = new uint64[](1);
        lambda[0] = 0.0000000005e18;
        updateWeightRunner.setRuleForPool(
            IQuantAMMWeightedPool.PoolSettings({
                assets: new IERC20[](0),
                rule: mockRule,
                oracles: oracles,
                updateInterval: 1,
                lambda: lambda,
                epsilonMax: 0.2e18,
                absoluteWeightGuardRail: 0.2e18,
                maxTradeSizeRatio: 0.2e18,
                ruleParameters: new int256[][](0),
                poolManager: addr2
            })
        );
        vm.stopPrank();

        vm.startPrank(owner);
        updateWeightRunner.setIntermediateValuesManually(address(mockPool), newMovingAverages, newParameters, 4);
        vm.stopPrank();
        assertEq(mockRule.getMovingAverages(), newMovingAverages);
        assertEq(mockRule.getIntermediateValues(), newParameters);
    }

    function testUpdateWeightRunnerSetIntermediateValuesManuallyInitiallyNonOwnerFails() public {
        int256[] memory newMovingAverages = new int256[](4);
        newMovingAverages[0] = 0.0000000005e18;
        newMovingAverages[1] = 0.0000000005e18;
        newMovingAverages[2] = 0;
        newMovingAverages[3] = 0;

        int256[] memory newParameters = new int256[](4);
        newParameters[0] = 0.0000000005e18;
        newParameters[1] = 0.0000000005e18;
        newParameters[2] = 0;
        newParameters[3] = 0;

        vm.startPrank(addr1);
        vm.expectRevert("No permission to set intermediate values");
        updateWeightRunner.setIntermediateValuesManually(address(mockPool), newMovingAverages, newParameters, 4);
    }
}
