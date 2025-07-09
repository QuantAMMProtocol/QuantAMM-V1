// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity >=0.8.24;

import {
    IWeightedPool,
    WeightedPoolDynamicData,
    WeightedPoolImmutableData
} from "@balancer-labs/v3-interfaces/contracts/pool-weighted/IWeightedPool.sol";
import { ISwapFeePercentageBounds } from "@balancer-labs/v3-interfaces/contracts/vault/ISwapFeePercentageBounds.sol";
import {
    IUnbalancedLiquidityInvariantRatioBounds
} from "@balancer-labs/v3-interfaces/contracts/vault/IUnbalancedLiquidityInvariantRatioBounds.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import { IVaultErrors } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultErrors.sol";
import {
    SwapKind,
    PoolSwapParams,
    PoolConfig,
    Rounding
} from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import { IBasePool } from "@balancer-labs/v3-interfaces/contracts/vault/IBasePool.sol";

import { VaultGuard } from "@balancer-labs/v3-vault/contracts/VaultGuard.sol";
import { BalancerPoolToken } from "@balancer-labs/v3-vault/contracts/BalancerPoolToken.sol";
import { PoolInfo } from "@balancer-labs/v3-pool-utils/contracts/PoolInfo.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { WeightedMath } from "@balancer-labs/v3-solidity-utils/contracts/math/WeightedMath.sol";
import { Version } from "@balancer-labs/v3-solidity-utils/contracts/helpers/Version.sol";
//CODEHAWKS INFO /s/703 remove dupe import
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IUpdateRule } from "@balancer-labs/v3-interfaces/contracts/pool-quantamm/IUpdateRule.sol"; // Ensure this path is correct
import { IQuantAMMWeightedPool } from "@balancer-labs/v3-interfaces/contracts/pool-quantamm/IQuantAMMWeightedPool.sol";
import { ScalarQuantAMMBaseStorage } from "./QuantAMMStorage.sol";
import { UpdateWeightRunner } from "./UpdateWeightRunner.sol";
import "@prb/math/contracts/PRBMathSD59x18.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { QuantAMMWeightedPoolFactory } from "./QuantAMMWeightedPoolFactory.sol";

/**
 * @notice QuantAMM Base Weighted pool. One per pool.
 * @dev QuantAMM pools are in effect more advanced managed pools. They are fixed to run with the QuantAMM UpdateWeightRunner.
 *
 * UpdateWeightRunner is reponsible for running automated strategies that determine weight changes in QuantAMM pools.
 * Given that all the logic is in update weight runner, setWeights is the fundamental access point between the two.
 *
 * QuantAMM weighted pools define the last set weight time and weight and a block multiplier.
 *
 * This block multiplier is used to interpolate between the last set weight and the current weight for a given block.
 *
 * Older mechanisms defined a target weight and a target block index. Like this by storing times instead of weights
 * we save on SLOADs during weight calculations. It also allows more nuanced weight changes where you carry on a vector
 * until you either hit a guard rail or call a new setWeight.
 *
 * Fees for these pools are set in hooks.
 *
 * Pool Registration will be gated by the QuantAMM team to begin with for security reasons.
 *
 * At any given block the pool is a fixed weighted balancer pool.
 *
 * We store weights differently to the standard balancer pool. We store them as a 32 bit int, with the first 16 bits being the weight
 * and the second 16 bits being the block multiplier. This allows us to store 8 weights in a single 256 bit int.
 * Changing to a less precise storage has been shown in simulations to have a negligible impact on overall performance of the strategy
 * while drastically reducing the gas cost.
 *
 */
contract QuantAMMWeightedPool is
    IQuantAMMWeightedPool,
    IBasePool,
    BalancerPoolToken,
    PoolInfo,
    Version,
    Initializable
{
    using FixedPoint for uint256;

    // Fees are 18-decimal, floating point values, which will be stored in the Vault using 24 bits.
    // This means they have 0.00001% resolution (i.e., any non-zero bits < 1e11 will cause precision loss).
    // Minimum values help make the math well-behaved (i.e., the swap fee should overwhelm any rounding error).
    // Maximum values protect users by preventing permissioned actors from setting excessively high swap fees.
    uint256 private constant _MIN_SWAP_FEE_PERCENTAGE = 0.001e16; // 0.001%
    uint256 private constant _MAX_SWAP_FEE_PERCENTAGE = 10e16; // 10%
    uint256 private constant _FIX_WINDOW = 3 * 365 * 24 * 60 * 60;

    uint256 private immutable _totalTokens;

    ///@dev First elem = category, second elem is name, third variable type, fourth elem detail
    string[][] private poolDetails;

    int256[] internal _weights;
    int256[] internal _multipliers;

    UpdateWeightRunner public updateWeightRunner;

    uint256 public immutable deploymentTime;
    address internal immutable quantammAdmin;

    /// @notice the pool settings for getting weights and assets keyed by pool
    QuantAMMBaseGetWeightData poolSettings;

    /// @notice the pool settings for setting weights keyed by pool
    /// @param name The name of the pool
    /// @param symbol The symbol of the pool
    /// @param numTokens The number of tokens in the pool
    /// @param version The version of the pool
    /// @param updateWeightRunner The address of the update weight runner
    /// @param poolRegistry The settings of admin functionality of pools
    /// @param poolDetails The details of the pool. dynamic user driven descriptive data
    struct NewPoolParams {
        string name;
        string symbol;
        uint256 numTokens;
        string version;
        address updateWeightRunner;
        uint256 poolRegistry;
        string[][] poolDetails;
    }

    ///@dev Emitted when the weights of the pool are updated
    /// @notice The information regarding the weight update. A second event is sent with finalised weights from the updateWeightRunner with precisions used for trading.
    /// @param poolAddress The address of the pool
    /// @param calculatedWeightsAndMultipliers The weights and multipliers submitted to be saved. These are in 18dp. Trade precision is in 9dp.
    /// @param lastInterpolationTimePossible The last time the weights can be interpolated
    /// @param lastUpdateTime The last time the weights were updated
    event WeightsUpdated(address indexed poolAddress, int256[] calculatedWeightsAndMultipliers, uint40 lastInterpolationTimePossible, uint40 lastUpdateTime);

    /// @notice Emitted when the update weight runner is updated. This is during break glass situations.
    /// @param oldAddress The old address of the update weight runner
    /// @param newAddress The new address of the update weight runner
    event UpdateWeightRunnerAddressUpdated(address indexed oldAddress, address indexed newAddress);

    /// @notice Emitted when the pool is set in the update weight runner
    /// @param rule The rule to use for the pool
    /// @param poolOracles The oracles to use for the pool. [asset oracle][backup oracles for that asset]
    /// @param lambda The decay parameter for the rule
    /// @param ruleParameters The parameters for the rule
    /// @param epsilonMax The parameter that controls maximum allowed delta for a weight update
    /// @param absoluteWeightGuardRail The parameter that controls minimum allowed absolute weight allowed
    /// @param updateInterval The time between updates
    /// @param poolManager The address of the pool manager
    /// @param creatorAddress The address of the creator of the pool
    event PoolRuleSet(
        address rule,
        address[][] poolOracles,
        uint64[] lambda,
        int256[][] ruleParameters,
        uint64 epsilonMax,
        uint64 absoluteWeightGuardRail,
        uint40 updateInterval,
        address poolManager,
        address creatorAddress
    );


    /// @dev Indicates that the maximum allowed trade size has been exceeded.
    error maxTradeSizeRatioExceeded();

    /**
     * @notice `getRate` from `IRateProvider` was called on a Weighted Pool.
     * @dev It is not safe to nest Weighted Pools as WITH_RATE tokens in other pools, where they function as their own
     * rate provider. The default `getRate` implementation from `BalancerPoolToken` computes the BPT rate using the
     * invariant, which has a non-trivial (and non-linear) error. Without the ability to specify a rounding direction,
     * the rate could be manipulable.
     *
     * It is fine to nest Weighted Pools as STANDARD tokens, or to use them with external rate providers that are
     * stable and have at most 1 wei of rounding error (e.g., oracle-based).
     */
    error WeightedPoolBptRateUnsupported();

    ///@dev The parameters for the rule, validated in each rule separately during set rule
    int256[][] public ruleParameters;

    ///@dev Decay parameter for exponentially-weighted moving average (0 < λ < 1)
    uint64[] public lambda;

    ///@dev Maximum allowed delta for a weight update, stored as SD59x18 number
    uint64 public epsilonMax; // Maximum allowed delta for a weight update, stored as SD59x18 number

    ///@dev Minimum absolute weight allowed. CODEHAWKS INFO /s/611
    uint64 public absoluteWeightGuardRail;

    ///@dev maximum trade size allowed as a fraction of the pool
    uint256 internal maxTradeSizeRatio;

    ///@dev Minimum amount of seconds between two updates
    uint64 public updateInterval;

    ///@dev the maximum amount of time that an oracle an be stale.
    uint oracleStalenessThreshold;

    ///@dev the admin functionality enabled for this pool.
    uint256 public immutable poolRegistry;

    constructor(
        NewPoolParams memory params,
        IVault vault
    ) BalancerPoolToken(vault, params.name, params.symbol) PoolInfo(vault) Version(params.version) {
        _totalTokens = params.numTokens;
        updateWeightRunner = UpdateWeightRunner(params.updateWeightRunner);
        quantammAdmin = updateWeightRunner.quantammAdmin();
        deploymentTime = block.timestamp;

        poolRegistry = params.poolRegistry;
        poolDetails = params.poolDetails;
    }

    /// @inheritdoc IBasePool
    function computeBalance(
        uint256[] memory balancesLiveScaled18,
        uint256 tokenInIndex,
        uint256 invariantRatio
    ) external view returns (uint256 newBalance) {
        uint40 multiplierTime = uint40(block.timestamp);
        //CODEHAWKS INFO /s/234
        InteropDetails memory variables = poolSettings.interopDetails;

        if (block.timestamp >= variables.lastInteropTime) {
            //we have gone beyond the first variable hitting the guard rail. We cannot interpolate any further and an update is needed
            multiplierTime = variables.lastInteropTime;
        }

        //CODEHAWKS INFO /s/4
        //Lifted outside of unchecked in case of race condition of combined bad user setting last update in the future and chain downtime
        uint256 timeSinceLastUpdate = uint256(
            multiplierTime - variables.lastUpdateTime
        );

        unchecked {
            return
                WeightedMath.computeBalanceOutGivenInvariant(
                    balancesLiveScaled18[tokenInIndex],
                    _getNormalizedWeight(tokenInIndex, timeSinceLastUpdate),
                    invariantRatio
                );
        }
    }

    /// @inheritdoc IQuantAMMWeightedPool
    function getPoolDetail(string memory category, string memory name) external view returns (string memory, string memory) {
        for(uint i = 0; i < poolDetails.length; i++){
            string[] memory detail = poolDetails[i];
            if(keccak256(abi.encodePacked(detail[0])) == keccak256(abi.encodePacked(category)) 
                && keccak256(abi.encodePacked(detail[1])) == keccak256(abi.encodePacked(name))){
                return (detail[2], detail[3]);
            }
        }
        
        return ("", "");
    }

    /// @inheritdoc IBasePool
    function computeInvariant(uint256[] memory balancesLiveScaled18, Rounding rounding) public view returns (uint256) {
        function(uint256[] memory, uint256[] memory) internal pure returns (uint256) _upOrDown = rounding ==
            Rounding.ROUND_UP
            ? WeightedMath.computeInvariantUp
            : WeightedMath.computeInvariantDown;

        return _upOrDown(_getNormalizedWeights(), balancesLiveScaled18);
    }

    /// @inheritdoc IQuantAMMWeightedPool
    function getNormalizedWeights() external view returns (uint256[] memory) {
        return _getNormalizedWeights();
    }

    /// @inheritdoc IBasePool
    function onSwap(PoolSwapParams memory request) public view onlyVault returns (uint256) {
        InteropDetails memory variables = poolSettings.interopDetails;

        uint256 tokenInWeight;
        uint256 tokenOutWeight;
        uint40 multiplierTime = uint40(block.timestamp);

        if (block.timestamp >= variables.lastInteropTime) {
            //we have gone beyond the first variable hitting the guard rail. We cannot interpolate any further and an update is needed
            multiplierTime = variables.lastInteropTime;
        }

        uint256 timeSinceLastUpdate = uint256(multiplierTime - variables.lastUpdateTime);

        tokenInWeight = _getNormalizedWeight(request.indexIn, timeSinceLastUpdate);
        tokenOutWeight = _getNormalizedWeight(request.indexOut, timeSinceLastUpdate);

       
        if (request.kind == SwapKind.EXACT_IN) {            
            if (request.amountGivenScaled18 > request.balancesScaled18[request.indexIn].mulDown(maxTradeSizeRatio)) {
                revert maxTradeSizeRatioExceeded();
            }

            uint256 amountOutScaled18 = WeightedMath.computeOutGivenExactIn(
                request.balancesScaled18[request.indexIn],
                tokenInWeight,
                request.balancesScaled18[request.indexOut],
                tokenOutWeight,
                request.amountGivenScaled18
            );
            //CODEHAWKS M-09 check amountOUTScaled18 
            if (amountOutScaled18 > request.balancesScaled18[request.indexOut].mulDown(maxTradeSizeRatio)) {
                revert maxTradeSizeRatioExceeded();
            }

            return amountOutScaled18;
        } else {
            // Cannot exceed maximum out ratio
            if (request.amountGivenScaled18 > request.balancesScaled18[request.indexOut].mulDown(maxTradeSizeRatio)) {
                revert maxTradeSizeRatioExceeded();
            }

            uint256 amountInScaled18 = WeightedMath.computeInGivenExactOut(
                request.balancesScaled18[request.indexIn],
                tokenInWeight,
                request.balancesScaled18[request.indexOut],
                tokenOutWeight,
                request.amountGivenScaled18
            );

            //CODEHAWKS M-09 check amountInScaled18 
            if (amountInScaled18 > request.balancesScaled18[request.indexIn].mulDown(maxTradeSizeRatio)) {
                revert maxTradeSizeRatioExceeded();
            }

            // Fees are added after scaling happens, to reduce the complexity of the rounding direction analysis.
            return amountInScaled18;
        }
    }

    struct QuantAMMNormalisedTokenPair {
        uint256 firstTokenWeight;
        uint256 secondTokenWeight;
    }

    function _calculateCurrentBlockWeight(
        int256 weight,
        int256 multiplier,
        uint256 timeSinceLastUpdate
    ) internal pure returns (uint256) {
        unchecked {
            //multiplier is always below 1 which is int128, we multiply by 1e18 for rounding as muldown / 1e18 at the end.
            int256 multiplierScaled18 = multiplier * 1e18;
            if (multiplier > 0) {
                return uint256(weight) + FixedPoint.mulDown(uint256(multiplierScaled18), timeSinceLastUpdate);
            } else {
                //CYFRIN H02
                //CODEHAWKS /s/866,542
                return uint256(weight) - FixedPoint.mulDown(uint256(-multiplierScaled18), timeSinceLastUpdate);
            }
        }
    }

    /// @notice Gets the normalised weight for a token
    /// @param tokenIndex The index of the token
    /// @param timeSinceLastUpdate The time since the last update
    function _getNormalizedWeight(
        uint256 tokenIndex,
        uint256 timeSinceLastUpdate
    ) internal view virtual returns (uint256) {
        return
            _calculateCurrentBlockWeight(
                _weights[tokenIndex],
                _multipliers[tokenIndex],
                timeSinceLastUpdate
            );
    }

    /// @notice gets the normalised weights for the pool
    function _getNormalizedWeights() internal view virtual returns (uint256[] memory) {
        uint256 totalTokens = _totalTokens;
        uint256[] memory normalizedWeights = new uint256[](totalTokens);

        uint40 multiplierTime = uint40(block.timestamp);
        uint40 lastInterpolationTime = poolSettings.interopDetails.lastInteropTime;

        if (block.timestamp >= lastInterpolationTime) {
            //we have gone beyond the first variable hitting the guard rail. We cannot interpolate any further and an update is needed
            multiplierTime = lastInterpolationTime;
        }

        uint256 timeSinceLastUpdate = uint256(
            multiplierTime - poolSettings.interopDetails.lastUpdateTime
        );

        unchecked {
            for(uint256 i = 0; i < totalTokens; i++) {
                normalizedWeights[i] = _getNormalizedWeight(i, timeSinceLastUpdate);
            }
        }
        return normalizedWeights;
    }

    /// @notice Calculate the normalised weight for a token
    /// @param weight The weight of the token
    /// @param multiplier The multiplier for the token
    /// @param timeSinceLastUpdate The time since the last update
    function calculateBlockNormalisedWeight(
        int256 weight,
        int256 multiplier,
        uint256 timeSinceLastUpdate
    ) internal pure returns (uint256) {
        
    }

    /// @inheritdoc ISwapFeePercentageBounds
    function getMinimumSwapFeePercentage() external pure returns (uint256) {
        return _MIN_SWAP_FEE_PERCENTAGE;
    }

    /// @inheritdoc ISwapFeePercentageBounds
    function getMaximumSwapFeePercentage() external pure returns (uint256) {
        return _MAX_SWAP_FEE_PERCENTAGE;
    }

    /// @inheritdoc IUnbalancedLiquidityInvariantRatioBounds
    function getMinimumInvariantRatio() external pure returns (uint256) {
        return WeightedMath._MIN_INVARIANT_RATIO;
    }

    /// @inheritdoc IUnbalancedLiquidityInvariantRatioBounds
    function getMaximumInvariantRatio() external pure returns (uint256) {
        return WeightedMath._MAX_INVARIANT_RATIO;
    }

    /// @inheritdoc IQuantAMMWeightedPool
    function getQuantAMMWeightedPoolDynamicData() external view returns (QuantAMMWeightedPoolDynamicData memory data) {
        data.balancesLiveScaled18 = _vault.getCurrentLiveBalances(address(this));
        (, data.tokenRates) = _vault.getPoolTokenRates(address(this));
        data.totalSupply = totalSupply();

        PoolConfig memory poolConfig = _vault.getPoolConfig(address(this));
        data.isPoolInitialized = poolConfig.isPoolInitialized;
        data.isPoolPaused = poolConfig.isPoolPaused;
        data.isPoolInRecoveryMode = poolConfig.isPoolInRecoveryMode;
         uint256 N = _weights.length;

        int256[] memory firstFour = new int256[](8);
        int256[] memory secondFour = new int256[](8);

        // —— Case 1: N ≤ 4 —— 
        if (N <= 4) {
            // Pack weights at [0..N-1], multipliers at [N..2N-1]
            for (uint256 i = 0; i < N; i++) {
                firstFour[i]     = _weights[i];
                firstFour[i + N] = _multipliers[i];
            }
        }
        else{

            // —— Case 2: N > 4 —— 
            // firstFour = 4 weights, then 4 multipliers
            for (uint256 i = 0; i < 4; i++) {
                firstFour[i]     = _weights[i];
                firstFour[i + 4] = _multipliers[i];
            }

            // secondFour: we have `secondCount = N-4` tokens here
            uint256 secondCount = N - 4;
            // pack next weights [4..N-1] into secondFour[0..secondCount-1]
            // and their multipliers into secondFour[secondCount..secondCount*2-1]
            for (uint256 i = 0; i < secondCount; i++) {
                secondFour[i]               = _weights[4 + i];
                secondFour[i + secondCount] = _multipliers[4 + i];
            }
        }

        data.firstFourWeightsAndMultipliers = firstFour;
        data.secondFourWeightsAndMultipliers = secondFour;

        //just a get but still more efficient to do it here
        InteropDetails memory interpolationDetails = poolSettings.interopDetails;
        data.lastUpdateTime = interpolationDetails.lastUpdateTime;
        data.lastInteropTime = interpolationDetails.lastInteropTime;
    }

    /// @inheritdoc IQuantAMMWeightedPool
    function getQuantAMMWeightedPoolImmutableData()
        external
        view
        returns (QuantAMMWeightedPoolImmutableData memory data)
    {
        data.tokens = _vault.getPoolTokens(address(this));
        data.oracleStalenessThreshold = oracleStalenessThreshold;
        data.poolRegistry = poolRegistry;
        data.ruleParameters = ruleParameters;
        data.lambda = lambda;
        data.epsilonMax = epsilonMax;
        data.absoluteWeightGuardRail = absoluteWeightGuardRail;
        data.maxTradeSizeRatio = maxTradeSizeRatio;
        data.updateInterval = updateInterval;
    }

    function getWithinFixWindow() external override view returns (bool) {
        return block.timestamp - deploymentTime < _FIX_WINDOW;
    }

    /// @notice the main function to update target weights and multipliers from the update weight runner
    /// @param _inputweights the target weights and their block multipliers
    /// @param _address the target pool address
    /// @param _lastInteropTime the last time the weights can be interpolated
    function setWeights(
        int256[] calldata _inputweights,
        address _address,
        uint40 _lastInteropTime
    ) external override {
        uint256 totalTokens = _totalTokens;
        require(msg.sender == address(updateWeightRunner), "XUR");
        require(_inputweights.length == totalTokens * 2, "WD"); //weight length different

        for(uint256 i = 0; i < totalTokens; i++) {
            _weights[i] = _inputweights[i];
            _multipliers[i] = _inputweights[i + totalTokens];
        }

        //struct allows one SSTORE
        poolSettings.interopDetails = InteropDetails({
            lastInteropTime: _lastInteropTime,
            lastUpdateTime: uint40(block.timestamp)
        });

        emit WeightsUpdated(_address, _inputweights, _lastInteropTime, uint40(block.timestamp));
    }

    /// @notice the initialising function during registration of the pool with the vault to set the initial weights
    /// @param _inputWeights the target weights
    function _setInitialWeights(int256[] memory _inputWeights) internal {
        require(_weights.length == 0, "init");

        _weights = new int256[](_inputWeights.length);
        _multipliers = new int256[](_inputWeights.length);

        for (uint i; i < _inputWeights.length; ) {
            _weights[i] = _inputWeights[i];
            _multipliers[i] = int256(0);

            unchecked {
                ++i;
            }
        }

        //struct allows one SSTORE
        poolSettings.interopDetails = InteropDetails({
            lastInteropTime: uint40(block.timestamp), //given muliplier is 0 on start
            lastUpdateTime: uint40(block.timestamp)
        });

        //CODEHAWKS L-05 emit weights and multiplier
        emit WeightsUpdated(address(this), _inputWeights, uint40(block.timestamp), uint40(block.timestamp));
    }

    /// @notice Initialize the pool
    /// @param params parameters defined by the factory
    function initialize(
        QuantAMMWeightedPoolFactory.CreationNewPoolParams memory params
    ) public initializer {        
        oracleStalenessThreshold = params._oracleStalenessThreshold;
        updateInterval = params._poolSettings.updateInterval;
        _setRule(params);

        _setInitialWeights(params._initialWeights);

        //CODEHAWKS L-09 emit during creation rather than setruleforpool with creator address also
        // emit event for easier tracking of rule changes
        emit PoolRuleSet(
            address(params._poolSettings.rule),
            params._poolSettings.oracles,
            params._poolSettings.lambda,
            params._poolSettings.ruleParameters,
            params._poolSettings.epsilonMax,
            params._poolSettings.absoluteWeightGuardRail,
            params._poolSettings.updateInterval,
            params._poolSettings.poolManager,
            msg.sender //this should be the factory and only factory sent creations should be listened to.
        );
    }

    /// @notice Set the rule for this pool
    /// @param params parameters defined by the factory creation process
    function _setRule(
        QuantAMMWeightedPoolFactory.CreationNewPoolParams memory params
    ) internal {
        lambda = params._poolSettings.lambda;
        epsilonMax = params._poolSettings.epsilonMax;
        absoluteWeightGuardRail = params._poolSettings.absoluteWeightGuardRail;
        maxTradeSizeRatio = params._poolSettings.maxTradeSizeRatio;

        ruleParameters = params._poolSettings.ruleParameters;

        params._poolSettings.rule.initialisePoolRuleIntermediateValues(
            address(this),
            params._initialMovingAverages,
            params._initialIntermediateValues,
            params._initialWeights.length
        );

        updateWeightRunner.setRuleForPool(params._poolSettings);
    }

    /// @inheritdoc IQuantAMMWeightedPool
    function getOracleStalenessThreshold() external view override returns (uint) {
        return oracleStalenessThreshold;
    }

    /// @inheritdoc IQuantAMMWeightedPool
    function setUpdateWeightRunnerAddress(address _updateWeightRunner) external override {
        require(msg.sender == quantammAdmin, "XAD");

        require(
            block.timestamp - deploymentTime < _FIX_WINDOW,
            "XIM"
        );

        address oldAddress = address(updateWeightRunner);

        updateWeightRunner = UpdateWeightRunner(_updateWeightRunner);
        //CODEHAWKS L-04
        emit UpdateWeightRunnerAddressUpdated(oldAddress, _updateWeightRunner);
    }

    function getRate() public pure override returns (uint256) {
        revert WeightedPoolBptRateUnsupported();
    }
}
