// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { MetaSwapOrderLib } from "./MetaSwapOrderLib.sol";

/**
 * @title RouteRebuildLib
 * @notice Rebuilds `abi.encode(Execution[])` from signed limit terms + relayer route bytes.
 * @dev UniswapX / Rhinestone pattern: user signs bounds; filler supplies only `aggregatorId` + `data`.
 *      Built in small assembly stages (london stack limit). Route wire:
 *      `uint8 aggregatorIdLen | aggregatorId | uint16 dataLen | data`.
 */
library RouteRebuildLib {
    uint256 private constant APPROVE_SELECTOR = 0x095ea7b3;
    /// @dev `swap(string,address,uint256,bytes)`
    uint256 private constant SWAP_SELECTOR = 0x5f575529;
    /// @dev Left-shift a 4-byte selector into the high bytes of a word: (32 - 4) * 8
    uint256 private constant SELECTOR_LSHIFT = 224;
    /// @dev Right-shift after `calldataload` to right-align a packed uint16: (32 - 2) * 8
    uint256 private constant UINT16_RSHIFT = 240;

    struct Route {
        uint256 aggOff;
        uint256 aggLen;
        uint256 dataOff;
        uint256 dataLen;
        uint256 aggPad;
        uint256 swapCdLen;
        uint256 swapCdPad;
    }

    error InvalidRoute();

    function buildBatch(
        address metaSwap_,
        address tokenIn_,
        uint256 tokenInAmount_,
        uint256 approvalMode_,
        bytes calldata route_
    )
        internal
        pure
        returns (bytes memory batch_)
    {
        if (tokenIn_ == address(0)) {
            if (approvalMode_ != uint8(MetaSwapOrderLib.ApprovalMode.None)) {
                revert MetaSwapOrderLib.InvalidApprovalMode();
            }
            return _swapOnly(metaSwap_, tokenInAmount_, tokenIn_, tokenInAmount_, route_);
        }
        if (approvalMode_ == uint8(MetaSwapOrderLib.ApprovalMode.SkipApproval)) {
            return _swapOnly(metaSwap_, 0, tokenIn_, tokenInAmount_, route_);
        }
        if (approvalMode_ == uint8(MetaSwapOrderLib.ApprovalMode.Approve)) {
            return _approveSwap(metaSwap_, tokenIn_, tokenInAmount_, route_);
        }
        if (approvalMode_ == uint8(MetaSwapOrderLib.ApprovalMode.ResetApprove)) {
            return _resetApproveSwap(metaSwap_, tokenIn_, tokenInAmount_, route_);
        }
        revert MetaSwapOrderLib.InvalidApprovalMode();
    }

    function _parse(bytes calldata route_) private pure returns (Route memory r_) {
        assembly ("memory-safe") {
            let routeOff_ := route_.offset
            let routeLen_ := route_.length
            if lt(routeLen_, 3) {
                mstore(0x00, 0x84e505d2)
                revert(0x1c, 0x04)
            }
            let aggLen_ := byte(0, calldataload(routeOff_))
            let dataLenPos_ := add(1, aggLen_)
            if lt(routeLen_, add(dataLenPos_, 2)) {
                mstore(0x00, 0x84e505d2)
                revert(0x1c, 0x04)
            }
            let dataLen_ := shr(UINT16_RSHIFT, calldataload(add(routeOff_, dataLenPos_)))
            if or(or(iszero(aggLen_), lt(dataLen_, 64)), iszero(eq(routeLen_, add(add(dataLenPos_, 2), dataLen_)))) {
                mstore(0x00, 0x84e505d2)
                revert(0x1c, 0x04)
            }
            let aggPad_ := and(add(aggLen_, 31), not(31))
            // callData length: selector + 4-word head + str(len+pad) + bytes(len+rawLen)
            // = 4+128+32+aggPad+32+dataLen = 196+aggPad+dataLen
            let swapCdLen_ := add(196, add(aggPad_, dataLen_))
            mstore(r_, add(routeOff_, 1))
            mstore(add(r_, 0x20), aggLen_)
            mstore(add(r_, 0x40), add(add(routeOff_, dataLenPos_), 2))
            mstore(add(r_, 0x60), dataLen_)
            mstore(add(r_, 0x80), aggPad_)
            mstore(add(r_, 0xa0), swapCdLen_)
            mstore(add(r_, 0xc0), and(add(swapCdLen_, 31), not(31)))
        }
    }

    function _swapOnly(
        address metaSwap_,
        uint256 value_,
        address tokenIn_,
        uint256 amount_,
        bytes calldata route_
    )
        private
        pure
        returns (bytes memory batch_)
    {
        Route memory r_ = _parse(route_);
        batch_ = new bytes(32 + 32 + 32 + 128 + r_.swapCdPad);
        assembly ("memory-safe") {
            let ptr_ := add(batch_, 0x20)
            mstore(ptr_, 0x20)
            let c_ := add(ptr_, 0x20)
            mstore(c_, 1)
            mstore(add(c_, 0x20), 0x20)
        }
        _writeSwapExec(batch_, 0x60, metaSwap_, value_, tokenIn_, amount_, r_);
    }

    function _approveSwap(
        address metaSwap_,
        address tokenIn_,
        uint256 amount_,
        bytes calldata route_
    )
        private
        pure
        returns (bytes memory batch_)
    {
        Route memory r_ = _parse(route_);
        // Top 0x20 | len | off0 | off1 | exec0 (224) | exec1 (128+pad). Offsets match `abi.encode`.
        batch_ = new bytes(32 + 32 + 64 + 224 + 128 + r_.swapCdPad);
        assembly ("memory-safe") {
            let ptr_ := add(batch_, 0x20)
            mstore(ptr_, 0x20)
            let c_ := add(ptr_, 0x20)
            mstore(c_, 2)
            mstore(add(c_, 0x20), 0x40)
            mstore(add(c_, 0x40), 0x120) // 0x40 + 224
        }
        // Bodies start at content+0x60 (= batch-relative 0x80), after length + 2 offsets.
        _writeApprove(batch_, 0x80, tokenIn_, metaSwap_, amount_);
        _writeSwapExec(batch_, 0x80 + 224, metaSwap_, 0, tokenIn_, amount_, r_);
    }

    function _resetApproveSwap(
        address metaSwap_,
        address tokenIn_,
        uint256 amount_,
        bytes calldata route_
    )
        private
        pure
        returns (bytes memory batch_)
    {
        Route memory r_ = _parse(route_);
        batch_ = new bytes(32 + 32 + 96 + 224 + 224 + 128 + r_.swapCdPad);
        assembly ("memory-safe") {
            let ptr_ := add(batch_, 0x20)
            mstore(ptr_, 0x20)
            let c_ := add(ptr_, 0x20)
            mstore(c_, 3)
            mstore(add(c_, 0x20), 0x60)
            mstore(add(c_, 0x40), add(0x60, 224))
            mstore(add(c_, 0x60), add(0x60, 448))
        }
        _writeApprove(batch_, 0xa0, tokenIn_, metaSwap_, 0);
        _writeApprove(batch_, 0xa0 + 224, tokenIn_, metaSwap_, amount_);
        _writeSwapExec(batch_, 0xa0 + 448, metaSwap_, 0, tokenIn_, amount_, r_);
    }

    function _writeApprove(
        bytes memory batch_,
        uint256 execRel_,
        address tokenIn_,
        address spender_,
        uint256 amount_
    )
        private
        pure
    {
        uint256 sel_ = APPROVE_SELECTOR;
        assembly ("memory-safe") {
            let e_ := add(add(batch_, 0x20), execRel_)
            mstore(e_, tokenIn_)
            mstore(add(e_, 0x20), 0)
            mstore(add(e_, 0x40), 0x60)
            mstore(add(e_, 0x60), 68)
            let cd_ := add(e_, 0x80)
            mstore(cd_, shl(SELECTOR_LSHIFT, sel_))
            mstore(add(cd_, 4), spender_)
            mstore(add(cd_, 0x24), amount_)
        }
    }

    function _writeSwapExec(
        bytes memory batch_,
        uint256 execRel_,
        address metaSwap_,
        uint256 value_,
        address tokenIn_,
        uint256 amount_,
        Route memory r_
    )
        private
        pure
    {
        uint256 sel_ = SWAP_SELECTOR;
        assembly ("memory-safe") {
            let e_ := add(add(batch_, 0x20), execRel_)
            let swapCdLen_ := mload(add(r_, 0xa0))
            let aggPad_ := mload(add(r_, 0x80))
            mstore(e_, metaSwap_)
            mstore(add(e_, 0x20), value_)
            mstore(add(e_, 0x40), 0x60)
            mstore(add(e_, 0x60), swapCdLen_)
            let cd_ := add(e_, 0x80)
            mstore(cd_, shl(SELECTOR_LSHIFT, sel_))
            let head_ := add(cd_, 4)
            mstore(head_, 0x80)
            mstore(add(head_, 0x20), tokenIn_)
            mstore(add(head_, 0x40), amount_)
            mstore(add(head_, 0x60), add(0xa0, aggPad_))
            mstore(add(head_, 0x80), mload(add(r_, 0x20)))
            calldatacopy(add(head_, 0xa0), mload(r_), mload(add(r_, 0x20)))
            let dataHead_ := add(add(head_, 0xa0), aggPad_)
            mstore(dataHead_, mload(add(r_, 0x60)))
            calldatacopy(add(dataHead_, 0x20), mload(add(r_, 0x40)), mload(add(r_, 0x60)))
        }
    }
}
