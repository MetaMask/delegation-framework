// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;
import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ExecutionLib} from "@erc7579/lib/ExecutionLib.sol";
import {IMetaSwap} from "../../../src/helpers/interfaces/IMetaSwap.sol";
import {Execution} from "../../../src/utils/Types.sol";
import {RouteRebuildLib} from "../../../src/metaswap/direct-route/RouteRebuildLib.sol";

contract RouteRebuildClarityProbe is Test {
    using ExecutionLib for Execution[];
    address metaSwap = address(0x1111);
    address tokenIn = address(0x2222);

    function test_gas_approveSwap() public {
        (bytes memory route_, string memory agg_, bytes memory data_) = _route();
        uint256 amount = 100 ether;

        // warm
        this.asmBuild(metaSwap, tokenIn, amount, 2, route_);
        this.solBuild(metaSwap, tokenIn, amount, agg_, data_);

        uint256 g0 = gasleft();
        bytes memory a = this.asmBuild(metaSwap, tokenIn, amount, 2, route_);
        uint256 asmG = g0 - gasleft();
        g0 = gasleft();
        bytes memory s = this.solBuild(metaSwap, tokenIn, amount, agg_, data_);
        uint256 solG = g0 - gasleft();
        assertEq(a, s);
        console2.log("approveSwap|asm", asmG);
        console2.log("approveSwap|sol", solG);
        console2.log("approveSwap|delta", int256(solG) - int256(asmG));
    }

    function test_gas_swapOnly() public {
        (bytes memory route_, string memory agg_, bytes memory data_) = _route();
        uint256 amount = 100 ether;
        this.asmBuild(metaSwap, tokenIn, amount, 1, route_);
        this.solSwapOnly(metaSwap, tokenIn, amount, agg_, data_);
        uint256 g0 = gasleft();
        bytes memory a = this.asmBuild(metaSwap, tokenIn, amount, 1, route_);
        uint256 asmG = g0 - gasleft();
        g0 = gasleft();
        bytes memory s = this.solSwapOnly(metaSwap, tokenIn, amount, agg_, data_);
        uint256 solG = g0 - gasleft();
        assertEq(a, s);
        console2.log("swapOnly|asm", asmG);
        console2.log("swapOnly|sol", solG);
        console2.log("swapOnly|delta", int256(solG) - int256(asmG));
    }

    function test_gas_resetApprove() public {
        (bytes memory route_, string memory agg_, bytes memory data_) = _route();
        uint256 amount = 100 ether;
        this.asmBuild(metaSwap, tokenIn, amount, 3, route_);
        this.solReset(metaSwap, tokenIn, amount, agg_, data_);
        uint256 g0 = gasleft();
        bytes memory a = this.asmBuild(metaSwap, tokenIn, amount, 3, route_);
        uint256 asmG = g0 - gasleft();
        g0 = gasleft();
        bytes memory s = this.solReset(metaSwap, tokenIn, amount, agg_, data_);
        uint256 solG = g0 - gasleft();
        assertEq(a, s);
        console2.log("resetApprove|asm", asmG);
        console2.log("resetApprove|sol", solG);
        console2.log("resetApprove|delta", int256(solG) - int256(asmG));
    }

    function _route() private pure returns (bytes memory route_, string memory agg_, bytes memory data_) {
        agg_ = "actual-aggregator-with-different-length";
        bytes memory routeData = new bytes(160);
        data_ = abi.encode(IERC20(address(0x3333)), uint256(200 ether), routeData);
        route_ = bytes.concat(bytes1(uint8(bytes(agg_).length)), bytes(agg_), bytes2(uint16(data_.length)), data_);
    }

    function asmBuild(address m, address t, uint256 a, uint256 mode, bytes calldata route) external pure returns (bytes memory) {
        return RouteRebuildLib.buildBatch(m, t, a, mode, route);
    }
    function solBuild(address m, address t, uint256 a, string calldata agg, bytes calldata data) external pure returns (bytes memory) {
        Execution[] memory e = new Execution[](2);
        e[0] = Execution({target: t, value: 0, callData: abi.encodeWithSelector(IERC20.approve.selector, m, a)});
        e[1] = Execution({target: m, value: 0, callData: abi.encodeCall(IMetaSwap.swap, (agg, IERC20(t), a, data))});
        return e.encodeBatch();
    }
    function solSwapOnly(address m, address t, uint256 a, string calldata agg, bytes calldata data) external pure returns (bytes memory) {
        Execution[] memory e = new Execution[](1);
        e[0] = Execution({target: m, value: 0, callData: abi.encodeCall(IMetaSwap.swap, (agg, IERC20(t), a, data))});
        return e.encodeBatch();
    }
    function solReset(address m, address t, uint256 a, string calldata agg, bytes calldata data) external pure returns (bytes memory) {
        Execution[] memory e = new Execution[](3);
        e[0] = Execution({target: t, value: 0, callData: abi.encodeWithSelector(IERC20.approve.selector, m, 0)});
        e[1] = Execution({target: t, value: 0, callData: abi.encodeWithSelector(IERC20.approve.selector, m, a)});
        e[2] = Execution({target: m, value: 0, callData: abi.encodeCall(IMetaSwap.swap, (agg, IERC20(t), a, data))});
        return e.encodeBatch();
    }

    function test_gas_approveSwap_fairSolWithParse() public {
        (bytes memory route_,,) = _route();
        uint256 amount = 100 ether;
        this.asmBuild(metaSwap, tokenIn, amount, 2, route_);
        this.solBuildFromRoute(metaSwap, tokenIn, amount, 2, route_);
        uint256 g0 = gasleft();
        bytes memory a = this.asmBuild(metaSwap, tokenIn, amount, 2, route_);
        uint256 asmG = g0 - gasleft();
        g0 = gasleft();
        bytes memory s = this.solBuildFromRoute(metaSwap, tokenIn, amount, 2, route_);
        uint256 solG = g0 - gasleft();
        assertEq(a, s);
        console2.log("approveSwap_fair|asm", asmG);
        console2.log("approveSwap_fair|sol+parse", solG);
        console2.log("approveSwap_fair|delta", int256(solG) - int256(asmG));
    }

    function solBuildFromRoute(address m, address t, uint256 a, uint256 mode, bytes calldata route) external pure returns (bytes memory) {
        uint256 aggLen = uint8(route[0]);
        require(aggLen != 0 && route.length >= 1 + aggLen + 2, "route");
        uint256 dataLenPos = 1 + aggLen;
        uint256 dataLen = uint16(bytes2(route[dataLenPos:dataLenPos+2]));
        require(dataLen >= 64 && route.length == dataLenPos + 2 + dataLen, "route2");
        string memory agg = string(route[1:1+aggLen]);
        bytes memory data = route[dataLenPos+2:];
        if (mode == 1) {
            Execution[] memory e1 = new Execution[](1);
            e1[0] = Execution({target: m, value: 0, callData: abi.encodeCall(IMetaSwap.swap, (agg, IERC20(t), a, data))});
            return e1.encodeBatch();
        }
        if (mode == 2) {
            Execution[] memory e2 = new Execution[](2);
            e2[0] = Execution({target: t, value: 0, callData: abi.encodeWithSelector(IERC20.approve.selector, m, a)});
            e2[1] = Execution({target: m, value: 0, callData: abi.encodeCall(IMetaSwap.swap, (agg, IERC20(t), a, data))});
            return e2.encodeBatch();
        }
        Execution[] memory e3 = new Execution[](3);
        e3[0] = Execution({target: t, value: 0, callData: abi.encodeWithSelector(IERC20.approve.selector, m, 0)});
        e3[1] = Execution({target: t, value: 0, callData: abi.encodeWithSelector(IERC20.approve.selector, m, a)});
        e3[2] = Execution({target: m, value: 0, callData: abi.encodeCall(IMetaSwap.swap, (agg, IERC20(t), a, data))});
        return e3.encodeBatch();
    }
}

