// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@prb/math/contracts/PRBMathSD59x18.sol";
import "./QuantAMMStorage.sol";
import "./IQuantAMMWeightedPool.sol";
import "./DaoOperations.sol";
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
contract QuantAMMBaseAdministration is DaoOperations, ScalarQuantAMMBaseStorage {
    event TradingFeeSet(
        address indexed pool,
        uint16 tradingFee,
        address feeRecipient
    );
    event ProtocolTradingFeeSet(uint16 tradingFee, address feeRecipient);
    event MinMaxTradingFeesSet(uint16 minTradingFee, uint16 maxTradingFee);
    event WithdrawalFixedFeeSet(
        address indexed pool,
        uint16 withdrawalFixedFee,
        address feeRecipient
    );
    event ProtocolWithdrawalFixedFeeSet(
        uint16 withdrawalFixedFee,
        address feeRecipient
    );
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
    uint16 public maxTradingFee = 10_000; 

    /// @notice Min trading fees in BPS, 100% = 10_000
    uint16 public minTradingFee = 0; 

    /// @notice Max and min fixed withdrawal fees in BPS, 100% = 10_000
    uint16 public maxFixedWithdrawalFee = 10_000; 

    /// @notice Min fixed withdrawal fees in BPS, 100% = 10_000
    uint16 public minFixedWithdrawalFee = 0; 

    uint256 private constant MASK_POOL_ACTIVE = 1;
    uint256 private constant MASK_POOL_COMPOSITE = 2;
    uint256 private constant MASK_POOL_INDEX = 4;
    uint256 private constant MASK_POOL_COMPLIANCE_TRADE = 8;
    uint256 private constant MASK_POOL_COMPLIANCE_DEPOSIT = 16;
    uint256 private constant MASK_POOL_DAO_WEIGHT_UPDATES = 32;

    constructor(address _daoRunner) DaoOperations(_daoRunner) {
       
    }

    /// @notice one time only call during deployment to set the base pool address
    /// @param _basePoolAddress the address of the base pool
    function setBaseAddress(address _basePoolAddress) public {
        //will be called during deployment
        require(basePool == address(0), "Should never be changed");
        basePool = _basePoolAddress;
    }

    /// @notice one time only call during deployment to set the update weight runner address
    /// @param _updateWeightRunner the address of the update weight runner
    function setUpdateWeightRunnerAddress(address _updateWeightRunner) public {
        //will be called during deployment
        require(updateWeightRunner == address(0), "Should never be changed");
        updateWeightRunner = _updateWeightRunner;
    }
}
