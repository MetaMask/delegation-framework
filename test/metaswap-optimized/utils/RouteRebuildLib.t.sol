// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { IMetaSwap } from "../../../src/helpers/interfaces/IMetaSwap.sol";
import { Execution } from "../../../src/utils/Types.sol";
import { RouteRebuildLib } from "../../../src/metaswap/direct-route/RouteRebuildLib.sol";

contract RouteRebuildLibTest is Test {
    using ExecutionLib for Execution[];

    function test_approveSwapMatchesAbiEncode() public {
        address metaSwap_ = address(0x1111);
        address tokenIn_ = address(0x2222);
        uint256 amount_ = 100 ether;
        string memory agg_ = "actual-aggregator-with-different-length";
        bytes memory routeData_ = new bytes(160);
        bytes memory data_ = abi.encode(IERC20(address(0x3333)), uint256(200 ether), routeData_);
        bytes memory route_ = bytes.concat(bytes1(uint8(bytes(agg_).length)), bytes(agg_), bytes2(uint16(data_.length)), data_);

        bytes memory got_ = this.build(metaSwap_, tokenIn_, amount_, 2, route_);

        bytes memory swapCd_ = abi.encodeCall(IMetaSwap.swap, (agg_, IERC20(tokenIn_), amount_, data_));
        Execution[] memory wantExec_ = new Execution[](2);
        wantExec_[0] = Execution({
            target: tokenIn_, value: 0, callData: abi.encodeWithSelector(IERC20.approve.selector, metaSwap_, amount_)
        });
        wantExec_[1] = Execution({ target: metaSwap_, value: 0, callData: swapCd_ });
        assertEq(got_, wantExec_.encodeBatch());
    }

    function build(
        address metaSwap_,
        address tokenIn_,
        uint256 amount_,
        uint256 mode_,
        bytes calldata route_
    )
        external
        pure
        returns (bytes memory)
    {
        return RouteRebuildLib.buildBatch(metaSwap_, tokenIn_, amount_, mode_, route_);
    }
}
