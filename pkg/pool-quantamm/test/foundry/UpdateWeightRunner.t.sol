// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../contracts/mock/MockUpdateWeightRunner.sol"; // Update with your actual path
import "../../contracts/mock/MockChainlinkOracles.sol"; // Update with your actual path
import "../../contracts/mock/MockIdentityRules.sol"; // Update with your actual path
import "../../contracts/mock/MockQuantAMMBasePool.sol"; // Update with your actual path
import "./utils.t.sol";
import "@balancer-labs/v3-interfaces/contracts/pool-quantamm/IQuantAMMWeightedPool.sol"; // Update with your actual path

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
    uint40 constant UPDATE_INTERVAL = 1800;
    // Deploy UpdateWeightRunner contract before each test
    function setUp() public {
        (address ownerLocal, address addr1Local, address addr2Local) = (vm.addr(1), vm.addr(2), vm.addr(3));
        owner = ownerLocal;
        addr1 = addr1Local;
        addr2 = addr2Local;
        // Deploy UpdateWeightRunner contract
        vm.startPrank(owner);
        updateWeightRunner = new MockUpdateWeightRunner(owner, addr2, false);
        
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
    function testOwnerCanAddOracle() public {
        int216 fixedValue = 1000;
        uint delay = 3600;

        chainlinkOracle = deployOracle(fixedValue, delay);
        vm.startPrank(owner);
        updateWeightRunner.addOracle(OracleWrapper(chainlinkOracle));
        vm.stopPrank();
        assertEq(updateWeightRunner.approvedOracles(address(chainlinkOracle)), true);
    }

    function testNonOwnerCannotAddOracle() public {
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
    
    function testOwnerCanAddSwapFee(uint256 fee) public {
        uint256 boundFee = bound(fee, 0, 1e18);
        vm.startPrank(owner);
        updateWeightRunner.setQuantAMMSwapFeeTake(boundFee);
        vm.stopPrank();
        assertEq(updateWeightRunner.getQuantAMMSwapFeeTake(), boundFee);
    }

    function testOwnerCannotAddSwapFeeGreaterThan100(uint256 fee) public {
        uint256 oldFee = updateWeightRunner.getQuantAMMSwapFeeTake();
        uint256 boundFee = bound(fee, 1e18 + 1, type(uint256).max);
        vm.startPrank(owner);
        vm.expectRevert("Swap fee must be less than 100%");
        updateWeightRunner.setQuantAMMSwapFeeTake(boundFee);
        vm.stopPrank();
        assertEq(updateWeightRunner.getQuantAMMSwapFeeTake(), oldFee);
    }

    function testNonOwnerCannotAddSwapFee() public {
        vm.startPrank(addr1);
        vm.expectRevert("ONLYADMIN");
        updateWeightRunner.setQuantAMMSwapFeeTake(50e16);
    }

    function testOwnerCanAddUpliftFee(uint256 fee) public {
        uint256 boundFee = bound(fee, 0, 1e18);
        vm.startPrank(owner);
        updateWeightRunner.setQuantAMMUpliftFeeTake(boundFee);
        vm.stopPrank();
        assertEq(updateWeightRunner.getQuantAMMUpliftFeeTake(), boundFee);
    }

    function testOwnerCanSetEthUsdOracle() public {
        int216 fixedValue = 1000;
        uint delay = 3600;

        chainlinkOracle = deployOracle(fixedValue, delay);
        vm.startPrank(owner);
        updateWeightRunner.setETHUSDOracle(address(OracleWrapper(chainlinkOracle)));
        vm.stopPrank();
        assertEq(address(updateWeightRunner.ethOracle()), address(chainlinkOracle));
    }

    function testNoneOwnerSetEthUsdOracle() public {
        int216 fixedValue = 1000;
        uint delay = 3600;

        chainlinkOracle = deployOracle(fixedValue, delay);
        vm.startPrank(owner);
        updateWeightRunner.setETHUSDOracle(address(OracleWrapper(chainlinkOracle)));
        vm.stopPrank();
        vm.startPrank(addr1);
        vm.expectRevert("ONLYADMIN");
        updateWeightRunner.setETHUSDOracle(address(OracleWrapper(chainlinkOracle)));
    }

    function testAddress0CannotBeSetAsEthUsdOracle() public {
        vm.startPrank(owner);
        vm.expectRevert("INVETHUSDORACLE");
        updateWeightRunner.setETHUSDOracle(address(0));
        vm.stopPrank();
    }

    function testOwnerCannotAddUpliftFeeGreaterThan100(uint256 fee) public {
        uint256 oldFee = updateWeightRunner.getQuantAMMSwapFeeTake();
        uint256 boundFee = bound(fee, 1e18 + 1, type(uint256).max);
        vm.startPrank(owner);
        vm.expectRevert("Uplift fee must be less than 100%");
        updateWeightRunner.setQuantAMMUpliftFeeTake(boundFee);
        vm.stopPrank();
        assertEq(updateWeightRunner.getQuantAMMSwapFeeTake(), oldFee);
    }

    function testNonOwnerCannotAddUpliftFee() public {
        vm.startPrank(addr1);
        vm.expectRevert("ONLYADMIN");
        updateWeightRunner.setQuantAMMUpliftFeeTake(50e16);
    }

    function testOracleCannotBeAddedTwice() public {
        int216 fixedValue = 1000;
        uint delay = 3600;

        chainlinkOracle = deployOracle(fixedValue, delay);
        vm.startPrank(owner);
        updateWeightRunner.addOracle(OracleWrapper(chainlinkOracle));
        vm.expectRevert("Oracle already added");
        updateWeightRunner.addOracle(OracleWrapper(chainlinkOracle));
        vm.stopPrank();
    }

    function testOwnerCanRemoveOracle() public {
        int216 fixedValue = 1000;
        uint delay = 3600;

        chainlinkOracle = deployOracle(fixedValue, delay);
        vm.startPrank(owner);
        updateWeightRunner.addOracle(OracleWrapper(chainlinkOracle));

        updateWeightRunner.removeOracle(OracleWrapper(chainlinkOracle));

        assertEq(updateWeightRunner.approvedOracles(address(chainlinkOracle)), false);
    }

    function testNonOwnerCannotRemoveOracle() public {
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

    function tesUpdateWeightRunnerDupeSettingOfAction() public {
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 3);
        vm.expectRevert("DUPEACTION");
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 3);
        vm.stopPrank();
        assertEq(updateWeightRunner.getPoolApprovedActions(address(mockPool)), 3);
    }


    function testNonOwnabeCannotApprovePoolUses() public {
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 3);
        vm.stopPrank();
        vm.startPrank(addr1);
        vm.expectRevert("ONLYADMIN");
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 1);
        vm.stopPrank();
        assertEq(updateWeightRunner.getPoolApprovedActions(address(mockPool)), 3);
    }

    function testCannotRunUpdateForNonExistingPool() public {
        address nonPool = address(0xdead);
        vm.expectRevert("Pool not registered");
        updateWeightRunner.performUpdate(nonPool);
    }

    function testCannotRunUpdateBeforeUpdateInterval() public {
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

        mockPool.setPoolRegistry(8);
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 8);
        vm.stopPrank();

        vm.startPrank(addr2);
        updateWeightRunner.InitialisePoolLastRunTime(address(mockPool), blockTime);
        vm.stopPrank();

        vm.expectRevert("Update not allowed");
        updateWeightRunner.performUpdate(address(mockPool));
    }

    function testUpdatesSuccessfullyAfterUpdateInterval() public {
        int256[] memory initialWeights = new int256[](4);
        initialWeights[0] = 0.0000000005e18;
        initialWeights[1] = 0.0000000005e18;
        initialWeights[2] = 0;
        initialWeights[3] = 0;

        // Set initial weights
        mockPool.setInitialWeights(initialWeights);
        mockPool.setPoolRegistry(9);
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 9);
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

        int256[] memory expectedData = new int256[](2);
        expectedData[0] = int256(fixedValue);
        expectedData[1] = int256(fixedValue);

        mockRule.setExpectedDataValue(expectedData);

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


    function testCalculateNewWeightsAfterUpdateWeightRunnerChange() public {
        int256[] memory initialWeights = new int256[](4);
        initialWeights[0] = 0.0000000005e18;
        initialWeights[1] = 0.0000000005e18;
        initialWeights[2] = 0;
        initialWeights[3] = 0;

        mockPool.setInitialWeights(initialWeights);
        mockPool.setPoolRegistry(9);

        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 9);
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

        int256[] memory expectedData = new int256[](2);
        expectedData[0] = int256(fixedValue);
        expectedData[1] = int256(fixedValue);

        mockRule.setExpectedDataValue(expectedData);

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

        // Update the UpdateWeightRunner contract
        vm.startPrank(owner);
        MockUpdateWeightRunner newUpdateWeightRunner = new MockUpdateWeightRunner(owner, addr2, false);
        
        mockPool.setUpdateWeightRunnerAddress(address(newUpdateWeightRunner));
        
        newUpdateWeightRunner.setApprovedActionsForPool(address(mockPool), 9);
        newUpdateWeightRunner.addOracle(OracleWrapper(chainlinkOracle));
        newUpdateWeightRunner.setRuleForPoolAdminInitialise(
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
            }), address(mockPool)
        );
        vm.stopPrank();

        vm.startPrank(addr2);
        newUpdateWeightRunner.InitialisePoolLastRunTime(address(mockPool), 1);
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
        newUpdateWeightRunner.performUpdate(address(mockPool));

        timeNow = uint40(block.timestamp);
        assertEq(newUpdateWeightRunner.getPoolRuleSettings(address(mockPool)).timingSettings.lastPoolUpdateRun, timeNow);
        assertTrue(mockRule.CalculateNewWeightsCalled());
    }
    
    function testUpdatesSuccessfullyAfterUpdateIntervalAfterUpdateWeightRunnerChange() public {
        int256[] memory initialWeights = new int256[](4);
        initialWeights[0] = 0.0000000005e18;
        initialWeights[1] = 0.0000000005e18;
        initialWeights[2] = 0;
        initialWeights[3] = 0;

        // Set initial weights
        mockPool.setInitialWeights(initialWeights);
        mockPool.setPoolRegistry(9);
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 9);
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

        int256[] memory expectedData = new int256[](2);
        expectedData[0] = int256(fixedValue);
        expectedData[1] = int256(fixedValue);

        mockRule.setExpectedDataValue(expectedData);

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

        // Reset the mock
        mockRule.SetCalculateNewWeightsCalled(false);
        assertFalse(mockRule.CalculateNewWeightsCalled());

        // Update the UpdateWeightRunner contract
        vm.startPrank(owner);
        MockUpdateWeightRunner newUpdateWeightRunner = new MockUpdateWeightRunner(owner, addr2, false);
        
        mockPool.setUpdateWeightRunnerAddress(address(newUpdateWeightRunner));
        
        newUpdateWeightRunner.setApprovedActionsForPool(address(mockPool), 9);
        newUpdateWeightRunner.addOracle(OracleWrapper(chainlinkOracle));
        newUpdateWeightRunner.setRuleForPoolAdminInitialise(
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
            }), address(mockPool)
        );
        vm.stopPrank();

        vm.startPrank(addr2);
        newUpdateWeightRunner.InitialisePoolLastRunTime(address(mockPool), 1);
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
        newUpdateWeightRunner.performUpdate(address(mockPool));

        timeNow = uint40(block.timestamp);

        assertEq(newUpdateWeightRunner.getPoolRuleSettings(address(mockPool)).timingSettings.lastPoolUpdateRun, timeNow);
        assertTrue(mockRule.CalculateNewWeightsCalled());

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
        newUpdateWeightRunner.performUpdate(address(mockPool));

        timeNow = uint40(block.timestamp);
        assertEq(newUpdateWeightRunner.getPoolRuleSettings(address(mockPool)).timingSettings.lastPoolUpdateRun, timeNow);
        assertTrue(mockRule.CalculateNewWeightsCalled());
    }

    function testSetRuleForPoolAdminInitialise() public {
        int216 fixedValue = 1000;
        uint delay = 3600;
        chainlinkOracle = deployOracle(fixedValue, delay);

        vm.startPrank(owner);
        updateWeightRunner.addOracle(OracleWrapper(chainlinkOracle));
        vm.stopPrank();

        vm.startPrank(owner);
        IQuantAMMWeightedPool.PoolSettings memory poolSettings = IQuantAMMWeightedPool.PoolSettings({
            assets: new IERC20[](0),
            rule: mockRule,
            oracles: new address[][](1),
            updateInterval: 1,
            lambda: new uint64[](1),
            epsilonMax: 0.2e18,
            absoluteWeightGuardRail: 0.2e18,
            maxTradeSizeRatio: 0.2e18,
            ruleParameters: new int256[][](0),
            poolManager: addr2
        });
        poolSettings.oracles[0] = new address[](1);
        poolSettings.oracles[0][0] = address(chainlinkOracle);

        updateWeightRunner.setRuleForPoolAdminInitialise(poolSettings, address(mockPool));
        vm.stopPrank();

        assertEq(address(updateWeightRunner.rules(address(mockPool))), address(mockRule));
        assertEq(updateWeightRunner.getOptimisedPoolOracle(address(mockPool)).length, 1);
        assertEq(updateWeightRunner.getOptimisedPoolOracle(address(mockPool))[0], address(chainlinkOracle));
    }

    function testSetRuleForPoolAdminInitialiseOnlyAdmin() public {
        int216 fixedValue = 1000;
        uint delay = 3600;
        chainlinkOracle = deployOracle(fixedValue, delay);

        vm.startPrank(owner);
        updateWeightRunner.addOracle(OracleWrapper(chainlinkOracle));
        vm.stopPrank();

        vm.startPrank(addr1);
        IQuantAMMWeightedPool.PoolSettings memory poolSettings = IQuantAMMWeightedPool.PoolSettings({
            assets: new IERC20[](0),
            rule: mockRule,
            oracles: new address[][](1),
            updateInterval: 1,
            lambda: new uint64[](1),
            epsilonMax: 0.2e18,
            absoluteWeightGuardRail: 0.2e18,
            maxTradeSizeRatio: 0.2e18,
            ruleParameters: new int256[][](0),
            poolManager: addr2
        });
        poolSettings.oracles[0] = new address[](1);
        poolSettings.oracles[0][0] = address(chainlinkOracle);

        vm.expectRevert("ONLYADMIN");
        updateWeightRunner.setRuleForPoolAdminInitialise(poolSettings, address(mockPool));
        vm.stopPrank();
    }

    function testSetRuleForPoolAdminInitialiseRuleAlreadySet() public {
        int216 fixedValue = 1000;
        uint delay = 3600;
        chainlinkOracle = deployOracle(fixedValue, delay);

        vm.startPrank(owner);
        updateWeightRunner.addOracle(OracleWrapper(chainlinkOracle));
        vm.stopPrank();

        vm.startPrank(owner);
        IQuantAMMWeightedPool.PoolSettings memory poolSettings = IQuantAMMWeightedPool.PoolSettings({
            assets: new IERC20[](0),
            rule: mockRule,
            oracles: new address[][](1),
            updateInterval: 1,
            lambda: new uint64[](1),
            epsilonMax: 0.2e18,
            absoluteWeightGuardRail: 0.2e18,
            maxTradeSizeRatio: 0.2e18,
            ruleParameters: new int256[][](0),
            poolManager: addr2
        });
        poolSettings.oracles[0] = new address[](1);
        poolSettings.oracles[0][0] = address(chainlinkOracle);

        updateWeightRunner.setRuleForPoolAdminInitialise(poolSettings, address(mockPool));
        vm.expectRevert("Rule already set");
        updateWeightRunner.setRuleForPoolAdminInitialise(poolSettings, address(mockPool));
        vm.stopPrank();
    }

    function testSetRuleForPoolAdminInitialiseEmptyOraclesArray() public {
        vm.startPrank(owner);
        IQuantAMMWeightedPool.PoolSettings memory poolSettings = IQuantAMMWeightedPool.PoolSettings({
            assets: new IERC20[](0),
            rule: mockRule,
            oracles: new address[][](0),
            updateInterval: 1,
            lambda: new uint64[](1),
            epsilonMax: 0.2e18,
            absoluteWeightGuardRail: 0.2e18,
            maxTradeSizeRatio: 0.2e18,
            ruleParameters: new int256[][](0),
            poolManager: addr2
        });

        vm.expectRevert("Empty oracles array");
        updateWeightRunner.setRuleForPoolAdminInitialise(poolSettings, address(mockPool));
        vm.stopPrank();
    }

    function testSetRuleForPoolAdminInitialisePoolRuleAlreadySet() public {
        int216 fixedValue = 1000;
        uint delay = 3600;
        chainlinkOracle = deployOracle(fixedValue, delay);

        vm.startPrank(owner);
        updateWeightRunner.addOracle(OracleWrapper(chainlinkOracle));
        vm.stopPrank();

        vm.startPrank(owner);
        IQuantAMMWeightedPool.PoolSettings memory poolSettings = IQuantAMMWeightedPool.PoolSettings({
            assets: new IERC20[](0),
            rule: mockRule,
            oracles: new address[][](1),
            updateInterval: 1,
            lambda: new uint64[](1),
            epsilonMax: 0.2e18,
            absoluteWeightGuardRail: 0.2e18,
            maxTradeSizeRatio: 0.2e18,
            ruleParameters: new int256[][](0),
            poolManager: addr2
        });
        poolSettings.oracles[0] = new address[](1);
        poolSettings.oracles[0][0] = address(chainlinkOracle);

        updateWeightRunner.setRuleForPoolAdminInitialise(poolSettings, address(mockPool));
        vm.expectRevert("Rule already set");
        updateWeightRunner.setRuleForPoolAdminInitialise(poolSettings, address(mockPool));
        vm.stopPrank();
    }

    function testSetRuleForPoolAdminInitialiseInvalidPoolAddress() public {
        int216 fixedValue = 1000;
        uint delay = 3600;
        chainlinkOracle = deployOracle(fixedValue, delay);

        vm.startPrank(owner);
        updateWeightRunner.addOracle(OracleWrapper(chainlinkOracle));
        vm.stopPrank();

        vm.startPrank(owner);
        IQuantAMMWeightedPool.PoolSettings memory poolSettings = IQuantAMMWeightedPool.PoolSettings({
            assets: new IERC20[](0),
            rule: mockRule,
            oracles: new address[][](1),
            updateInterval: 1,
            lambda: new uint64[](1),
            epsilonMax: 0.2e18,
            absoluteWeightGuardRail: 0.2e18,
            maxTradeSizeRatio: 0.2e18,
            ruleParameters: new int256[][](0),
            poolManager: addr2
        });
        poolSettings.oracles[0] = new address[](1);
        poolSettings.oracles[0][0] = address(chainlinkOracle);

        vm.expectRevert("Invalid pool address");
        updateWeightRunner.setRuleForPoolAdminInitialise(poolSettings, address(0));
        vm.stopPrank();
    }

    function testSetRuleForPoolAdminInitialiseUpdateIntervalGreaterThanZero() public {
        int216 fixedValue = 1000;
        uint delay = 3600;
        chainlinkOracle = deployOracle(fixedValue, delay);

        vm.startPrank(owner);
        updateWeightRunner.addOracle(OracleWrapper(chainlinkOracle));
        vm.stopPrank();

        vm.startPrank(owner);
        IQuantAMMWeightedPool.PoolSettings memory poolSettings = IQuantAMMWeightedPool.PoolSettings({
            assets: new IERC20[](0),
            rule: mockRule,
            oracles: new address[][](1),
            updateInterval: 0,
            lambda: new uint64[](1),
            epsilonMax: 0.2e18,
            absoluteWeightGuardRail: 0.2e18,
            maxTradeSizeRatio: 0.2e18,
            ruleParameters: new int256[][](0),
            poolManager: addr2
        });
        poolSettings.oracles[0] = new address[](1);
        poolSettings.oracles[0][0] = address(chainlinkOracle);

        vm.expectRevert("Update interval must be greater than 0");
        updateWeightRunner.setRuleForPoolAdminInitialise(poolSettings, address(mockPool));
        vm.stopPrank();
    }

    function testFuzz_getDataBackupOracles_ThrowOnUpdate(
        int256 numberOfBackups,
        int256 positionOfNonStaleData,
        int256 unboundNumAssets
    ) public {
        uint256 numAssets = uint256(bound(unboundNumAssets, 2, 8));

        int256[] memory initialWeights = new int256[](numAssets * 2);
        for (uint i = 0; i < numAssets; i++) {
            initialWeights[i] = 0.0000000005e18;
            initialWeights[i + numAssets] = 0;
        }
        uint256 boundBackup = uint256(bound(numberOfBackups, 0, 5));
        uint256 boundPosition = uint256(bound(positionOfNonStaleData, 0, int256(boundBackup)));

        mockPool.setInitialWeights(initialWeights);
        mockPool.setPoolRegistry(9);
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 9);
        vm.stopPrank();

        MockChainlinkOracle[] memory validOracles = new MockChainlinkOracle[](numAssets);
        int216 fixedValue = 1000;
        for (uint i = 0; i < numAssets; i++) {
            validOracles[i] = deployOracle(fixedValue + int216(int256(i)), 0);
        }

        int216 fixedValue2 = 5000;
        MockChainlinkOracle staleChainlinkOracle = deployOracle(fixedValue2, 1000);
        staleChainlinkOracle.setThrowOnUpdate(true);

        vm.startPrank(owner);
        for (uint i = 0; i < validOracles.length; i++) {
            updateWeightRunner.addOracle(OracleWrapper(validOracles[i]));
        }
        updateWeightRunner.addOracle(OracleWrapper(staleChainlinkOracle));
        vm.stopPrank();

        vm.startPrank(address(mockPool));
        address[][] memory oracles = new address[][](numAssets);
        for (uint i = 0; i < numAssets; i++) {
            oracles[i] = new address[](boundBackup + 1);
            for (uint j = 0; j < oracles[i].length; j++) {
                if (j == boundPosition) {
                    oracles[i][j] = address(validOracles[i]);
                } else {
                    oracles[i][j] = address(staleChainlinkOracle);
                }
            }
        }

        int256[] memory expectedData = new int256[](numAssets);
        for (uint i = 0; i < numAssets; i++) {
            expectedData[i] = int256(fixedValue + int216(int256(i)));
        }
        mockRule.setExpectedDataValue(expectedData);

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

    function testFuzz_getDataBackupOracles(int256 numberOfBackups, int256 positionOfNonStaleData, int256 unboundNumAssets) public {
        uint256 numAssets = uint256(bound(unboundNumAssets,2,8));

        int256[] memory initialWeights = new int256[](numAssets * 2);

        for(uint i; i < numAssets; i++){
            initialWeights[i] = 0.0000000005e18;
            initialWeights[i + numAssets] = 0;
        }
        uint256 boundBackup = uint256(bound(numberOfBackups, 0, 5));
        uint256 boundPosition = uint256(bound(positionOfNonStaleData, 0, int256(boundBackup)));

        // Set initial weights
        mockPool.setInitialWeights(initialWeights);
        mockPool.setPoolRegistry(9);
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 9);
        vm.stopPrank();

        MockChainlinkOracle[] memory validOracles = new MockChainlinkOracle[](numAssets);
        int216 fixedValue = 1000;
        for(uint i = 0; i < numAssets; i++){
            validOracles[i] = deployOracle(fixedValue + int216(int256(i)), 0);
        }

        int216 fixedValue2 = 5000;
        MockChainlinkOracle staleChainlinkOracle = deployOracle(fixedValue2, 1000);

        vm.startPrank(owner);
        
        for(uint i = 0; i < validOracles.length; i++){
            updateWeightRunner.addOracle(OracleWrapper(validOracles[i]));
        }

        updateWeightRunner.addOracle(OracleWrapper(staleChainlinkOracle));

        vm.stopPrank();

        vm.startPrank(address(mockPool));

        address[][] memory oracles = new address[][](numAssets);
        for(uint i = 0; i < numAssets; i++){
            oracles[i] = new address[](boundBackup + 1);
            for(uint j = 0; j < oracles[i].length; j++){
                if(j == boundPosition){
                    oracles[i][j] = address(validOracles[i]);
                } else {
                    oracles[i][j] = address(staleChainlinkOracle);
                }
            }
        }

        int256[] memory expectedData = new int256[](numAssets);
        for(uint i = 0; i < numAssets; i++){
            expectedData[i] = int256(fixedValue + int216(int256(i)));
        }
        
        mockRule.setExpectedDataValue(expectedData);
        
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

    function testNoBackupOracleStalePriceThow() public {
        int256[] memory initialWeights = new int256[](4);
        initialWeights[0] = 0.0000000005e18;
        initialWeights[1] = 0.0000000005e18;
        initialWeights[2] = 0;
        initialWeights[3] = 0;

        // Set initial weights
        mockPool.setInitialWeights(initialWeights);
        mockPool.setPoolRegistry(9);
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 9);
        vm.stopPrank();

        int216 fixedValue = 1000;
        chainlinkOracle = deployOracle(fixedValue, 3000);

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
        
        vm.expectRevert("No fresh oracle values available");
        updateWeightRunner.performUpdate(address(mockPool));
    }

    function testMultipleConsecutiveUpdatesSuccessful() public {
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


    function testCalculateBlockMultiplierCorrectly() public {
        int256[] memory initialWeights = new int256[](4);
        initialWeights[0] = 0.5e18;
        initialWeights[1] = 0.5e18;
        initialWeights[2] = 0;
        initialWeights[3] = 0;

        // Set initial weights
        mockPool.setInitialWeights(initialWeights);

        //set pool registry
        mockPool.setPoolRegistry(9);
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 9);
        vm.stopPrank();
        
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


    function testGetDataWhenPoolHasPerformUpdateAndGetDataPermSuccess() public {
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 11);
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
        updateWeightRunner.getData(address(mockPool));
    }


    function testGetDataWhenPoolHasPerformUpdatePermSuccess() public {
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 9);
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
        console.log(owner);
        console.log(addr2);
        console.log(address(mockPool));
        console.log(address(this));
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


    function testGetDataWhenPoolDoesNotHavePermFailure() public {
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 8);
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

        vm.expectRevert("Not allowed to get data");
        updateWeightRunner.getData(address(mockPool));
    }


    function testCalculateBlockMultiplierBeyondLimit() public {
        int256[] memory initialWeights = new int256[](4);
        initialWeights[0] = 0.5e18;
        initialWeights[1] = 0.5e18;
        initialWeights[2] = 0;
        initialWeights[3] = 0;

        // Set initial weights
        mockPool.setInitialWeights(initialWeights);
        //admin perms
        mockPool.setPoolRegistry(9);
        
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 9);
        vm.stopPrank();
        
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

    function testCalculateBlockMultiplierZero() public {
        int256[] memory initialWeights = new int256[](4);
        initialWeights[0] = 0.5e18;
        initialWeights[1] = 0.5e18;
        initialWeights[2] = 0;
        initialWeights[3] = 0;

        // Set initial weights
        mockPool.setInitialWeights(initialWeights);
        
        //set pool registry
        mockPool.setPoolRegistry(9);
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 9);
        vm.stopPrank();

        //stays the same
        int256[] memory newCalculatedWeights = new int256[](2);
        newCalculatedWeights[0] = 0.5e18;
        newCalculatedWeights[1] = 0.5e18;

        mockRule.setWeights(newCalculatedWeights);

        int216 fixedValue1 = 1000;
        int216 fixedValue2 = 1000;

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
        expectedWeights[2] = 0e18;
        expectedWeights[3] = 0e18;

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

        assertEq(mockPool.lastInterpolationTimePossible(), 1099511627775);
    }


    function testCalculateBlockMultiplierLastInterpolationTimeBeforeUpdateInterval() public {
        int256[] memory initialWeights = new int256[](4);
        initialWeights[0] = 0.6e18;
        initialWeights[1] = 0.4e18;
        initialWeights[2] = 0;
        initialWeights[3] = 0;

        // Set initial weights
        mockPool.setInitialWeights(initialWeights);
        
        //set pool registry
        mockPool.setPoolRegistry(9);
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 9);
        vm.stopPrank();

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

    function testMultipleConsecutiveUpdatesFailsIfNotApproved() public {
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

    function testSetWeightsManuallyNegativeFails_Fuzz(int256 negativeWeight) public {
        int256[] memory weights = new int256[](4);
        weights[0] = bound(negativeWeight, type(int256).min, 0e18);
        weights[1] = 0.0000000005e18;
        weights[2] = 0;
        weights[3] = 0;
        mockPool.setPoolRegistry(16);
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 16);
        vm.stopPrank();

        vm.startPrank(owner);
        vm.expectRevert("Below min allowed weight");
        updateWeightRunner.setWeightsManually(weights, address(mockPool), 6, 2);
        vm.stopPrank();
    }

    function testSetWeightsManuallyBetween0And1Allowed_Fuzz(int256 firstWeight, int256 secondWeight) public {
        int256[] memory weights = new int256[](4);
        weights[0] = bound(firstWeight, 0.01e18, 0.99e18);
        weights[1] = bound(secondWeight, 0.01e18, 0.99e18);
        weights[2] = 0;
        weights[3] = 0;
        mockPool.setPoolRegistry(16);
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 16);
        vm.stopPrank();

        vm.startPrank(owner);
        updateWeightRunner.setWeightsManually(weights, address(mockPool), 6, 2);
        vm.stopPrank();
    }

    function testSetWeightsManuallyNegativeFails2ndWeight_Fuzz(int256 negativeWeight) public {
        int256[] memory weights = new int256[](4);
        weights[0] = 0.0000000005e18;
        weights[1] = bound(negativeWeight, type(int256).min, -0.000000001e18);
        weights[2] = 0;
        weights[3] = 0;
        mockPool.setPoolRegistry(16);
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 16);
        vm.stopPrank();

        vm.startPrank(owner);
        vm.expectRevert("Below min allowed weight");
        updateWeightRunner.setWeightsManually(weights, address(mockPool), 6, 2);
        vm.stopPrank();
    }

    function testSetWeightsManuallyGreaterThan99PctFails_Fuzz(int256 moreThanOneWeight) public {
        int256[] memory weights = new int256[](4);
        weights[0] = bound(moreThanOneWeight, 0.99e18 + 1, type(int256).max);
        weights[1] = 0.0000000005e18;
        weights[2] = 0;
        weights[3] = 0;
        mockPool.setPoolRegistry(16);
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 16);
        vm.stopPrank();

        vm.startPrank(owner);
        vm.expectRevert("Above max allowed weight");
        updateWeightRunner.setWeightsManually(weights, address(mockPool), 6, 2);
        vm.stopPrank();
    }

    function testSetWeightsManuallyGreaterThanOne2ndWeightFails_Fuzz(int256 moreThanOneWeight) public {
        int256[] memory weights = new int256[](4);
        weights[0] = 0.01e18;
        weights[1] = bound(moreThanOneWeight, 1e18, type(int256).max);
        weights[2] = 0;
        weights[3] = 0;
        mockPool.setPoolRegistry(16);
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 16);
        vm.stopPrank();

        vm.startPrank(owner);
        vm.expectRevert("Above max allowed weight");
        updateWeightRunner.setWeightsManually(weights, address(mockPool), 6, 2);
        vm.stopPrank();
    }

    function testSetWeightsManuallyAdmin() public {
        int256[] memory weights = new int256[](4);
        weights[0] = 0.01e18;
        weights[1] = 0.01e18;
        weights[2] = 0;
        weights[3] = 0;
        mockPool.setPoolRegistry(16);
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 16);
        vm.stopPrank();

        vm.startPrank(owner);

        updateWeightRunner.setWeightsManually(weights, address(mockPool), 6, 2);

        vm.stopPrank();
        uint256[] memory poolWeights = new uint256[](2);
        poolWeights[0] = 0.01e18;
        poolWeights[1] = 0.01e18;
        assertEq(IWeightedPool(address(mockPool)).getNormalizedWeights(), poolWeights);
    }


    function testSetWeightsManuallyFailsAdminPermOwnerFails() public {
        int256[] memory weights = new int256[](4);
        weights[0] = 0.0000000005e18;
        weights[1] = 0.0000000005e18;
        weights[2] = 0;
        weights[3] = 0;
        mockPool.setPoolRegistry(16);

        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 16);
        vm.stopPrank();

        vm.startPrank(addr2);
        vm.expectRevert("ONLYADMIN");
        updateWeightRunner.setWeightsManually(weights, address(mockPool), 6, 2);
        vm.stopPrank();
    }

    function testSetWeightsManuallyPoolOwner() public {
        int256[] memory weights = new int256[](4);
        weights[0] = 0.01e18;
        weights[1] = 0.01e18;
        weights[2] = 0.01e18;
        weights[3] = 0.01e18;
        mockPool.setPoolRegistry(8);

        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 8);
        vm.stopPrank();
        
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
        updateWeightRunner.setWeightsManually(weights, address(mockPool), 6, 2);
        vm.stopPrank();
        uint256[] memory poolWeights = new uint256[](2);
        poolWeights[0] = 0.01e18;
        poolWeights[1] = 0.01e18;
        assertEq(IWeightedPool(address(mockPool)).getNormalizedWeights(), poolWeights);
    }

    function testSetTargetWeightsManuallyNegativeFails_Fuzz(int256 negativeWeight) public {
        int256[] memory weights = new int256[](2);
        weights[0] = bound(negativeWeight, type(int256).min, 0e18);
        weights[1] = 0.0000000005e18;
        mockPool.setPoolRegistry(16);
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 16);
        vm.stopPrank();

        vm.startPrank(owner);
        vm.expectRevert("Below min allowed weight");
        updateWeightRunner.setTargetWeightsManually(weights, address(mockPool), 6, 2);
        vm.stopPrank();
    }

    function testSetTargetWeightsManuallyBetween0And1Allowed_Fuzz(int256 firstWeight, int256 secondWeight) public {
        int256[] memory initialWeights = new int256[](4);
        initialWeights[0] = 0.5e18;
        initialWeights[1] = 0.5e18;
        initialWeights[2] = 0;
        initialWeights[3] = 0;
        
        mockPool.setPoolRegistry(16);
        mockPool.setInitialWeights(initialWeights);

        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 16);
        vm.stopPrank();

        int256[] memory weights = new int256[](2);
        weights[0] = bound(firstWeight, 0.01e18, 0.99e18);
        weights[1] = bound(secondWeight, 0.01e18, 0.99e18);
        
        vm.startPrank(owner);
        updateWeightRunner.setTargetWeightsManually(weights, address(mockPool), 6, 2);
        vm.stopPrank();
    }

    function testSetTargetWeightsManuallyNegativeFails2ndWeight_Fuzz(int256 negativeWeight) public {
        int256[] memory weights = new int256[](4);
        weights[0] = 0.0000000005e18;
        weights[1] = bound(negativeWeight, type(int256).min, -0.000000001e18);
        weights[2] = 0;
        weights[3] = 0;
        mockPool.setPoolRegistry(16);
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 16);
        vm.stopPrank();

        vm.startPrank(owner);
        vm.expectRevert("Below min allowed weight");
        updateWeightRunner.setTargetWeightsManually(weights, address(mockPool), 6, 2);
        vm.stopPrank();
    }

    function testSetTargetWeightsManuallyGreaterThan99PctFails_Fuzz(int256 moreThanOneWeight) public {
        int256[] memory weights = new int256[](4);
        weights[0] = bound(moreThanOneWeight, 0.99e18 + 1, type(int256).max);
        weights[1] = 0.0000000005e18;
        weights[2] = 0;
        weights[3] = 0;

        mockPool.setPoolRegistry(16);
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 16);
        vm.stopPrank();

        vm.startPrank(owner);
        vm.expectRevert("Above max allowed weight");
        updateWeightRunner.setTargetWeightsManually(weights, address(mockPool), 6, 2);
        vm.stopPrank();
    }

    function testSetTargetWeightsManuallyGreaterThanOne2ndWeightFails_Fuzz(int256 moreThanOneWeight) public {
        int256[] memory weights = new int256[](4);
        weights[0] = 0.01e18;
        weights[1] = bound(moreThanOneWeight, 1e18, type(int256).max);
        weights[2] = 0;
        weights[3] = 0;
        mockPool.setPoolRegistry(16);
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 16);
        vm.stopPrank();

        vm.startPrank(owner);
        vm.expectRevert("Above max allowed weight");
        updateWeightRunner.setTargetWeightsManually(weights, address(mockPool), 6, 2);
        vm.stopPrank();
    }

    function testSetTargetWeightsManuallyAdmin() public {
        int256[] memory weights = new int256[](4);
        weights[0] = 0.01e18;
        weights[1] = 0.01e18;
        weights[2] = 0;
        weights[3] = 0;

        mockPool.setPoolRegistry(16);
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 16);
        mockPool.setInitialWeights(weights);

        vm.startPrank(owner);
        int256[] memory newWeights = new int256[](2);
        newWeights[0] = 0.5e18;
        newWeights[1] = 0.5e18;

        updateWeightRunner.setTargetWeightsManually(newWeights, address(mockPool), 1000, 2);

        vm.stopPrank();

        uint256[] memory poolWeights = new uint256[](2);
        poolWeights[0] = 0.01e18;
        poolWeights[1] = 0.01e18;
        assertEq(IWeightedPool(address(mockPool)).getNormalizedWeights(), poolWeights);

        int256[] memory getCurrentWeightsAndMultipliers = mockPool.getWeights();

        assertEq(getCurrentWeightsAndMultipliers[0], 0.01e18);
        assertEq(getCurrentWeightsAndMultipliers[1], 0.01e18);
        assertEq(getCurrentWeightsAndMultipliers[2], 0.00049e18);
        assertEq(getCurrentWeightsAndMultipliers[3], 0.00049e18);
    }


    function testSetTargetWeightsManuallyFailsAdminPermOwnerFails() public {
        int256[] memory weights = new int256[](4);
        weights[0] = 0.0000000005e18;
        weights[1] = 0.0000000005e18;
        weights[2] = 0;
        weights[3] = 0;
        mockPool.setPoolRegistry(16);

        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 16);
        vm.stopPrank();

        vm.startPrank(addr2);
        vm.expectRevert("ONLYADMIN");
        updateWeightRunner.setTargetWeightsManually(weights, address(mockPool), 6, 2);
        vm.stopPrank();
    }

    function testSetTargetWeightsManuallyPoolOwner() public {
        int256[] memory weights = new int256[](4);
        weights[0] = 0.01e18;
        weights[1] = 0.01e18;
        weights[2] = 0;
        weights[3] = 0;
        mockPool.setPoolRegistry(8);

        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 8);
        mockPool.setInitialWeights(weights);
        vm.stopPrank();
        
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

        int256[] memory newWeights = new int256[](2);
        newWeights[0] = 0.5e18;
        newWeights[1] = 0.5e18;
        
        //multiplier should be 0.5e18 - 0.01e18 = 0.49e18

        updateWeightRunner.setTargetWeightsManually(newWeights, address(mockPool), 100, 2);

        vm.stopPrank();

        uint256[] memory poolWeights = new uint256[](2);
        poolWeights[0] = 0.01e18;
        poolWeights[1] = 0.01e18;
        assertEq(IWeightedPool(address(mockPool)).getNormalizedWeights(), poolWeights);
        
        int256[] memory getCurrentWeightsAndMultipliers = mockPool.getWeights();

        assertEq(getCurrentWeightsAndMultipliers[0], 0.01e18);
        assertEq(getCurrentWeightsAndMultipliers[1], 0.01e18);
        assertEq(getCurrentWeightsAndMultipliers[2], 0.0049e18);
        assertEq(getCurrentWeightsAndMultipliers[3], 0.0049e18);
    }


    function testSetTargetWeightsManuallyFailsOwnerPermAdminFails() public {
        int256[] memory weights = new int256[](2);
        weights[0] = 0.0000000005e18;
        weights[1] = 0.0000000005e18;
        mockPool.setPoolRegistry(8);

        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 8);

        vm.expectRevert("ONLYMANAGER");
        updateWeightRunner.setWeightsManually(weights, address(mockPool), 6, 2);
        vm.stopPrank();
    }

    function testSetTargetWeightsManuallyInitiallyNonOwnerFails() public {
        int256[] memory weights = new int256[](2);
        weights[0] = 0.0000000005e18;
        weights[1] = 0.0000000005e18;

        vm.startPrank(addr1);
        vm.expectRevert("No permission to set weight values");
        updateWeightRunner.setTargetWeightsManually(weights, address(mockPool), 6, 2);
    }

    function testSetTargetWeightsManuallyOwnerPermedNonOwnerFails() public {
        int256[] memory weights = new int256[](2);
        weights[0] = 0.0000000005e18;
        weights[1] = 0.0000000005e18;
        mockPool.setPoolRegistry(8);

        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 8);
        vm.stopPrank();

        vm.startPrank(addr1);
        vm.expectRevert("ONLYMANAGER");
        updateWeightRunner.setTargetWeightsManually(weights, address(mockPool), 6, 2);
    }

    function testSetTargetWeightsManuallyAdminPermedNonOwnerFails() public {
        int256[] memory weights = new int256[](4);
        weights[0] = 0.0000000005e18;
        weights[1] = 0.0000000005e18;
        weights[2] = 0;
        weights[3] = 0;

        mockPool.setPoolRegistry(16);

        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 16);
        mockPool.setInitialWeights(weights);
        vm.stopPrank();

        vm.startPrank(addr1);
        vm.expectRevert("ONLYADMIN");
        updateWeightRunner.setTargetWeightsManually(weights, address(mockPool), 6, 2);
        vm.stopPrank();
    }

    function testCalculateMultiplierAndSetWeightsFromRuleSuccess() public {
        int256[] memory weights = new int256[](4);
        weights[0] = 0.5e18;
        weights[1] = 0.5e18;
        weights[2] = 0;
        weights[3] = 0;
        mockPool.setPoolRegistry(8);

        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 8);
        vm.stopPrank();
        
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
                updateInterval: 100,
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
        updateWeightRunner.setWeightsManually(weights, address(mockPool), 6, 2);
        vm.stopPrank();

        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 32);
        vm.stopPrank();
        

        int256[] memory poolWeights = new int256[](2);
        poolWeights[0] = 0.6e18;
        poolWeights[1] = 0.4e18;

        uint256[] memory currentWeightsUnsigned = IWeightedPool(address(mockPool)).getNormalizedWeights();
        int256[] memory currentWeights = new int256[](currentWeightsUnsigned.length);

        for (uint i; i < currentWeights.length; ) {
            currentWeights[i] = int256(currentWeightsUnsigned[i]);

            unchecked {
                i++;
            }
        }
        vm.startPrank(address(mockRule));
        updateWeightRunner.calculateMultiplierAndSetWeightsFromRule(UpdateWeightRunner.CalculateMuliplierAndSetWeightsLocal({
                currentWeights: currentWeights,
                updatedWeights: poolWeights,
                updateInterval: int256(100),
                absoluteWeightGuardRail18: 0.2e18,
                poolAddress: address(mockPool)
            })
        );
        vm.stopPrank();
        currentWeightsUnsigned = IWeightedPool(address(mockPool)).getNormalizedWeights();
        currentWeights = new int256[](currentWeightsUnsigned.length);

        for (uint i; i < currentWeights.length; ) {
            currentWeights[i] = int256(currentWeightsUnsigned[i]);

            unchecked {
                i++;
            }
        }

        currentWeights = mockPool.getWeights();

        assertEq(currentWeights[0], 0.5e18);
        assertEq(currentWeights[1], 0.5e18);
        assertEq(currentWeights[2], 0.001e18);
        assertEq(currentWeights[3], -0.001e18);
    }


    function testCalculateMultiplierAndSetWeightsFromRuleFailBadSender() public {
        int256[] memory weights = new int256[](4);
        weights[0] = 0.5e18;
        weights[1] = 0.5e18;
        weights[2] = 0;
        weights[3] = 0;
        mockPool.setPoolRegistry(8);
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 8);
        vm.stopPrank();
        uint40 blockTime = uint40(block.timestamp);
        int216 fixedValue = 1000;
        uint delay = 3600;
        chainlinkOracle = deployOracle(fixedValue, delay);

        vm.startPrank(owner);
        updateWeightRunner.addOracle(OracleWrapper(chainlinkOracle));
        vm.stopPrank();

        //test non setup pools cannot be used
        vm.startPrank(address(chainlinkOracle));
        vm.expectRevert("ONLYRULECANSETWEIGHTS");
        updateWeightRunner.calculateMultiplierAndSetWeightsFromRule(UpdateWeightRunner.CalculateMuliplierAndSetWeightsLocal({
                currentWeights: weights,
                updatedWeights: weights,
                updateInterval: int256(100),
                absoluteWeightGuardRail18: 0.2e18,
                poolAddress: address(mockPool)
            })
        );
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
                updateInterval: 100,
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
        updateWeightRunner.setWeightsManually(weights, address(mockPool), 6, 2);
        vm.stopPrank();

        mockPool.setPoolRegistry(32);

        int256[] memory poolWeights = new int256[](2);
        poolWeights[0] = 0.6e18;
        poolWeights[1] = 0.4e18;

        uint256[] memory currentWeightsUnsigned = IWeightedPool(address(mockPool)).getNormalizedWeights();
        int256[] memory currentWeights = new int256[](currentWeightsUnsigned.length);

        for (uint i; i < currentWeights.length; ) {
            currentWeights[i] = int256(currentWeightsUnsigned[i]);

            unchecked {
                i++;
            }
        }
        vm.startPrank(address(mockPool));
        vm.expectRevert("ONLYRULECANSETWEIGHTS");
        updateWeightRunner.calculateMultiplierAndSetWeightsFromRule(UpdateWeightRunner.CalculateMuliplierAndSetWeightsLocal({
                currentWeights: currentWeights,
                updatedWeights: poolWeights,
                updateInterval: int256(100),
                absoluteWeightGuardRail18: 0.2e18,
                poolAddress: address(mockPool)
            })
        );
        vm.stopPrank();

        vm.startPrank(address(0));
        vm.expectRevert("ONLYRULECANSETWEIGHTS");
        updateWeightRunner.calculateMultiplierAndSetWeightsFromRule(UpdateWeightRunner.CalculateMuliplierAndSetWeightsLocal({
                currentWeights: currentWeights,
                updatedWeights: poolWeights,
                updateInterval: int256(100),
                absoluteWeightGuardRail18: 0.2e18,
                poolAddress: address(mockPool)
            })
        );
        vm.stopPrank();

        vm.startPrank(owner);
        vm.expectRevert("ONLYRULECANSETWEIGHTS");
        updateWeightRunner.calculateMultiplierAndSetWeightsFromRule(UpdateWeightRunner.CalculateMuliplierAndSetWeightsLocal({
                currentWeights: currentWeights,
                updatedWeights: poolWeights,
                updateInterval: int256(100),
                absoluteWeightGuardRail18: 0.2e18,
                poolAddress: address(mockPool)
            })
        );
        vm.stopPrank();


        vm.startPrank(addr1);
        vm.expectRevert("ONLYRULECANSETWEIGHTS");
        updateWeightRunner.calculateMultiplierAndSetWeightsFromRule(UpdateWeightRunner.CalculateMuliplierAndSetWeightsLocal({
                currentWeights: currentWeights,
                updatedWeights: poolWeights,
                updateInterval: int256(100),
                absoluteWeightGuardRail18: 0.2e18,
                poolAddress: address(mockPool)
            })
        );
        vm.stopPrank();

        vm.startPrank(addr2);
        vm.expectRevert("ONLYRULECANSETWEIGHTS");
        updateWeightRunner.calculateMultiplierAndSetWeightsFromRule(UpdateWeightRunner.CalculateMuliplierAndSetWeightsLocal({
                currentWeights: currentWeights,
                updatedWeights: poolWeights,
                updateInterval: int256(100),
                absoluteWeightGuardRail18: 0.2e18,
                poolAddress: address(mockPool)
            })
        );
        vm.stopPrank();

        vm.startPrank(address(chainlinkOracle));
        vm.expectRevert("ONLYRULECANSETWEIGHTS");
        updateWeightRunner.calculateMultiplierAndSetWeightsFromRule(UpdateWeightRunner.CalculateMuliplierAndSetWeightsLocal({
                currentWeights: currentWeights,
                updatedWeights: poolWeights,
                updateInterval: int256(100),
                absoluteWeightGuardRail18: 0.2e18,
                poolAddress: address(mockPool)
            })
        );
        vm.stopPrank();
    }

    function testCalculateMultiplierAndSetWeightsFromRuleFailBadRegistry() public {
        int256[] memory weights = new int256[](4);
        weights[0] = 0.5e18;
        weights[1] = 0.5e18;
        weights[2] = 0;
        weights[3] = 0;
        mockPool.setPoolRegistry(8);
        
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 8);
        vm.stopPrank();

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
                updateInterval: 100,
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
        updateWeightRunner.setWeightsManually(weights, address(mockPool), 6, 2);
        vm.stopPrank();

        int256[] memory poolWeights = new int256[](2);
        poolWeights[0] = 0.6e18;
        poolWeights[1] = 0.4e18;

        uint256[] memory currentWeightsUnsigned = IWeightedPool(address(mockPool)).getNormalizedWeights();
        int256[] memory currentWeights = new int256[](currentWeightsUnsigned.length);

        for (uint i; i < currentWeights.length; ) {
            currentWeights[i] = int256(currentWeightsUnsigned[i]);

            unchecked {
                i++;
            }
        }
        vm.startPrank(address(mockRule));
        mockPool.setPoolRegistry(2);
        vm.expectRevert("FUNCTIONNOTAPPROVEDFORPOOL");
        updateWeightRunner.calculateMultiplierAndSetWeightsFromRule(UpdateWeightRunner.CalculateMuliplierAndSetWeightsLocal({
                currentWeights: currentWeights,
                updatedWeights: poolWeights,
                updateInterval: int256(100),
                absoluteWeightGuardRail18: 0.2e18,
                poolAddress: address(mockPool)
            })
        );

        mockPool.setPoolRegistry(4);
        vm.expectRevert("FUNCTIONNOTAPPROVEDFORPOOL");
        updateWeightRunner.calculateMultiplierAndSetWeightsFromRule(UpdateWeightRunner.CalculateMuliplierAndSetWeightsLocal({
                currentWeights: currentWeights,
                updatedWeights: poolWeights,
                updateInterval: int256(100),
                absoluteWeightGuardRail18: 0.2e18,
                poolAddress: address(mockPool)
            })
        );


        mockPool.setPoolRegistry(8);
        vm.expectRevert("FUNCTIONNOTAPPROVEDFORPOOL");
        updateWeightRunner.calculateMultiplierAndSetWeightsFromRule(UpdateWeightRunner.CalculateMuliplierAndSetWeightsLocal({
                currentWeights: currentWeights,
                updatedWeights: poolWeights,
                updateInterval: int256(100),
                absoluteWeightGuardRail18: 0.2e18,
                poolAddress: address(mockPool)
            })
        );

        mockPool.setPoolRegistry(16);
        vm.expectRevert("FUNCTIONNOTAPPROVEDFORPOOL");
        updateWeightRunner.calculateMultiplierAndSetWeightsFromRule(UpdateWeightRunner.CalculateMuliplierAndSetWeightsLocal({
                currentWeights: currentWeights,
                updatedWeights: poolWeights,
                updateInterval: int256(100),
                absoluteWeightGuardRail18: 0.2e18,
                poolAddress: address(mockPool)
            })
        );

        mockPool.setPoolRegistry(64);
        vm.expectRevert("FUNCTIONNOTAPPROVEDFORPOOL");
        updateWeightRunner.calculateMultiplierAndSetWeightsFromRule(UpdateWeightRunner.CalculateMuliplierAndSetWeightsLocal({
                currentWeights: currentWeights,
                updatedWeights: poolWeights,
                updateInterval: int256(100),
                absoluteWeightGuardRail18: 0.2e18,
                poolAddress: address(mockPool)
            })
        );
        vm.stopPrank();
    }



    function testSetWeightsManuallyFailsOwnerPermAdminFails() public {
        int256[] memory weights = new int256[](4);
        weights[0] = 0.0000000005e18;
        weights[1] = 0.0000000005e18;
        weights[2] = 0;
        weights[3] = 0;
        mockPool.setPoolRegistry(8);

        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 8);

        vm.expectRevert("ONLYMANAGER");
        updateWeightRunner.setWeightsManually(weights, address(mockPool), 6, 2);
        vm.stopPrank();
    }

    function testSetWeightsManuallyInitiallyNonOwnerFails() public {
        int256[] memory weights = new int256[](4);
        weights[0] = 0.0000000005e18;
        weights[1] = 0.0000000005e18;
        weights[2] = 0;
        weights[3] = 0;

        vm.startPrank(addr1);
        vm.expectRevert("No permission to set weight values");
        updateWeightRunner.setWeightsManually(weights, address(mockPool), 6, 2);
    }

    function testSetWeightsManuallyOwnerPermedNonOwnerFails() public {
        int256[] memory weights = new int256[](4);
        weights[0] = 0.0000000005e18;
        weights[1] = 0.0000000005e18;
        weights[2] = 0;
        weights[3] = 0;
        mockPool.setPoolRegistry(8);

        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 8);
        vm.stopPrank();

        vm.startPrank(addr1);
        vm.expectRevert("ONLYMANAGER");
        updateWeightRunner.setWeightsManually(weights, address(mockPool), 6, 2);
    }

    function testSetWeightsManuallyAdminPermedNonOwnerFails() public {
        int256[] memory weights = new int256[](4);
        weights[0] = 0.0000000005e18;
        weights[1] = 0.0000000005e18;
        weights[2] = 0;
        weights[3] = 0;
        mockPool.setPoolRegistry(16);

        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 16);
        vm.stopPrank();

        vm.startPrank(addr1);
        vm.expectRevert("ONLYADMIN");
        updateWeightRunner.setWeightsManually(weights, address(mockPool), 6, 2);
    }

    function testSetIntermediateValuesManually() public {
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
        
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 16);
        vm.stopPrank();

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

    function testSetIntermediateValuesManuallyInitiallyNonOwnerFails() public {
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

    function testInitialisePoolLastRunTimeOwnerPermedNonOwnerFails() public {
        uint40 blockTime = uint40(block.timestamp);
        mockPool.setPoolRegistry(8);
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 8);
        vm.stopPrank();
        vm.startPrank(addr1);
        vm.expectRevert("ONLYMANAGER");
        updateWeightRunner.InitialisePoolLastRunTime(address(mockPool), blockTime);
    }

    function testInitialisePoolLastRunTimeAdminPermedNonOwnerFails() public {
        uint40 blockTime = uint40(block.timestamp);
        mockPool.setPoolRegistry(16);
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 16);
        vm.stopPrank();
        vm.startPrank(addr1);
        vm.expectRevert("ONLYADMIN");
        updateWeightRunner.InitialisePoolLastRunTime(address(mockPool), blockTime);
    }

    function testInitialisePoolLastRunTimeInitiallyNonOwnerFails() public {
        uint40 blockTime = uint40(block.timestamp);
        vm.startPrank(addr1);
        vm.expectRevert("No permission to set last run time");
        updateWeightRunner.InitialisePoolLastRunTime(address(mockPool), blockTime);
    }

    function testInitialisePoolLastRunTimeOwnerPermFailsAdmin() public {
        uint40 blockTime = uint40(block.timestamp);
        mockPool.setPoolRegistry(8);
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 8);
        vm.stopPrank();
        vm.startPrank(owner);
        vm.expectRevert("ONLYMANAGER");
        updateWeightRunner.InitialisePoolLastRunTime(address(mockPool), blockTime);
    }

    function testInitialisePoolLastRunTimeAdminPermFailsOwner() public {
        uint40 blockTime = uint40(block.timestamp);
        mockPool.setPoolRegistry(16);
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 16);
        vm.stopPrank();
        vm.startPrank(addr2);
        vm.expectRevert("ONLYADMIN");
        updateWeightRunner.InitialisePoolLastRunTime(address(mockPool), blockTime);
    }

    function testInitialisePoolLastRunTimeOwnerPermedSuccess() public {
        uint40 blockTime = uint40(block.timestamp);
        int256[] memory weights = new int256[](4);
        weights[0] = 0.5e18;
        weights[1] = 0.5e18;
        weights[2] = 0;
        weights[3] = 0;
        mockPool.setPoolRegistry(8);
        
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

        mockPool.setPoolRegistry(8);
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 8);
        vm.stopPrank();

        vm.startPrank(address(mockPool));
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
        assertEq(updateWeightRunner.getPoolRuleSettings(address(mockPool)).timingSettings.lastPoolUpdateRun, blockTime);
    }

    function testInitialisePoolLastRunTimeAdminPermedSuccess() public {
        uint40 blockTime = uint40(block.timestamp);

        mockPool.setPoolRegistry(16);
        vm.startPrank(owner);
        updateWeightRunner.setApprovedActionsForPool(address(mockPool), 16);
        vm.stopPrank();
        
        vm.startPrank(owner);
        updateWeightRunner.InitialisePoolLastRunTime(address(mockPool), blockTime);
        vm.stopPrank();
        assertEq(updateWeightRunner.getPoolRuleSettings(address(mockPool)).timingSettings.lastPoolUpdateRun, blockTime);
    }
}
