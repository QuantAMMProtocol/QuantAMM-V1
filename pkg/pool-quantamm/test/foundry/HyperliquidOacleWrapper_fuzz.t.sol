// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

// Adjust this path if your contract lives elsewhere in your repo:
import "../../contracts/HyperliquidSpotOracle.sol";

import { OracleWrapper } from "@balancer-labs/v3-interfaces/contracts/pool-quantamm/OracleWrapper.sol";
import {
    HyperSpotPricePrecompile
} from "@balancer-labs/v3-standalone-utils/contracts/utils/HyperSpotPricePrecompile.sol";
import {
    HyperTokenInfoPrecompile
} from "@balancer-labs/v3-standalone-utils/contracts/utils/HyperTokenInfoPrecompile.sol";

/// ======= Minimal precompile mocks etched at the canonical addresses =======

contract MockSpotPricePrecompile {
    mapping(uint32 => uint256) public prices;
    bool public forceFail;

    function setPrice(uint32 pairIndex, uint256 price) external {
        prices[pairIndex] = price;
    }

    function setFail(bool shouldFail) external {
        forceFail = shouldFail;
    }

    fallback() external {
        if (forceFail) {
            assembly {
                revert(0, 0)
            }
        }
        uint32 pairIndex = abi.decode(msg.data, (uint32));
        uint256 p = prices[pairIndex];
        bytes memory out = abi.encode(p);
        assembly {
            return(add(out, 32), mload(out))
        }
    }
}

contract MockTokenInfoPrecompile {
    struct HyperTokenInfo {
        string name;
        uint64[] spots;
        uint64 deployerTradingFeeShare;
        address deployer;
        address evmContract;
        uint8 szDecimals;
        uint8 weiDecimals;
        int8 evmExtraWeiDecimals;
    }

    mapping(uint32 => uint8) public szByToken;

    function setSz(uint32 tokenIndex, uint8 sz) external {
        szByToken[tokenIndex] = sz;
    }

    fallback() external {
        uint32 tokenIndex = abi.decode(msg.data, (uint32));
        uint8 sz = szByToken[tokenIndex];
        HyperTokenInfo memory info = HyperTokenInfo({
            name: "",
            spots: new uint64[](0),
            deployerTradingFeeShare: 0,
            deployer: address(0),
            evmContract: address(0),
            szDecimals: sz,
            weiDecimals: 0,
            evmExtraWeiDecimals: 0
        });
        bytes memory out = abi.encode(info);
        assembly {
            return(add(out, 32), mload(out))
        }
    }
}

/// ======= Tests =======

contract HyperliquidOracleFuzzTest is Test {
    address constant SPOT_PRECOMPILE = HyperSpotPricePrecompile.SPOT_PRICE_PRECOMPILE_ADDRESS;
    address constant TOKEN_INFO_PRECOMPILE = HyperTokenInfoPrecompile.TOKEN_INFO_PRECOMPILE_ADDRESS;

    MockSpotPricePrecompile private spotImpl;
    MockTokenInfoPrecompile private tokenInfoImpl;

    function setUp() public {
        // Deploy mocks
        spotImpl = new MockSpotPricePrecompile();
        tokenInfoImpl = new MockTokenInfoPrecompile();

        // Etch runtime bytecode to canonical precompile addresses
        vm.etch(SPOT_PRECOMPILE, address(spotImpl).code);
        vm.etch(TOKEN_INFO_PRECOMPILE, address(tokenInfoImpl).code);
    }

    // --- Helpers ---

    function _setSz(uint32 tokenIndex, uint8 s) internal {
        MockTokenInfoPrecompile(TOKEN_INFO_PRECOMPILE).setSz(tokenIndex, s);
    }

    function _setPrice(uint32 pairIndex, uint256 raw) internal {
        MockSpotPricePrecompile(SPOT_PRECOMPILE).setPrice(pairIndex, raw);
    }

    function _deployOracle(uint32 pairIndex, uint32 tokenIndex) internal returns (HyperliquidOracle) {
        return new HyperliquidOracle(pairIndex, tokenIndex);
    }

    function _divisorFromSz(uint8 s) internal pure returns (uint256) {
        // Mirror wrapper: clamp s > 8 to 8 via default branch
        if (s == 0) return 100_000_000;
        if (s == 1) return 10_000_000;
        if (s == 2) return 1_000_000;
        if (s == 3) return 100_000;
        if (s == 4) return 10_000;
        if (s == 5) return 1_000;
        if (s == 6) return 100;
        if (s == 7) return 10;
        return 1; // s >= 8
    }

    function testFuzz_Normalization(uint8 s, uint256 raw) public {
        uint32 pair = 7777;
        uint32 tok = 8888;

        _setSz(tok, s);
        _setPrice(pair, raw);

        HyperliquidOracle o = _deployOracle(pair, tok);

        uint256 divisor = _divisorFromSz(s);

        if (raw == 0) {
            vm.expectRevert(HyperSpotPricePrecompile.SpotPriceIsZero.selector);
            o.getData();
            return;
        }

        uint256 normalized = raw / divisor;

        if (normalized == 0) {
            vm.expectRevert(HyperliquidOracle.InvalidData.selector);
            o.getData();
            return;
        }

        if (normalized > uint256(uint216(type(int216).max))) {
            vm.expectRevert(HyperliquidOracle.Overflow.selector);
            o.getData();
            return;
        }

        (int216 data, uint40 ts) = o.getData();
        assertEq(uint256(int256(data)), normalized, "normalized mismatch");
        assertEq(uint256(ts), block.timestamp, "timestamp mismatch");
    }

    function testFuzz_InvalidDataWhenRawBelowDivisor(uint8 s, uint256 rawBelowDivisor) public {
        uint32 pair = 9001;
        uint32 tok = 9002;

        _setSz(tok, s);
        uint256 divisor = _divisorFromSz(s);

        vm.assume(divisor > 1);

        rawBelowDivisor = bound(rawBelowDivisor, 1, divisor - 1);
        _setPrice(pair, rawBelowDivisor);

        HyperliquidOracle o = _deployOracle(pair, tok);

        vm.expectRevert(HyperliquidOracle.InvalidData.selector);
        o.getData();
    }

    function testFuzz_constructorRejectsInvalidPairIndex(uint32 pairIndex, uint32 tokenIndex) public {
        // Ensure the token info precompile returns a valid szDecimals for any fuzzed tokenIndex.
        _setSz(tokenIndex, 6); // s=6 ⇒ divisor=100 (any nonzero is fine)

        if (pairIndex == 0) {
            vm.expectRevert(HyperliquidOracle.InvalidPairIndex.selector);
            new HyperliquidOracle(pairIndex, tokenIndex);
        } else {
            // Should not revert for any nonzero pairIndex.
            new HyperliquidOracle(pairIndex, tokenIndex);
        }
    }

    function testFuzz_szDivisorLUT(uint8 s) public {
        uint32 pair = 1234;
        uint32 tok = 5678;

        uint32 expected;
        if (s < 8) {
            uint32 pow10 = 1;
            unchecked {
                for (uint8 i = 0; i < (8 - s); ++i) {
                    pow10 *= 10;
                }
            }
            expected = pow10;
        } else {
            expected = 1;
        }

        _setSz(tok, s);
        HyperliquidOracle o = _deployOracle(pair, tok);

        assertEq(o.szDecimals(), s, "szDecimals cached mismatch");
        assertEq(o.priceDivisor(), expected, string(abi.encodePacked("divisor mismatch for s=", vm.toString(s))));
    }

    /// @dev Fuzz around overflow boundary: choose normalized > int216.max so the wrapper reverts with Overflow().
    function testFuzz_OverflowWhenNormalizedTooLarge(uint8 s, uint256 extra) public {
        uint32 pair = 12_345;
        uint32 tok = 54_321;

        _setSz(tok, s);
        uint256 divisor = _divisorFromSz(s);
        if (divisor == 0) divisor = 1;

        // Ensure we exceed int216.max by at least 1 (vary slightly for fuzzing).
        uint256 k = (extra % 10) + 1; // ∈ [1..10]
        uint256 targetNormalized = uint256(uint216(type(int216).max)) + k;

        // raw = targetNormalized * divisor  => normalized = targetNormalized > int216.max
        uint256 raw = targetNormalized * divisor;
        _setPrice(pair, raw);

        HyperliquidOracle o = _deployOracle(pair, tok);

        // Expect the wrapper's custom error (not a string).
        vm.expectRevert(HyperliquidOracle.Overflow.selector);
        o.getData();
    }

    function testFuzz_HappyPath(uint8 s, uint256 normalized) public {
        uint32 pair = 22_22;
        uint32 tok = 33_33;

        _setSz(tok, s);
        uint256 divisor = _divisorFromSz(s);
        if (divisor == 0) divisor = 1;

        normalized = bound(normalized, 1, uint256(uint216(type(int216).max)));

        uint256 raw = normalized * divisor;

        _setPrice(pair, raw);
        HyperliquidOracle o = _deployOracle(pair, tok);

        (int216 data, ) = o.getData();
        assertEq(uint256(int256(data)), normalized, "normalized mismatch");
    }

    function testFuzz_ImmutablesUnaffectedByPostDeploySzChange(
        uint8 sInitial,
        uint8 sLater,
        uint256 normalized
    ) public {
        uint32 pair = 44_44;
        uint32 tok = 55_55;

        _setSz(tok, sInitial);
        uint256 dInitial = _divisorFromSz(sInitial);
        if (dInitial == 0) dInitial = 1;

        normalized = bound(normalized, 1, 1e18);
        uint256 raw = normalized * dInitial;

        _setPrice(pair, raw);
        HyperliquidOracle o = _deployOracle(pair, tok);

        _setSz(tok, sLater);

        (int216 data, ) = o.getData();
        assertEq(uint256(int256(data)), normalized, "immutables should keep initial divisor");
    }
}
