// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@prb/math/contracts/PRBMathSD59x18.sol";
import "./QuantAMMStorage.sol";
import "./IQuantAMMWeightedPool.sol";
import "./DaoOperations.sol";
import "./UpdateWeightRunner.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
/*
ARCHITECTURE DESIGN NOTES

Most of this functionality could be in the vault contract but it would push the contract size over the limit.

The vault administration contract is responsible for the following:
- setting the protocol trading fee
- setting the protocol trading fee receiving address
- setting the protocol fixed withdrawal fee
- setting the protocol fixed withdrawal fee receiving address
- setting the min and max trading fees for the protocol
- setting the min and max fixed withdrawal fees for the protocol
- setting the non protocol fees being charged by a pool
- diluting a pool

Only fixed addresses of the base and update weight runner are allowed to call these functions.
While there is a small race condition possible during deployment, if someone does come in with a different address all that is required is a redeployment. 


*/
/// @title QuantAMM base administration contract for low frequency, high impact admin calls to the base
/// @notice Responsible for considerable critical setting management. Separated from the base contract due to contract size limits.
contract QuantAMMBaseAdministration is DaoOperations, ScalarQuantAMMBaseStorage, Ownable2Step {
    event TradingFeeSet(address indexed pool, uint16 tradingFee, address feeRecipient);
    event ProtocolTradingFeeSet(uint16 tradingFee, address feeRecipient);
    event MinMaxTradingFeesSet(uint16 minTradingFee, uint16 maxTradingFee);
    event WithdrawalFixedFeeSet(address indexed pool, uint16 withdrawalFixedFee, address feeRecipient);
    event ProtocolWithdrawalFixedFeeSet(uint16 withdrawalFixedFee, address feeRecipient);
    event MinMaxFixedWithdrawalFeesSet(uint16 minBaseFee, uint16 maxBaseFee);
    event PoolDiluted(address indexed poolAddress, uint256 gasInUSD);
    event PoolRegistered(
        address indexed targetPoolAddress,
        bool isCompositePool,
        address[] complianceCheckerTrade,
        address[] complianceCheckerDeposit,
        uint256 numAssets
    );

    address basePool;

    /// @notice Address of the contract that will be allowed to update weights
    address public updateWeightRunner;

    /// @notice Max and min trading fees in BPS, 100% = 10_000
    uint16 public constant maxTradingFee = 10_000;

    /// @notice Min trading fees in BPS, 100% = 10_000
    uint16 public constant minTradingFee = 0;

    /// @notice Max and min fixed withdrawal fees in BPS, 100% = 10_000
    uint16 public constant maxFixedWithdrawalFee = 10_000;

    /// @notice Min fixed withdrawal fees in BPS, 100% = 10_000
    uint16 public constant minFixedWithdrawalFee = 0;

    constructor(address _daoRunner) DaoOperations(_daoRunner) Ownable(msg.sender) {}

    /// @notice one time only call during deployment to set the base pool address
    /// @param _basePoolAddress the address of the base pool
    function setBaseAddress(address _basePoolAddress) public {
        //will be called during deployment
        require(basePool == address(0), "Should never be changed");
        require(_basePoolAddress != address(0), "new base address cannot be default");

        basePool = _basePoolAddress;
    }

    /// @notice one time only call during deployment to set the update weight runner address
    /// @param _updateWeightRunner the address of the update weight runner
    function setUpdateWeightRunnerAddress(address _updateWeightRunner) public onlyOwner{
        require(_updateWeightRunner != address(0), "address cannot be default");
        updateWeightRunner = _updateWeightRunner;
    }

    /// @notice set the pool weights manually as a break glass function
    /// @param _weights the weights to set that sum to 1 and interpolation values
    /// @param _poolAddress the address of the pool to set the weights for
    /// @param _lastInterpolationTimePossible the last time that the weights can be updated given the block multiplier before one weight hits the guardrail
    function setWeightsManually(
        int256[] calldata _weights,
        address _poolAddress,
        uint40 _lastInterpolationTimePossible
    ) public onlyOwner {
        UpdateWeightRunner(updateWeightRunner).setWeightsManually(_weights, _poolAddress, _lastInterpolationTimePossible);
        //event emitted in the update weight runner
    }

    function setIntermediateValuesManually(
        int256[] calldata _movingAverages,
        int256[] calldata _intermediateValues,
        address _poolAddress,
        uint numberOfAssets
    ) public onlyOwner {
        UpdateWeightRunner(updateWeightRunner).setIntermediateValuesManually(_poolAddress, _movingAverages, _intermediateValues, numberOfAssets);
        //event emitted in the update weight runner
    }
}
