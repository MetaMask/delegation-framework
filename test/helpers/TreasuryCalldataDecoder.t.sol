// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IMetaBridge } from "../../src/helpers/interfaces/IMetaBridge.sol";
import { IMetaSwap } from "../../src/helpers/interfaces/IMetaSwap.sol";
import { TreasuryCalldataDecoder } from "../../src/helpers/libraries/TreasuryCalldataDecoder.sol";

/// @dev Exposes `TreasuryCalldataDecoder` internal library functions for direct unit tests.
contract TreasuryCalldataDecoderHarness {
    function decodeOuterBridgeCalldata(bytes calldata _apiData)
        external
        pure
        returns (string memory adapterId_, IERC20 tokenFrom_, uint256 amountFrom_, bytes memory bridgeInnerData_)
    {
        return TreasuryCalldataDecoder.decodeOuterBridgeCalldata(_apiData);
    }

    function decodeBridgeApiData(bytes calldata _apiData)
        external
        pure
        returns (
            string memory adapterId_,
            IERC20 tokenFrom_,
            uint256 amountFrom_,
            bytes memory bridgeInnerData_,
            TreasuryCalldataDecoder.BridgeAdapterDecoded memory inner_
        )
    {
        return TreasuryCalldataDecoder.decodeBridgeApiData(_apiData);
    }

    function decodeSwapApiData(bytes calldata _apiData)
        external
        pure
        returns (string memory aggregatorId_, IERC20 tokenFrom_, IERC20 tokenTo_, uint256 amountFrom_, bytes memory swapData_)
    {
        return TreasuryCalldataDecoder.decodeSwapApiData(_apiData);
    }
}

/// @dev Run: `forge test --match-contract TreasuryCalldataDecoderTest`
contract TreasuryCalldataDecoderTest is Test {
    TreasuryCalldataDecoderHarness internal harness;

    address internal constant TOKEN_A = address(0xA11ce);
    address internal constant TOKEN_B = address(0xB0b);
    uint256 internal constant DEST_CHAIN = 137;

    function setUp() public {
        harness = new TreasuryCalldataDecoderHarness();
    }

    function test_revert_decodeOuterBridge_InvalidBridgeFunctionSelector() public {
        bytes memory apiData = abi.encodeWithSelector(bytes4(0xdeadbeef), "relay", TOKEN_A, uint256(1 ether), bytes(""));
        vm.expectRevert(TreasuryCalldataDecoder.InvalidBridgeFunctionSelector.selector);
        harness.decodeOuterBridgeCalldata(apiData);
    }

    function test_revert_decodeBridgeApiData_InvalidBridgeFunctionSelector() public {
        bytes memory apiData = abi.encodeWithSelector(bytes4(0xdeadbeef), "relay", TOKEN_A, uint256(1 ether), bytes(""));
        vm.expectRevert(TreasuryCalldataDecoder.InvalidBridgeFunctionSelector.selector);
        harness.decodeBridgeApiData(apiData);
    }

    function test_revert_decodeBridgeApiData_TokenFromMismatch() public {
        bytes memory tail = _bridgeTail(DEST_CHAIN, TOKEN_B, TOKEN_B, 1 ether, 0);
        bytes memory apiData = _bridgeApi(TOKEN_A, 1 ether, tail);
        vm.expectRevert(TreasuryCalldataDecoder.TokenFromMismatch.selector);
        harness.decodeBridgeApiData(apiData);
    }

    function test_revert_decodeBridgeApiData_AmountFromMismatch() public {
        bytes memory tail = _bridgeTail(DEST_CHAIN, TOKEN_A, TOKEN_B, 1, 1);
        bytes memory apiData = _bridgeApi(TOKEN_A, 3, tail);
        vm.expectRevert(TreasuryCalldataDecoder.AmountFromMismatch.selector);
        harness.decodeBridgeApiData(apiData);
    }

    function test_decodeBridgeApiData_happy() public {
        uint256 amt = 1 ether;
        bytes memory tail = _bridgeTail(DEST_CHAIN, TOKEN_A, TOKEN_B, amt, 0);
        bytes memory apiData = _bridgeApi(TOKEN_A, amt, tail);
        (
            string memory adapterId,
            IERC20 tokenFrom,
            uint256 amountFrom,
            ,
            TreasuryCalldataDecoder.BridgeAdapterDecoded memory inner
        ) = harness.decodeBridgeApiData(apiData);
        assertEq(adapterId, "relay");
        assertEq(address(tokenFrom), TOKEN_A);
        assertEq(amountFrom, amt);
        assertEq(inner.destinationChainId, DEST_CHAIN);
        assertEq(inner.tokenFrom, TOKEN_A);
        assertEq(inner.tokenTo, TOKEN_B);
    }

    function test_revert_decodeSwapApiData_InvalidSwapFunctionSelector() public {
        bytes memory apiData = abi.encodeWithSelector(bytes4(0xdeadbeef), "agg", IERC20(TOKEN_A), uint256(1), bytes(""));
        vm.expectRevert(TreasuryCalldataDecoder.InvalidSwapFunctionSelector.selector);
        harness.decodeSwapApiData(apiData);
    }

    function test_revert_decodeSwapApiData_TokenFromMismatch() public {
        IERC20 tA = IERC20(TOKEN_A);
        IERC20 tB = IERC20(TOKEN_B);
        bytes memory swapData = abi.encode(tB, tB, uint256(1 ether), uint256(1 ether), hex"", uint256(0), address(0), true);
        bytes memory apiData = abi.encodeWithSelector(IMetaSwap.swap.selector, "agg", tA, uint256(1 ether), swapData);
        vm.expectRevert(TreasuryCalldataDecoder.TokenFromMismatch.selector);
        harness.decodeSwapApiData(apiData);
    }

    function test_revert_decodeSwapApiData_AmountFromMismatch() public {
        IERC20 tA = IERC20(TOKEN_A);
        IERC20 tB = IERC20(TOKEN_B);
        bytes memory swapData = abi.encode(tA, tB, uint256(1 ether), uint256(1 ether), hex"", uint256(1), address(0), false);
        bytes memory apiData = abi.encodeWithSelector(IMetaSwap.swap.selector, "agg", tA, uint256(2 ether), swapData);
        vm.expectRevert(TreasuryCalldataDecoder.AmountFromMismatch.selector);
        harness.decodeSwapApiData(apiData);
    }

    function test_decodeSwapApiData_happy_feeToTrue_skipsAmountEquality() public {
        IERC20 tA = IERC20(TOKEN_A);
        IERC20 tB = IERC20(TOKEN_B);
        uint256 outerAmt = 5 ether;
        bytes memory swapData = abi.encode(tA, tB, uint256(1 ether), uint256(1 ether), hex"", uint256(0), address(0), true);
        bytes memory apiData = abi.encodeWithSelector(IMetaSwap.swap.selector, "agg", tA, outerAmt, swapData);
        (string memory agg, IERC20 from, IERC20 to, uint256 amtFrom, bytes memory swapDataOut) = harness.decodeSwapApiData(apiData);
        assertEq(agg, "agg");
        assertEq(address(from), TOKEN_A);
        assertEq(address(to), TOKEN_B);
        assertEq(amtFrom, outerAmt);
        assertEq(keccak256(swapDataOut), keccak256(swapData));
    }

    function _bridgeTail(uint256 chainId, address tokenFrom, address tokenTo, uint256 innerAmount, uint256 fee)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(address(0xA1), address(0xA2), chainId, tokenFrom, tokenTo, innerAmount, bytes(""), fee, address(0));
    }

    function _bridgeApi(address tokenFromOuter, uint256 outerAmount, bytes memory tail) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IMetaBridge.bridge.selector, "relay", tokenFromOuter, outerAmount, tail);
    }
}
