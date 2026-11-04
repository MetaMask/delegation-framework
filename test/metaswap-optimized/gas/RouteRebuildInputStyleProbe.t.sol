// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Test, console2 } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { IMetaSwap } from "../../../src/helpers/interfaces/IMetaSwap.sol";
import { Execution } from "../../../src/utils/Types.sol";

/**
 * @notice Option A (parse packed route → Solidity Execution[]) vs Solidity with agg/data as inputs.
 */
contract RouteRebuildInputStyleProbe is Test {
    using ExecutionLib for Execution[];

    address internal metaSwap = address(0x1111);
    address internal tokenIn = address(0x2222);

    function test_compare_approveSwap() public {
        (bytes memory route_, string memory agg_, bytes memory data_) = _fixture();
        uint256 amount_ = 100 ether;

        this.optionA(metaSwap, tokenIn, amount_, 2, route_);
        this.fnInputs(metaSwap, tokenIn, amount_, 2, agg_, data_);

        uint256 g0_ = gasleft();
        bytes memory a_ = this.optionA(metaSwap, tokenIn, amount_, 2, route_);
        uint256 optionAGas_ = g0_ - gasleft();

        g0_ = gasleft();
        bytes memory b_ = this.fnInputs(metaSwap, tokenIn, amount_, 2, agg_, data_);
        uint256 inputsGas_ = g0_ - gasleft();

        assertEq(a_, b_);
        _log("approveSwap", optionAGas_, inputsGas_);
    }

    function test_compare_swapOnly() public {
        (bytes memory route_, string memory agg_, bytes memory data_) = _fixture();
        uint256 amount_ = 100 ether;

        this.optionA(metaSwap, tokenIn, amount_, 1, route_);
        this.fnInputs(metaSwap, tokenIn, amount_, 1, agg_, data_);

        uint256 g0_ = gasleft();
        bytes memory a_ = this.optionA(metaSwap, tokenIn, amount_, 1, route_);
        uint256 optionAGas_ = g0_ - gasleft();

        g0_ = gasleft();
        bytes memory b_ = this.fnInputs(metaSwap, tokenIn, amount_, 1, agg_, data_);
        uint256 inputsGas_ = g0_ - gasleft();

        assertEq(a_, b_);
        _log("swapOnly", optionAGas_, inputsGas_);
    }

    function test_compare_resetApprove() public {
        (bytes memory route_, string memory agg_, bytes memory data_) = _fixture();
        uint256 amount_ = 100 ether;

        this.optionA(metaSwap, tokenIn, amount_, 3, route_);
        this.fnInputs(metaSwap, tokenIn, amount_, 3, agg_, data_);

        uint256 g0_ = gasleft();
        bytes memory a_ = this.optionA(metaSwap, tokenIn, amount_, 3, route_);
        uint256 optionAGas_ = g0_ - gasleft();

        g0_ = gasleft();
        bytes memory b_ = this.fnInputs(metaSwap, tokenIn, amount_, 3, agg_, data_);
        uint256 inputsGas_ = g0_ - gasleft();

        assertEq(a_, b_);
        _log("resetApprove", optionAGas_, inputsGas_);
    }

    function _log(string memory name_, uint256 optionAGas_, uint256 inputsGas_) private pure {
        console2.log(string.concat(name_, "|optionA_parse+encode"), optionAGas_);
        console2.log(string.concat(name_, "|fnInputs_encodeOnly"), inputsGas_);
        console2.log(string.concat(name_, "|optionA_minus_inputs"), int256(optionAGas_) - int256(inputsGas_));
    }

    function _fixture() private pure returns (bytes memory route_, string memory agg_, bytes memory data_) {
        agg_ = "actual-aggregator-with-different-length";
        data_ = abi.encode(IERC20(address(0x3333)), uint256(200 ether), new bytes(160));
        route_ = bytes.concat(bytes1(uint8(bytes(agg_).length)), bytes(agg_), bytes2(uint16(data_.length)), data_);
    }

    /// @dev Option A: packed route in, parse, then Execution[] encode.
    function optionA(address m_, address t_, uint256 a_, uint256 mode_, bytes calldata route_)
        external
        pure
        returns (bytes memory)
    {
        (string memory agg_, bytes memory data_) = _parse(route_);
        return _encode(m_, t_, a_, mode_, agg_, data_);
    }

    /// @dev Function inputs: agg + data already separate (no packed-route parse).
    function fnInputs(
        address m_,
        address t_,
        uint256 a_,
        uint256 mode_,
        string calldata agg_,
        bytes calldata data_
    )
        external
        pure
        returns (bytes memory)
    {
        return _encode(m_, t_, a_, mode_, agg_, data_);
    }

    function _parse(bytes calldata route_) private pure returns (string memory agg_, bytes memory data_) {
        if (route_.length < 3) revert("short");
        uint256 aggLen_ = uint8(route_[0]);
        if (aggLen_ == 0) revert("agg");
        uint256 dataLenPos_ = 1 + aggLen_;
        if (route_.length < dataLenPos_ + 2) revert("head");
        uint256 dataLen_ = uint16(bytes2(route_[dataLenPos_:dataLenPos_ + 2]));
        if (dataLen_ < 64 || route_.length != dataLenPos_ + 2 + dataLen_) revert("len");
        agg_ = string(route_[1:1 + aggLen_]);
        data_ = route_[dataLenPos_ + 2:];
    }

    function _encode(
        address m_,
        address t_,
        uint256 a_,
        uint256 mode_,
        string memory agg_,
        bytes memory data_
    )
        private
        pure
        returns (bytes memory)
    {
        if (mode_ == 1) {
            Execution[] memory e1_ = new Execution[](1);
            e1_[0] = Execution({
                target: m_, value: 0, callData: abi.encodeCall(IMetaSwap.swap, (agg_, IERC20(t_), a_, data_))
            });
            return e1_.encodeBatch();
        }
        if (mode_ == 2) {
            Execution[] memory e2_ = new Execution[](2);
            e2_[0] = Execution({
                target: t_, value: 0, callData: abi.encodeWithSelector(IERC20.approve.selector, m_, a_)
            });
            e2_[1] = Execution({
                target: m_, value: 0, callData: abi.encodeCall(IMetaSwap.swap, (agg_, IERC20(t_), a_, data_))
            });
            return e2_.encodeBatch();
        }
        Execution[] memory e3_ = new Execution[](3);
        e3_[0] = Execution({
            target: t_, value: 0, callData: abi.encodeWithSelector(IERC20.approve.selector, m_, 0)
        });
        e3_[1] = Execution({
            target: t_, value: 0, callData: abi.encodeWithSelector(IERC20.approve.selector, m_, a_)
        });
        e3_[2] = Execution({
            target: m_, value: 0, callData: abi.encodeCall(IMetaSwap.swap, (agg_, IERC20(t_), a_, data_))
        });
        return e3_.encodeBatch();
    }
}
