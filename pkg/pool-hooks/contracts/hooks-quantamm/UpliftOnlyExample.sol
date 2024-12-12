// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity >=0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IPermit2 } from "permit2/src/interfaces/IPermit2.sol";

import { IRouterCommon } from "@balancer-labs/v3-interfaces/contracts/vault/IRouterCommon.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import { IWETH } from "@balancer-labs/v3-interfaces/contracts/solidity-utils/misc/IWETH.sol";
import {
    TokenConfig,
    LiquidityManagement,
    HookFlags,
    AddLiquidityKind,
    RemoveLiquidityKind,
    AddLiquidityParams,
    PoolData
} from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { IUpdateWeightRunner } from "@balancer-labs/v3-interfaces/contracts/pool-quantamm/IUpdateWeightRunner.sol";

import { BaseHooks } from "@balancer-labs/v3-vault/contracts/BaseHooks.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";

import { MinimalRouter } from "../MinimalRouter.sol";
import { IVaultExplorer } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultExplorer.sol";
//import { VaultExplorer } from "@balancer-labs/v3-vault/contracts/VaultExplorer.sol";


import {LPNFT} from "./lp_nft.sol";

struct PoolCreationSettings {
    string name;
    string symbol;
    int256[] initialWeights;
    int256[] initialMovingAverages;
    int256[] initialIntermediateValues;
    uint oracleStalenessThreshold;
}

/// @notice Mint an NFT to pool depositors, and charge a decaying exit fee upon withdrawal.
contract UpliftOnlyExample is MinimalRouter, BaseHooks {
    using FixedPoint for uint256;
    
    /// @notice The withdrawal fee in basis points (1/10000) for the pool
    uint16 public immutable withdrawalFeeBps;

    /// @notice The maximum withdrawal fee in basis points (1/10000) for the pool 
    uint16 public immutable withdrawalMaxFeeBps;

    /// @notice The address to send withdrawal fees to
    address public immutable withdrawalFeeRecipient;

    /// @notice The numerator for the withdrawal fee calculation based on the wp definition
    uint32 public immutable withdrawalFeeNumerator;

    /// @notice The fee data for a given owner and deposit
    struct FeeData {
        uint256 tokenID;
        uint256 amount;
        uint256 lpTokenDepositValue;
        uint32 blockIndexDeposit;
        uint16 withdrawalMaxFeeBps;
        uint16 withdrawalFeeBps;
        uint32 withdrawalFeeNumerator;
    }

    /// @notice The LP NFT contract for the pool
    LPNFT public lpNFT;

    /// @notice The fee data for a given owner and deposit
    /// @notice pool => owner => FeeData[]
    mapping(address => mapping(address => FeeData[])) public poolsFeeData;

    // NFT unique identifier.
    uint256 private _nextTokenId;
    
    address private immutable _updateWeightRunner;

    /**
     * @notice A new `NftLiquidityPositionExample` contract has been registered successfully for a given pool.
     * @dev If the registration fails the call will revert, so there will be no event.
     * @param hooksContract This contract
     * @param pool The pool on which the hook was registered
     */
    event NftLiquidityPositionExampleRegistered(address indexed hooksContract, address indexed pool);

    /**
     * @notice An NFT holder withdrew liquidity during the decay period, incurring an exit fee.
     * @param nftHolder The NFT holder who withdrew liquidity in exchange for the NFT
     * @param pool The pool from which the NFT holder withdrew liquidity
     * @param feeToken The address of the token in which the fee was charged
     * @param feeAmount The amount of the fee, in native token decimals
     */
    event ExitFeeCharged(address indexed nftHolder, address indexed pool, IERC20 indexed feeToken, uint256 feeAmount);

    /**
     * @notice Hooks functions called from an external router.
     * @dev This contract inherits both `MinimalRouter` and `BaseHooks`, and functions as is its own router.
     * @param router The address of the Router
     */
    error CannotUseExternalRouter(address router);

    /**
     * @notice The pool does not support adding liquidity through donation.
     * @dev There is an existing similar error (IVaultErrors.DoesNotSupportDonation), but hooks should not throw
     * "Vault" errors.
     */
    error PoolDoesNotSupportDonation();

    /**
     * @notice The pool supports adding unbalanced liquidity.
     * @dev There is an existing similar error (IVaultErrors.DoesNotSupportUnbalancedLiquidity), but hooks should not
     * throw "Vault" errors.
     */
    error PoolSupportsUnbalancedLiquidity();

    /**
     * @notice To avoid Ddos issues, a single depositor can only deposit 100 times
     * 
     */
    error TooManyDeposits();

    /**
     * @notice Attempted withdrawal of an NFT-associated position by an address that is not the owner.
     * @param withdrawer The address attempting to withdraw
     * @param pool The attempted target pool
     * @param nftId The id of the Pool NFT
     */
    error WithdrawalByNonOwner(address withdrawer, address pool, uint256 nftId);


    modifier onlySelfRouter(address router) {
        _ensureSelfRouter(router);
        _;
    }

    constructor(
        IVault vault,
        IWETH weth,
        IPermit2 permit2,
        uint16 _withdrawalFeeBps,
        uint16 _withdrawalMaxFeeBps,
        uint32 _withdrawalFeeNumerator,
        address _updateWeightRunnerParam,
        string memory version,
        string memory name,
        string memory symbol
    ) MinimalRouter(vault, weth, permit2, version) {
         require(
            bytes(name).length > 0 &&
                bytes(symbol).length > 0,
            "NAMEREQ"
        ); //Must provide a name / symbol
        
        lpNFT = new LPNFT(
            name,
            symbol,
            address(vault)
        );

        // solhint-disable-previous-line no-empty-blocks
        withdrawalFeeBps = _withdrawalFeeBps;
        withdrawalMaxFeeBps = _withdrawalMaxFeeBps;
        withdrawalFeeNumerator = _withdrawalFeeNumerator;
        _updateWeightRunner = _updateWeightRunnerParam;

    }

    /***************************************************************************
                                  Router Functions
    ***************************************************************************/

    function addLiquidityProportional(
        address pool,
        uint256[] memory maxAmountsIn,  
        uint256 exactBptAmountOut,
        bool wethIsEth,
        bytes memory userData
    ) external payable saveSender(msg.sender) returns (uint256[] memory amountsIn) {

        if(poolsFeeData[pool][msg.sender].length > 100){
            revert TooManyDeposits();
        }
        // Do addLiquidity operation - BPT is minted to this contract.
        amountsIn = _addLiquidityProportional(
            pool,
            msg.sender,
            address(this),
            maxAmountsIn,
            exactBptAmountOut,
            wethIsEth,
            userData
        );
        
        uint256 tokenID = lpNFT.mint(msg.sender);
        
        int256[] memory prices = IUpdateWeightRunner(_updateWeightRunner).getData(address(this));

        FeeData memory feeDataDeposit = FeeData({
            tokenID: tokenID,
            amount: exactBptAmountOut,
            //this rounding favours the LP 
            lpTokenDepositValue: getPoolLPTokenValue(prices, pool, MULDIRECTION.MULUP),
            blockIndexDeposit: uint32(block.number),
            withdrawalFeeBps: withdrawalFeeBps,
            withdrawalMaxFeeBps: withdrawalMaxFeeBps,
            withdrawalFeeNumerator: withdrawalFeeNumerator
        });

        poolsFeeData[pool][msg.sender].push(feeDataDeposit); 
    }

    function removeLiquidityProportional(
        uint256 tokenId,
        uint256[] memory minAmountsOut,
        bool wethIsEth,
        address pool
    ) external payable saveSender(msg.sender) returns (uint256[] memory amountsOut) {
       
        uint depositLength = poolsFeeData[pool][msg.sender].length;
        if(depositLength > 0){
            revert WithdrawalByNonOwner(msg.sender, pool, tokenId);
        }

        uint256 bptAmountIn;
        for(uint i = 0; i < depositLength; i++){
            if(poolsFeeData[pool][msg.sender][i].tokenID == tokenId){
                bptAmountIn += poolsFeeData[pool][msg.sender][i].amount;
            }
        }

        // Do removeLiquidity operation - tokens sent to msg.sender.
        amountsOut = _removeLiquidityProportional(
            pool,
            address(this),
            msg.sender,
            bptAmountIn,
            minAmountsOut,
            wethIsEth,
            abi.encode(tokenId) // tokenId is passed to index fee data in hook
        );
    }

    /***************************************************************************
                                  Hook Functions
    ***************************************************************************/

    /// @inheritdoc BaseHooks
    function onRegister(
        address,
        address pool,
        TokenConfig[] memory,
        LiquidityManagement calldata liquidityManagement
    ) public override onlyVault returns (bool) {
        // This hook requires donation support to work (see above).
        if (liquidityManagement.enableDonation == false) {
            revert PoolDoesNotSupportDonation();
        }
        if (liquidityManagement.disableUnbalancedLiquidity == false) {
            revert PoolSupportsUnbalancedLiquidity();
        }

        emit NftLiquidityPositionExampleRegistered(address(this), pool);

        return true;
    }

    /// @inheritdoc BaseHooks
    function getHookFlags() public pure override returns (HookFlags memory) {
        HookFlags memory hookFlags;
        // `enableHookAdjustedAmounts` must be true for all contracts that modify the `amountCalculated`
        // in after hooks. Otherwise, the Vault will ignore any "hookAdjusted" amounts, and the transaction
        // might not settle. (It should be false if the after hooks do something else.)
        hookFlags.enableHookAdjustedAmounts = true;
        hookFlags.shouldCallBeforeAddLiquidity = true;
        hookFlags.shouldCallAfterRemoveLiquidity = true;
        return hookFlags;
    }

    /// @inheritdoc BaseHooks
    function onBeforeAddLiquidity(
        address router,
        address,
        AddLiquidityKind,
        uint256[] memory,
        uint256,
        uint256[] memory,
        bytes memory
    ) public view override onlySelfRouter(router) returns (bool) {
        // We only allow addLiquidity via the Router/Hook itself (as it must custody BPT).
        return true;
    }

    function _takeFee(
        address nftHolder,
        address pool,
        uint256[] memory amountsOutRaw,
        uint256 currentFee
    ) private returns (uint256[] memory hookAdjustedAmountsOutRaw) {
        hookAdjustedAmountsOutRaw = amountsOutRaw;
        IERC20[] memory tokens = _vault.getPoolTokens(pool);
        uint256[] memory accruedFees = new uint256[](tokens.length);
        // Charge fees proportional to the `amountOut` of each token.
        for (uint256 i = 0; i < amountsOutRaw.length; i++) {
            uint256 exitFee = amountsOutRaw[i].mulDown(currentFee);
            accruedFees[i] = exitFee;
            hookAdjustedAmountsOutRaw[i] -= exitFee;
            // Fees don't need to be transferred to the hook, because donation will redeposit them in the Vault.
            // In effect, we will transfer a reduced amount of tokensOut to the caller, and leave the remainder
            // in the pool balance.

            emit ExitFeeCharged(nftHolder, pool, tokens[i], exitFee);
        }

        // Donates accrued fees back to LPs.
        _vault.addLiquidity(
            AddLiquidityParams({
                pool: pool,
                to: msg.sender, // It would mint BPTs to router, but it's a donation so no BPT is minted
                maxAmountsIn: accruedFees, // Donate all accrued fees back to the pool (i.e. to the LPs)
                minBptAmountOut: 0, // Donation does not return BPTs, any number above 0 will revert
                kind: AddLiquidityKind.DONATION,
                userData: bytes("") // User data is not used by donation, so we can set it to an empty string
            })
        );
    }

    /// @inheritdoc BaseHooks
    function onAfterRemoveLiquidity(
        address router,
        address pool,
        RemoveLiquidityKind,
        uint256 bptAmountIn,
        uint256[] memory,
        uint256[] memory amountsOutRaw,
        uint256[] memory,
        bytes memory 
    ) public override onlySelfRouter(router) returns (bool, uint256[] memory hookAdjustedAmountsOutRaw) {
        // We only allow removeLiquidity via the Router/Hook itself so that fee is applied correctly.
        uint256 feeAmount;
        hookAdjustedAmountsOutRaw = amountsOutRaw;

        int256[] memory prices = IUpdateWeightRunner(_updateWeightRunner).getData(address(this));
        // in base currency (e.g. USD)

        //this rounding favours the LP 
        uint256 lpTokenDepositValueNow = getPoolLPTokenValue(prices, pool, MULDIRECTION.MULDOWN);
        FeeData[] storage feeDataArray = poolsFeeData[pool][msg.sender];
        uint256 feeDataArrayLength = feeDataArray.length;
        uint256 amountLeft = bptAmountIn;

        for (uint256 i; i < feeDataArrayLength; ++i) {
            int256 lpTokenDepositValueChange = int256(lpTokenDepositValueNow) -
                int256(feeDataArray[i].lpTokenDepositValue);
            uint256 feePerLP;

            // if the pool has increased in value since the deposit, the fee is calculated based on the deposit value
            if (lpTokenDepositValueChange > 0) {
                feePerLP =
                    (calculateFeeBps(
                        feeDataArray[i].withdrawalMaxFeeBps,
                        feeDataArray[i].withdrawalFeeBps,
                        block.number - feeDataArray[i].blockIndexDeposit,
                        feeDataArray[i].withdrawalFeeNumerator
                    ) * uint256(lpTokenDepositValueChange)) /
                    10000;
            }

            // if the pool has decreased in value since the deposit, the fee is calculated based on the base value - see wp
            else {
                feePerLP =
                    (calculateFeeBps(
                        feeDataArray[i].withdrawalMaxFeeBps,
                        feeDataArray[i].withdrawalFeeBps,
                        block.number - feeDataArray[i].blockIndexDeposit,
                        feeDataArray[i].withdrawalFeeNumerator
                    ) * lpTokenDepositValueNow) /
                    10000;
            }

            // if the deposit is less than the amount left to burn, burn the whole deposit and move on to the next
            if (feeDataArray[i].amount <= amountLeft) {
                uint256 depositAmount = feeDataArray[i].amount;
                feeAmount +=
                    (feePerLP * depositAmount) /
                    feeDataArray[i].lpTokenDepositValue;
                amountLeft -= feeDataArray[i].amount;
                lpNFT.burn(feeDataArray[i].tokenID);
                if (amountLeft == 0) {
                    break;
                }
            } else {
                feeDataArray[i].amount -= amountLeft;
                feeAmount +=
                    (feePerLP * amountLeft) /
                    feeDataArray[i].lpTokenDepositValue;
                break;
            }
        }

        feeAmount = FixedPoint.divDown(feeAmount, bptAmountIn);

        hookAdjustedAmountsOutRaw = _takeFee(msg.sender, pool, amountsOutRaw, feeAmount);

        return (true, hookAdjustedAmountsOutRaw);
    }


    /// @param _from the owner to transfer from
    /// @param _to the owner to transfer to
    /// @param _tokenID the token ID to transfer
    /// @notice aftertokentransfer is called by mint/burn and transfer however override checks that this is only called on transfer
    function afterTokenTransfer(
        address _from,
        address _to,
        uint256 _tokenID
    ) public {
        require(msg.sender == address(lpNFT), "ONLYNFT");
        int256[] memory prices = updateWeightRunner.getData(address(this));
        uint256 lpTokenDepositValueNow = getPoolLPTokenValue(prices);
        FeeData[] storage feeDataArray = feeData[_from];
        uint256 feeDataArrayLength = feeDataArray.length;
        for (uint256 i; i < feeDataArrayLength; ++i) {
            if (feeDataArray[i].tokenID == _tokenID) {
                // Update the deposit value to the current value of the pool in base currency (e.g. USD) and the block index to the current block number    
                vault.transferLPTokens(_from, _to, feeDataArray[i].amount);
                feeDataArray[i].lpTokenDepositValue = lpTokenDepositValueNow;
                feeDataArray[i].blockIndexDeposit = uint32(block.number);
                feeDataArray[i].withdrawalFeeBps = withdrawalFeeBps;
                feeDataArray[i].withdrawalMaxFeeBps = withdrawalMaxFeeBps;
                feeDataArray[i].withdrawalFeeNumerator = withdrawalFeeNumerator;
                if (_to != address(0)) {
                    // Don't push when burning
                    feeData[_to].push(feeDataArray[i]);
                }
                //replaced the burned with the last therefore can pop
                feeDataArray[i] = feeDataArray[feeDataArrayLength - 1];
                feeDataArray.pop();
                break;
            }
        }

    /***************************************************************************
                                Off-chain Getters
    ***************************************************************************/

    /// @param _maxFeeBps the maximum fees that can be charged in basis points (1/10000)
    /// @param _baseFeeBps the base fees that can be charged in basis points (1/10000)
    /// @param _denominator the denominator for the fee calculation - see wp
    /// @param _numerator the numerator for the fee calculation - see wp
    function calculateFeeBps(
        uint256 _maxFeeBps,
        uint256 _baseFeeBps,
        uint256 _denominator,
        uint256 _numerator
    ) private pure returns (uint256) {
        require(_denominator != 0);
        
        uint256 calculatedFee = _baseFeeBps + (_numerator * 10_000) / _denominator;

        if (calculatedFee >= _maxFeeBps) {
            return _maxFeeBps;
        }

        uint256 closenessToBaseBps = calculatedFee - _baseFeeBps;

        if (closenessToBaseBps <= 10) {
            return _baseFeeBps;
        }

        return calculatedFee;
    }

    enum MULDIRECTION {
        MULUP,
        MULDOWN
    }
    /// @notice gets the notional value of the lp token in USD
    /// @param _prices the prices of the assets in the pool
    function getPoolLPTokenValue(
        int256[] memory _prices,
        address pool,
        MULDIRECTION _direction
    ) public view returns (uint256) {
        uint256 poolValueInUSD;

        //PoolData memory poolData = VaultExplorer(address(_vault)).getPoolData(pool);
        PoolData memory poolData = IVaultExplorer(address(_vault)).getPoolData(pool);
        
        uint256 poolTotalSupply = _vault.totalSupply(address(this));

        for (uint i; i < poolData.tokens.length; ) {
            if(_direction == MULDIRECTION.MULUP) {
                poolValueInUSD += FixedPoint.mulUp(uint256(_prices[i]), poolData.balancesLiveScaled18[i]);
            } else {
                poolValueInUSD += FixedPoint.mulDown(uint256(_prices[i]), poolData.balancesLiveScaled18[i]);
            }

            unchecked {
                ++i;
            }
        }

        return poolValueInUSD / poolTotalSupply;
    }

    // Internal Functions

    function _ensureSelfRouter(address router) private view {
        if (router != address(this)) {
            revert CannotUseExternalRouter(router);
        }
    }
}
