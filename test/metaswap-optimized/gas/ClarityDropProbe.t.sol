// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Test, console2 } from "forge-std/Test.sol";

import { MetaSwapManager } from "../../../src/metaswap/final/MetaSwapManager.sol";

/**
 * @notice In-process gas for remaining clarity drops (asm → Solidity / existing helpers).
 * @dev Packed wire is forwarded as the entire inner `msg.data` so offsets match production.
 */
contract ClarityDropProbe is Test {
    uint256 private constant SIGNATURE_EXACT_OFFSET = 56;
    uint256 private constant METASWAP_OFFSET = 56;
    uint256 private constant TOKEN_IN_OFFSET = 76;
    uint256 private constant TOKEN_IN_AMOUNT_OFFSET = 96;
    uint256 private constant APPROVAL_MODE_OFFSET = 128;
    uint256 private constant TOKEN_OUT_OFFSET = 129;
    uint256 private constant RECIPIENT_OFFSET = 149;
    uint256 private constant TOKEN_OUT_MIN_OFFSET = 169;
    uint256 private constant VALID_AFTER_OFFSET = 201;
    uint256 private constant VALID_UNTIL_OFFSET = 217;
    uint256 private constant REDEEMERS_OFFSET = 234;

    bytes32 private constant EXACT_BATCH_TYPEHASH = keccak256(
        "ExactBatch(address delegator,uint256 nonce,uint128 validAfter,uint128 validUntil,address[] redeemers,bytes32 executionHash)"
    );

    MetaSwapManager internal mgr;
    address internal alice;
    address internal bob;
    address internal metaSwap;
    address internal tokenIn;
    address internal tokenOut;

    function setUp() public {
        mgr = new MetaSwapManager();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        metaSwap = makeAddr("metaSwap");
        tokenIn = makeAddr("tokenIn");
        tokenOut = makeAddr("tokenOut");
    }

    function test_probe_parseHeader() public {
        ClarityDropTarget t_ = new ClarityDropTarget();
        bytes memory wire_ = abi.encodePacked(bytes4(0x11111111), alice, uint256(7));
        (uint256 asmGas_, uint256 solGas_) = t_.measureHeader(wire_);
        _log("parseHeader", asmGas_, solGas_);
    }

    function test_probe_parseSignatureAndBatch() public {
        ClarityDropTarget t_ = new ClarityDropTarget();
        bytes memory wire_ = bytes.concat(abi.encodePacked(bytes4(0x11111111), alice, uint256(7)), new bytes(65), hex"aabbccdd");
        (uint256 asmGas_, uint256 solGas_) = t_.measureParse(wire_, SIGNATURE_EXACT_OFFSET);
        _log("parseSignatureAndBatch", asmGas_, solGas_);
    }

    function test_probe_exactStructHash() public {
        bytes32 executionHash_ = keccak256("batch");
        address[] memory redeemers_ = new address[](2);
        redeemers_[0] = bob;
        redeemers_[1] = alice;
        bytes32 redeemersHash_ = keccak256(abi.encodePacked(redeemers_));
        // Warm both pure paths (no external CALL overhead).
        _exactAsm(alice, 7, 1, 9, redeemersHash_, executionHash_);
        _exactSol(alice, 7, 1, 9, redeemersHash_, executionHash_);

        uint256 g0_ = gasleft();
        bytes32 asmHash_ = _exactAsm(alice, 7, 1, 9, redeemersHash_, executionHash_);
        uint256 asmGas_ = g0_ - gasleft();

        g0_ = gasleft();
        bytes32 solHash_ = _exactSol(alice, 7, 1, 9, redeemersHash_, executionHash_);
        uint256 solGas_ = g0_ - gasleft();

        assertEq(asmHash_, solHash_);
        assertEq(asmHash_, _managerExactHash(redeemers_, executionHash_));
        _log("exactStructHash", asmGas_, solGas_);
    }

    function test_probe_limitStructHash() public {
        ClarityDropTarget t_ = new ClarityDropTarget();
        address[] memory redeemers_ = new address[](2);
        redeemers_[0] = bob;
        redeemers_[1] = alice;
        bytes memory wire_ = _limitWire(alice, 9, redeemers_);

        (uint256 asmCold_, bytes32 h1_) = t_.measureLimitAsm(wire_, alice, 9, 2);
        (uint256 solCold_, bytes32 h2_) = t_.measureLimitSol(wire_, alice, 9, 2);
        assertEq(h1_, h2_);
        assertEq(h1_, mgr.hashLimitOrder(_buildLimitFromWire(wire_, alice, 9, 2)));

        (uint256 asmWarm_,) = t_.measureLimitAsm(wire_, alice, 9, 2);
        (uint256 solWarm_,) = t_.measureLimitSol(wire_, alice, 9, 2);

        console2.log("CLARITY|limitStructHash|asm_cold|%s", asmCold_);
        console2.log("CLARITY|limitStructHash|build+hash_cold|%s", solCold_);
        console2.log("CLARITY|limitStructHash|delta_cold|%s", int256(solCold_) - int256(asmCold_));
        _log("limitStructHash_warm", asmWarm_, solWarm_);
    }

    function _log(string memory name_, uint256 asmGas_, uint256 solGas_) private pure {
        console2.log(string.concat("CLARITY|", name_, "|asm|"), asmGas_);
        console2.log(string.concat("CLARITY|", name_, "|sol|"), solGas_);
        console2.log(string.concat("CLARITY|", name_, "|delta|"), int256(solGas_) - int256(asmGas_));
    }

    function _managerExactHash(address[] memory redeemers_, bytes32 executionHash_) private view returns (bytes32) {
        return mgr.hashExactBatch(alice, 7, 1, 9, redeemers_, executionHash_);
    }

    function _exactAsm(
        address delegator_,
        uint256 nonce_,
        uint128 validAfter_,
        uint128 validUntil_,
        bytes32 redeemersHash_,
        bytes32 executionHash_
    )
        private
        pure
        returns (bytes32 structHash_)
    {
        bytes32 typehash_ = EXACT_BATCH_TYPEHASH;
        assembly ("memory-safe") {
            let ptr_ := mload(0x40)
            mstore(ptr_, typehash_)
            mstore(add(ptr_, 0x20), delegator_)
            mstore(add(ptr_, 0x40), nonce_)
            mstore(add(ptr_, 0x60), validAfter_)
            mstore(add(ptr_, 0x80), validUntil_)
            mstore(add(ptr_, 0xa0), redeemersHash_)
            mstore(add(ptr_, 0xc0), executionHash_)
            structHash_ := keccak256(ptr_, 0xe0)
        }
    }

    /// @dev Same body as `MetaSwapManager._exactStructHash`.
    function _exactSol(
        address delegator_,
        uint256 nonce_,
        uint128 validAfter_,
        uint128 validUntil_,
        bytes32 redeemersHash_,
        bytes32 executionHash_
    )
        private
        pure
        returns (bytes32)
    {
        return
            keccak256(
                abi.encode(EXACT_BATCH_TYPEHASH, delegator_, nonce_, validAfter_, validUntil_, redeemersHash_, executionHash_)
            );
    }

    function _buildLimitFromWire(
        bytes memory wire_,
        address delegator_,
        uint256 nonce_,
        uint256 redeemerCount_
    )
        private
        pure
        returns (MetaSwapManager.LimitOrder memory order_)
    {
        order_.delegator = delegator_;
        order_.nonce = nonce_;
        order_.metaSwap = address(bytes20(_slice(wire_, METASWAP_OFFSET, 20)));
        order_.tokenIn = address(bytes20(_slice(wire_, TOKEN_IN_OFFSET, 20)));
        order_.tokenInAmount = uint256(bytes32(_slice(wire_, TOKEN_IN_AMOUNT_OFFSET, 32)));
        order_.approvalMode = uint8(bytes1(_slice(wire_, APPROVAL_MODE_OFFSET, 1)));
        order_.tokenOut = address(bytes20(_slice(wire_, TOKEN_OUT_OFFSET, 20)));
        order_.recipient = address(bytes20(_slice(wire_, RECIPIENT_OFFSET, 20)));
        order_.tokenOutMin = uint256(bytes32(_slice(wire_, TOKEN_OUT_MIN_OFFSET, 32)));
        order_.validAfter = uint128(bytes16(_slice(wire_, VALID_AFTER_OFFSET, 16)));
        order_.validUntil = uint128(bytes16(_slice(wire_, VALID_UNTIL_OFFSET, 16)));
        order_.redeemers = new address[](redeemerCount_);
        for (uint256 i_; i_ < redeemerCount_; ++i_) {
            order_.redeemers[i_] = address(bytes20(_slice(wire_, REDEEMERS_OFFSET + i_ * 20, 20)));
        }
    }

    function _slice(bytes memory data_, uint256 offset_, uint256 length_) private pure returns (bytes memory out_) {
        out_ = new bytes(length_);
        for (uint256 i_; i_ < length_; ++i_) {
            out_[i_] = data_[offset_ + i_];
        }
    }

    function _limitWire(address delegator_, uint256 nonce_, address[] memory redeemers_) private view returns (bytes memory) {
        bytes memory head_ = abi.encodePacked(
            bytes4(0x22222222),
            delegator_,
            nonce_,
            metaSwap,
            tokenIn,
            uint256(1 ether),
            uint8(1),
            tokenOut,
            alice,
            uint256(1),
            uint128(0),
            uint128(0),
            uint8(redeemers_.length)
        );
        bytes memory redeemersPacked_;
        for (uint256 i_; i_ < redeemers_.length; ++i_) {
            redeemersPacked_ = bytes.concat(redeemersPacked_, bytes20(redeemers_[i_]));
        }
        return bytes.concat(head_, redeemersPacked_, new bytes(65), hex"dead");
    }
}

contract ClarityDropTarget {
    uint256 private constant DELEGATOR_OFFSET = 4;
    uint256 private constant NONCE_OFFSET = 24;
    uint256 private constant SIGNATURE_EXACT_OFFSET = 56;
    uint256 private constant SIGNATURE_LENGTH = 65;
    uint256 private constant METASWAP_OFFSET = 56;
    uint256 private constant TOKEN_IN_OFFSET = 76;
    uint256 private constant TOKEN_IN_AMOUNT_OFFSET = 96;
    uint256 private constant APPROVAL_MODE_OFFSET = 128;
    uint256 private constant TOKEN_OUT_OFFSET = 129;
    uint256 private constant RECIPIENT_OFFSET = 149;
    uint256 private constant TOKEN_OUT_MIN_OFFSET = 169;
    uint256 private constant VALID_AFTER_OFFSET = 201;
    uint256 private constant VALID_UNTIL_OFFSET = 217;
    uint256 private constant REDEEMERS_OFFSET = 234;

    bytes32 private constant LIMIT_ORDER_TYPEHASH = keccak256(
        "LimitOrder(address delegator,uint256 nonce,address metaSwap,address tokenIn,uint256 tokenInAmount,uint8 approvalMode,address tokenOut,address recipient,uint256 tokenOutMin,uint128 validAfter,uint128 validUntil,address[] redeemers)"
    );

    uint8 private op;
    uint256 private argOffset;
    address private argDelegator;
    uint256 private argNonce;
    uint256 private argRedeemerCount;

    function measureHeader(bytes calldata wire_) external returns (uint256 asmGas_, uint256 solGas_) {
        return abi.decode(_inner(wire_, 1, 0, address(0), 0, 0), (uint256, uint256));
    }

    function measureParse(bytes calldata wire_, uint256 offset_) external returns (uint256 asmGas_, uint256 solGas_) {
        return abi.decode(_inner(wire_, 2, offset_, address(0), 0, 0), (uint256, uint256));
    }

    function measureLimitAsm(
        bytes calldata wire_,
        address delegator_,
        uint256 nonce_,
        uint256 redeemerCount_
    )
        external
        returns (uint256 gasUsed_, bytes32 hash_)
    {
        return abi.decode(_inner(wire_, 3, 0, delegator_, nonce_, redeemerCount_), (uint256, bytes32));
    }

    function measureLimitSol(
        bytes calldata wire_,
        address delegator_,
        uint256 nonce_,
        uint256 redeemerCount_
    )
        external
        returns (uint256 gasUsed_, bytes32 hash_)
    {
        return abi.decode(_inner(wire_, 4, 0, delegator_, nonce_, redeemerCount_), (uint256, bytes32));
    }

    function _inner(
        bytes memory wire_,
        uint8 op_,
        uint256 offset_,
        address delegator_,
        uint256 nonce_,
        uint256 redeemerCount_
    )
        private
        returns (bytes memory)
    {
        op = op_;
        argOffset = offset_;
        argDelegator = delegator_;
        argNonce = nonce_;
        argRedeemerCount = redeemerCount_;
        (bool ok_, bytes memory ret_) = address(this).call(wire_);
        require(ok_, "inner");
        return ret_;
    }

    fallback() external {
        if (op == 1) {
            uint256 g0_ = gasleft();
            (address a1_, uint256 n1_) = _parseHeaderAsm();
            uint256 asmGas_ = g0_ - gasleft();

            g0_ = gasleft();
            (address a2_, uint256 n2_) = _parseHeaderSol();
            uint256 solGas_ = g0_ - gasleft();
            require(a1_ == a2_ && n1_ == n2_, "header mismatch");

            _returnPair(asmGas_, solGas_);
        } else if (op == 2) {
            uint256 offset_ = argOffset;
            uint256 g0_ = gasleft();
            (bytes calldata s1_, bytes calldata b1_) = _parseAsm(offset_);
            uint256 asmGas_ = g0_ - gasleft();

            g0_ = gasleft();
            (bytes calldata s2_, bytes calldata b2_) = _parseSol(offset_);
            uint256 solGas_ = g0_ - gasleft();
            require(keccak256(s1_) == keccak256(s2_) && keccak256(b1_) == keccak256(b2_), "parse mismatch");

            _returnPair(asmGas_, solGas_);
        } else if (op == 3) {
            uint256 g0_ = gasleft();
            bytes32 hash_ = _limitAsm(argDelegator, argNonce, argRedeemerCount);
            _returnHash(g0_ - gasleft(), hash_);
        } else if (op == 4) {
            uint256 g0_ = gasleft();
            bytes32 hash_ = _limitSol(argDelegator, argNonce, argRedeemerCount);
            _returnHash(g0_ - gasleft(), hash_);
        } else {
            revert("bad op");
        }
    }

    function _returnHash(uint256 gasUsed_, bytes32 hash_) private pure {
        bytes memory out_ = abi.encode(gasUsed_, hash_);
        assembly ("memory-safe") {
            return(add(out_, 0x20), mload(out_))
        }
    }

    function _returnPair(uint256 a_, uint256 b_) private pure {
        bytes memory out_ = abi.encode(a_, b_);
        assembly ("memory-safe") {
            return(add(out_, 0x20), mload(out_))
        }
    }

    function _parseHeaderAsm() private pure returns (address delegator_, uint256 nonce_) {
        require(msg.data.length >= SIGNATURE_EXACT_OFFSET, "short");
        assembly ("memory-safe") {
            delegator_ := shr(96, calldataload(DELEGATOR_OFFSET))
            nonce_ := calldataload(NONCE_OFFSET)
        }
    }

    function _parseHeaderSol() private pure returns (address delegator_, uint256 nonce_) {
        require(msg.data.length >= SIGNATURE_EXACT_OFFSET, "short");
        delegator_ = address(bytes20(msg.data[DELEGATOR_OFFSET:DELEGATOR_OFFSET + 20]));
        nonce_ = uint256(bytes32(msg.data[NONCE_OFFSET:NONCE_OFFSET + 32]));
    }

    function _parseAsm(uint256 offset_) private pure returns (bytes calldata signature_, bytes calldata batch_) {
        uint256 signatureEnd_ = offset_ + SIGNATURE_LENGTH;
        require(msg.data.length >= signatureEnd_, "short");
        assembly ("memory-safe") {
            signature_.offset := offset_
            signature_.length := SIGNATURE_LENGTH
            batch_.offset := signatureEnd_
            batch_.length := sub(calldatasize(), signatureEnd_)
        }
    }

    function _parseSol(uint256 offset_) private pure returns (bytes calldata signature_, bytes calldata batch_) {
        uint256 signatureEnd_ = offset_ + SIGNATURE_LENGTH;
        require(msg.data.length >= signatureEnd_, "short");
        signature_ = msg.data[offset_:signatureEnd_];
        batch_ = msg.data[signatureEnd_:];
    }

    function _limitAsm(address delegator_, uint256 nonce_, uint256 redeemerCount_) private pure returns (bytes32 structHash_) {
        bytes32 typehash_ = LIMIT_ORDER_TYPEHASH;
        assembly ("memory-safe") {
            let ptr_ := mload(0x40)
            let redeemers_ := add(ptr_, 0x1a0)
            for { let i_ := 0 } lt(i_, redeemerCount_) { i_ := add(i_, 1) } {
                mstore(add(redeemers_, shl(5, i_)), shr(96, calldataload(add(REDEEMERS_OFFSET, mul(i_, 20)))))
            }
            mstore(add(ptr_, 0x180), keccak256(redeemers_, shl(5, redeemerCount_)))
            mstore(ptr_, typehash_)
            mstore(add(ptr_, 0x20), delegator_)
            mstore(add(ptr_, 0x40), nonce_)
            mstore(add(ptr_, 0x60), shr(96, calldataload(METASWAP_OFFSET)))
            mstore(add(ptr_, 0x80), shr(96, calldataload(TOKEN_IN_OFFSET)))
            mstore(add(ptr_, 0xa0), calldataload(TOKEN_IN_AMOUNT_OFFSET))
            mstore(add(ptr_, 0xc0), byte(0, calldataload(APPROVAL_MODE_OFFSET)))
            mstore(add(ptr_, 0xe0), shr(96, calldataload(TOKEN_OUT_OFFSET)))
            mstore(add(ptr_, 0x100), shr(96, calldataload(RECIPIENT_OFFSET)))
            mstore(add(ptr_, 0x120), calldataload(TOKEN_OUT_MIN_OFFSET))
            mstore(add(ptr_, 0x140), shr(128, calldataload(VALID_AFTER_OFFSET)))
            mstore(add(ptr_, 0x160), shr(128, calldataload(VALID_UNTIL_OFFSET)))
            structHash_ := keccak256(ptr_, 0x1a0)
        }
    }

    /// @dev Proposed path: calldata slices → memory struct → same `hashLimitOrder` encoding.
    function _limitSol(address delegator_, uint256 nonce_, uint256 redeemerCount_) private pure returns (bytes32) {
        address[] memory redeemers_ = new address[](redeemerCount_);
        for (uint256 i_; i_ < redeemerCount_; ++i_) {
            uint256 o_ = REDEEMERS_OFFSET + i_ * 20;
            redeemers_[i_] = address(bytes20(msg.data[o_:o_ + 20]));
        }
        return keccak256(
            bytes.concat(
                abi.encode(
                    LIMIT_ORDER_TYPEHASH,
                    delegator_,
                    nonce_,
                    address(bytes20(msg.data[METASWAP_OFFSET:METASWAP_OFFSET + 20])),
                    address(bytes20(msg.data[TOKEN_IN_OFFSET:TOKEN_IN_OFFSET + 20])),
                    uint256(bytes32(msg.data[TOKEN_IN_AMOUNT_OFFSET:TOKEN_IN_AMOUNT_OFFSET + 32])),
                    uint8(bytes1(msg.data[APPROVAL_MODE_OFFSET:APPROVAL_MODE_OFFSET + 1]))
                ),
                abi.encode(
                    address(bytes20(msg.data[TOKEN_OUT_OFFSET:TOKEN_OUT_OFFSET + 20])),
                    address(bytes20(msg.data[RECIPIENT_OFFSET:RECIPIENT_OFFSET + 20])),
                    uint256(bytes32(msg.data[TOKEN_OUT_MIN_OFFSET:TOKEN_OUT_MIN_OFFSET + 32])),
                    uint128(bytes16(msg.data[VALID_AFTER_OFFSET:VALID_AFTER_OFFSET + 16])),
                    uint128(bytes16(msg.data[VALID_UNTIL_OFFSET:VALID_UNTIL_OFFSET + 16]))
                ),
                abi.encode(keccak256(abi.encodePacked(redeemers_)))
            )
        );
    }
}
