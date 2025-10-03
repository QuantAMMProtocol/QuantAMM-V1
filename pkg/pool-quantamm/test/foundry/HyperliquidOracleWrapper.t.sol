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

/// @dev Mock for the SPOT PRICE precompile.
/// The real precompile is invoked via staticcall with abi-encoded (uint32 pairIndex)
/// and returns abi.encode(uint256 price). We expose setter helpers for tests and
/// implement a permissive fallback that decodes msg.data and returns encoded price.
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

contract HyperliquidOracleTest is Test {
    address constant SPOT_PRECOMPILE = HyperSpotPricePrecompile.SPOT_PRICE_PRECOMPILE_ADDRESS;
    address constant TOKEN_INFO_PRECOMPILE = HyperTokenInfoPrecompile.TOKEN_INFO_PRECOMPILE_ADDRESS;

    MockSpotPricePrecompile private spotImpl;
    MockTokenInfoPrecompile private tokenInfoImpl;

    HyperliquidOracle private oracle;

    function setUp() public {
        spotImpl = new MockSpotPricePrecompile();
        tokenInfoImpl = new MockTokenInfoPrecompile();

        vm.etch(SPOT_PRECOMPILE, address(spotImpl).code);
        vm.etch(TOKEN_INFO_PRECOMPILE, address(tokenInfoImpl).code);

        // 3) Seed state directly on the etched precompile addresses via the mock ABI
        MockTokenInfoPrecompile(TOKEN_INFO_PRECOMPILE).setSz(1 , 6);
        MockSpotPricePrecompile(SPOT_PRECOMPILE).setPrice(
            42,
            1_234_567_800
        );
        
        oracle = new HyperliquidOracle(42, 1);
    }

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
        if (s == 0) return 100_000_000;
        if (s == 1) return 10_000_000;
        if (s == 2) return 1_000_000;
        if (s == 3) return 100_000;
        if (s == 4) return 10_000;
        if (s == 5) return 1_000;
        if (s == 6) return 100;
        if (s == 7) return 10;
        return 1;
    }

    function test_returnsNormalizedPriceAndTimestamp() public view {
        (int216 data, uint40 ts) = oracle.getData();
        assertEq(int256(data), 12_345_678, "normalized price mismatch");
        assertEq(uint256(ts), block.timestamp, "timestamp mismatch");
    }

    function test_divisorMappingAcrossAllSzValues() public {
        uint32 pairIndex = 777;
        uint32 tokenIndex = 888;

        MockSpotPricePrecompile(SPOT_PRECOMPILE).setPrice(pairIndex, 100_000_000);

        for (uint8 s = 0; s <= 8; ++s) {
            MockTokenInfoPrecompile(TOKEN_INFO_PRECOMPILE).setSz(tokenIndex, s);
            HyperliquidOracle o = new HyperliquidOracle(pairIndex, tokenIndex);

            (int216 data, ) = o.getData();

            uint256 expectVal = 1;
            for (uint8 i = 0; i < s; ++i) {
                expectVal *= 10;
            }

            assertEq(int256(data), int256(expectVal), string(abi.encodePacked("bad norm for s=", vm.toString(s))));
        }
    }

    function test_zeroPriceRevertsWithPrecompileError() public {
        MockSpotPricePrecompile(SPOT_PRECOMPILE).setPrice(42, 0);
        vm.expectRevert(HyperSpotPricePrecompile.SpotPriceIsZero.selector);
        oracle.getData();
    }

    function test_precompileFailureBubbles() public {
        MockSpotPricePrecompile(SPOT_PRECOMPILE).setFail(true);
        vm.expectRevert();
        oracle.getData();
    }

    function test_constructorRejectsInvalidPairIndex() public {
        vm.expectRevert(HyperliquidOracle.InvalidPairIndex.selector);
        new HyperliquidOracle(0, 1);
    }

    function test_szDivisorLUT() public {
        uint32 pair = 1234;
        uint32 tok = 5678;

        uint32[9] memory expect = [
            uint32(100_000_000),
            uint32(10_000_000),
            uint32(1_000_000),
            uint32(100_000),
            uint32(10_000),
            uint32(1_000),
            uint32(100),
            uint32(10),
            uint32(1)
        ];

        for (uint8 s = 0; s <= 8; ++s) {
            _setSz(tok, s);
            HyperliquidOracle o = _deployOracle(pair, tok);

            assertEq(o.szDecimals(), s, "szDecimals cached mismatch");
            assertEq(o.priceDivisor(), expect[s], string(abi.encodePacked("divisor mismatch for s=", vm.toString(s))));
        }

        _setSz(tok, 9);
        HyperliquidOracle o9 = _deployOracle(pair, tok);
        assertEq(o9.priceDivisor(), 1, "divisor should be 1 for s=9");

        _setSz(tok, 255);
        HyperliquidOracle o255 = _deployOracle(pair, tok);
        assertEq(o255.priceDivisor(), 1, "divisor should be 1 for s>=8");
    }

    function test_timestampReflectsBlockTime() public {
        vm.warp(block.timestamp + 1234);
        (, uint40 ts) = oracle.getData();
        assertEq(uint256(ts), block.timestamp, "timestamp should be current block time");
    }

    function test_largeValuesFitIntoInt216() public {
        uint32 pair = 9001;
        uint32 tok = 9002;

        MockTokenInfoPrecompile(TOKEN_INFO_PRECOMPILE).setSz(tok, 8);
        uint256 raw = 1e30;
        MockSpotPricePrecompile(SPOT_PRECOMPILE).setPrice(pair, raw);

        HyperliquidOracle o = new HyperliquidOracle(pair, tok);
        (int216 data, ) = o.getData();
        assertEq(uint256(int256(data)), raw, "unexpected truncation or mismatch");
    }

    function test_szGreaterThanEightActsLikeEight() public {
        uint32 pair = 11;
        uint32 tok = 22;
        uint8 s = 15;

        _setSz(tok, s);
        _setPrice(pair, 123_456_789);
        HyperliquidOracle o = _deployOracle(pair, tok);

        (int216 data, ) = o.getData();

        assertEq(int256(data), 123_456_789);
    }

    function test_priceLessThanDivisorRevertsInvalidData() public {
        uint32 pair = 100;
        uint32 tok = 200;
        uint8 s = 6;

        _setSz(tok, s);
        _setPrice(pair, 99);
        HyperliquidOracle o = _deployOracle(pair, tok);

        vm.expectRevert(HyperliquidOracle.InvalidData.selector);
        o.getData();
    }

    function test_postDeploySzChangeDoesNotAffectNormalization() public {
        uint32 pair = 300;
        uint32 tok = 400;

        _setSz(tok, 6);
        _setPrice(pair, 12_345_600);
        HyperliquidOracle o = _deployOracle(pair, tok);

        _setSz(tok, 0);

        (int216 data, ) = o.getData();

        assertEq(int256(data), 123_456);
    }

    function test_timestampIsWithinUint40Bounds() public {
        uint32 pair = 500;
        uint32 tok = 600;
        _setSz(tok, 8);
        _setPrice(pair, 1e9);

        HyperliquidOracle o = _deployOracle(pair, tok);

        uint256 target = type(uint40).max - 10;
        vm.warp(target);
        (, uint40 ts) = o.getData();
        assertEq(uint256(ts), target);
    }

    function test_NoInvalidDataRegionWhenDivisorIsOne(uint256 raw) public {
        uint32 pair = 9101;
        uint32 tok = 9102;

        _setSz(tok, 255);
        uint256 divisor = _divisorFromSz(255);
        assertEq(divisor, 1, "divisor should be 1 when s >= 8");

        raw = bound(raw, 1, 1e18);
        _setPrice(pair, raw);

        HyperliquidOracle o = _deployOracle(pair, tok);

        (int216 data, ) = o.getData();
        assertEq(uint256(int256(data)), raw, "normalized should equal raw when divisor == 1");
    }
}
