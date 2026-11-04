// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Test, console2 } from "forge-std/Test.sol";

/**
 * @notice Current `_limitOrderStructHash` asm vs hybrid: Solidity encode + tiny redeemer asm.
 */
contract LimitHashReadableProbe is Test {
    function test_measure_limitHashHybrid() public {
        Wire memory w_ = _wire();
        CurrentHasher cur_ = new CurrentHasher();
        HybridHasher hyb_ = new HybridHasher();

        (uint256 curCold_, bytes32 h1_) = cur_.measure(w_.data, w_.alice, 9, 2);
        (uint256 hybCold_, bytes32 h2_) = hyb_.measure(w_.data, w_.alice, 9, 2);
        assertEq(h1_, h2_);

        (uint256 curWarm_,) = cur_.measure(w_.data, w_.alice, 9, 2);
        (uint256 hybWarm_,) = hyb_.measure(w_.data, w_.alice, 9, 2);

        console2.log("current_cold", curCold_);
        console2.log("hybrid_cold", hybCold_);
        console2.log("delta_cold", int256(hybCold_) - int256(curCold_));
        console2.log("current_warm", curWarm_);
        console2.log("hybrid_warm", hybWarm_);
        console2.log("delta_warm", int256(hybWarm_) - int256(curWarm_));
    }

    struct Wire {
        bytes data;
        address alice;
    }

    function _wire() private returns (Wire memory w_) {
        w_.alice = makeAddr("alice");
        address bob_ = makeAddr("bob");
        w_.data = bytes.concat(
            abi.encodePacked(
                bytes4(0x22222222),
                w_.alice,
                uint256(9),
                makeAddr("metaSwap"),
                makeAddr("tokenIn"),
                uint256(1 ether),
                uint8(1),
                makeAddr("tokenOut"),
                w_.alice,
                uint256(1),
                uint128(0),
                uint128(0),
                uint8(2)
            ),
            bytes20(bob_),
            bytes20(w_.alice),
            new bytes(65),
            hex"dead"
        );
    }
}

abstract contract HasherBase {
    uint256 internal constant METASWAP_OFFSET = 56;
    uint256 internal constant TOKEN_IN_OFFSET = 76;
    uint256 internal constant TOKEN_IN_AMOUNT_OFFSET = 96;
    uint256 internal constant APPROVAL_MODE_OFFSET = 128;
    uint256 internal constant TOKEN_OUT_OFFSET = 129;
    uint256 internal constant RECIPIENT_OFFSET = 149;
    uint256 internal constant TOKEN_OUT_MIN_OFFSET = 169;
    uint256 internal constant VALID_AFTER_OFFSET = 201;
    uint256 internal constant VALID_UNTIL_OFFSET = 217;
    uint256 internal constant REDEEMERS_OFFSET = 234;

    bytes32 internal constant LIMIT_ORDER_TYPEHASH = keccak256(
        "LimitOrder(address delegator,uint256 nonce,address metaSwap,address tokenIn,uint256 tokenInAmount,uint8 approvalMode,address tokenOut,address recipient,uint256 tokenOutMin,uint128 validAfter,uint128 validUntil,address[] redeemers)"
    );

    address private argDelegator;
    uint256 private argNonce;
    uint256 private argCount;

    function measure(bytes calldata wire_, address delegator_, uint256 nonce_, uint256 count_) external returns (uint256, bytes32) {
        argDelegator = delegator_;
        argNonce = nonce_;
        argCount = count_;
        (bool ok_, bytes memory ret_) = address(this).call(wire_);
        require(ok_, "inner");
        return abi.decode(ret_, (uint256, bytes32));
    }

    fallback() external {
        uint256 g0_ = gasleft();
        bytes32 hash_ = _hash(argDelegator, argNonce, argCount);
        bytes memory out_ = abi.encode(g0_ - gasleft(), hash_);
        assembly ("memory-safe") {
            return(add(out_, 0x20), mload(out_))
        }
    }

    function _hash(address delegator_, uint256 nonce_, uint256 redeemerCount_) internal pure virtual returns (bytes32);

    function _loadAddress(uint256 calldataOffset_) internal pure returns (address value_) {
        assembly ("memory-safe") {
            let word := calldataload(calldataOffset_)
            value_ := shr(96, word)
        }
    }

    function _loadWord(uint256 calldataOffset_) internal pure returns (uint256 value_) {
        assembly ("memory-safe") {
            value_ := calldataload(calldataOffset_)
        }
    }

    function _loadUint128(uint256 calldataOffset_) internal pure returns (uint256 value_) {
        assembly ("memory-safe") {
            let word := calldataload(calldataOffset_)
            value_ := shr(128, word)
        }
    }

    function _loadByte(uint256 calldataOffset_) internal pure returns (uint256 value_) {
        assembly ("memory-safe") {
            let word := calldataload(calldataOffset_)
            value_ := byte(0, word)
        }
    }

    function _hashRedeemers(uint256 redeemerCount_) internal pure returns (bytes32 hash_) {
        assembly ("memory-safe") {
            let words := mload(0x40)
            for { let i := 0 } lt(i, redeemerCount_) { i := add(i, 1) } {
                let word := calldataload(add(REDEEMERS_OFFSET, mul(i, 20)))
                mstore(add(words, shl(5, i)), shr(96, word))
            }
            hash_ := keccak256(words, shl(5, redeemerCount_))
        }
    }
}

contract CurrentHasher is HasherBase {
    function _hash(address delegator_, uint256 nonce_, uint256 redeemerCount_)
        internal
        pure
        override
        returns (bytes32 structHash_)
    {
        bytes32 typehash_ = LIMIT_ORDER_TYPEHASH;
        assembly ("memory-safe") {
            let fields := mload(0x40)
            let redeemerWords := add(fields, 0x1a0)
            for { let i := 0 } lt(i, redeemerCount_) { i := add(i, 1) } {
                let word := calldataload(add(REDEEMERS_OFFSET, mul(i, 20)))
                mstore(add(redeemerWords, shl(5, i)), shr(96, word))
            }
            let metaSwap := shr(96, calldataload(METASWAP_OFFSET))
            let tokenIn := shr(96, calldataload(TOKEN_IN_OFFSET))
            let tokenInAmount := calldataload(TOKEN_IN_AMOUNT_OFFSET)
            let approvalMode := byte(0, calldataload(APPROVAL_MODE_OFFSET))
            let tokenOut := shr(96, calldataload(TOKEN_OUT_OFFSET))
            let recipient := shr(96, calldataload(RECIPIENT_OFFSET))
            let tokenOutMin := calldataload(TOKEN_OUT_MIN_OFFSET)
            let validAfter := shr(128, calldataload(VALID_AFTER_OFFSET))
            let validUntil := shr(128, calldataload(VALID_UNTIL_OFFSET))
            let redeemersHash := keccak256(redeemerWords, shl(5, redeemerCount_))
            mstore(fields, typehash_)
            mstore(add(fields, 0x20), delegator_)
            mstore(add(fields, 0x40), nonce_)
            mstore(add(fields, 0x60), metaSwap)
            mstore(add(fields, 0x80), tokenIn)
            mstore(add(fields, 0xa0), tokenInAmount)
            mstore(add(fields, 0xc0), approvalMode)
            mstore(add(fields, 0xe0), tokenOut)
            mstore(add(fields, 0x100), recipient)
            mstore(add(fields, 0x120), tokenOutMin)
            mstore(add(fields, 0x140), validAfter)
            mstore(add(fields, 0x160), validUntil)
            mstore(add(fields, 0x180), redeemersHash)
            structHash_ := keccak256(fields, 0x1a0)
        }
    }
}

contract HybridHasher is HasherBase {
    function _hash(address delegator_, uint256 nonce_, uint256 redeemerCount_) internal pure override returns (bytes32) {
        bytes32 redeemersHash_ = _hashRedeemers(redeemerCount_);
        bytes memory head_ = abi.encode(
            LIMIT_ORDER_TYPEHASH,
            delegator_,
            nonce_,
            _loadAddress(METASWAP_OFFSET),
            _loadAddress(TOKEN_IN_OFFSET),
            _loadWord(TOKEN_IN_AMOUNT_OFFSET),
            uint8(_loadByte(APPROVAL_MODE_OFFSET))
        );
        bytes memory tail_ = abi.encode(
            _loadAddress(TOKEN_OUT_OFFSET),
            _loadAddress(RECIPIENT_OFFSET),
            _loadWord(TOKEN_OUT_MIN_OFFSET),
            uint128(_loadUint128(VALID_AFTER_OFFSET)),
            uint128(_loadUint128(VALID_UNTIL_OFFSET)),
            redeemersHash_
        );
        return keccak256(bytes.concat(head_, tail_));
    }
}
