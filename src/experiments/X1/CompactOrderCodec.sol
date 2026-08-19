// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Delegation, Caveat } from "../../utils/Types.sol";

/**
 * @title CompactOrderCodec
 * @notice Fixed-schema encoder/decoder for single-chain limit-order style delegations.
 * @dev Layout (big-endian offsets after 4-byte magic `0xC0DEC001`):
 *      delegate(20) | delegator(20) | authority(32) | salt(32) | caveatCount(1)
 *      | per caveat: enforcer(20) | termsLen(2) | terms | argsLen(2) | args
 *      | sigLen(2) | signature
 *      Supports exactly one delegation per context; chains are not compact-encoded.
 */
library CompactOrderCodec {
    bytes4 internal constant MAGIC = 0xC0DEC001;

    error CompactOrderInvalidMagic();
    error CompactOrderTruncated();
    error CompactOrderUnsupportedChain();

    function isCompact(bytes calldata _context) internal pure returns (bool) {
        return _context.length >= 4 && bytes4(_context[0:4]) == MAGIC;
    }

    function encodeSingleDelegation(Delegation memory _delegation) internal pure returns (bytes memory encoded_) {
        uint256 caveatCount_ = _delegation.caveats.length;
        require(caveatCount_ <= type(uint8).max, "CompactOrderCodec:caveat-overflow");

        uint256 payloadSize_ = 105;
        for (uint256 i_; i_ < caveatCount_; ++i_) {
            payloadSize_ += 24 + _delegation.caveats[i_].terms.length + _delegation.caveats[i_].args.length;
        }
        payloadSize_ += 2 + _delegation.signature.length;

        encoded_ = new bytes(4 + payloadSize_);
        encoded_[0] = bytes1(uint8(uint32(MAGIC) >> 24));
        encoded_[1] = bytes1(uint8(uint32(MAGIC) >> 16));
        encoded_[2] = bytes1(uint8(uint32(MAGIC) >> 8));
        encoded_[3] = bytes1(uint8(uint32(MAGIC)));

        uint256 offset_ = 4;
        offset_ = _writeAddress(encoded_, offset_, _delegation.delegate);
        offset_ = _writeAddress(encoded_, offset_, _delegation.delegator);
        offset_ = _writeBytes32(encoded_, offset_, _delegation.authority);
        offset_ = _writeBytes32(encoded_, offset_, bytes32(_delegation.salt));
        encoded_[offset_] = bytes1(uint8(caveatCount_));
        ++offset_;

        for (uint256 c_; c_ < caveatCount_; ++c_) {
            Caveat memory caveat_ = _delegation.caveats[c_];
            offset_ = _writeAddress(encoded_, offset_, caveat_.enforcer);
            offset_ = _writeUint16(encoded_, offset_, uint16(caveat_.terms.length));
            offset_ = _writeBytes(encoded_, offset_, caveat_.terms);
            offset_ = _writeUint16(encoded_, offset_, uint16(caveat_.args.length));
            offset_ = _writeBytes(encoded_, offset_, caveat_.args);
        }

        offset_ = _writeUint16(encoded_, offset_, uint16(_delegation.signature.length));
        offset_ = _writeBytes(encoded_, offset_, _delegation.signature);
        require(offset_ == encoded_.length, "CompactOrderCodec:encode-length-mismatch");
    }

    function decodeSingleDelegation(bytes memory _context) internal pure returns (Delegation memory delegation_) {
        if (_context.length < 4 || _readMagicMem(_context) != MAGIC) revert CompactOrderInvalidMagic();

        uint256 offset_ = 4;
        (delegation_.delegate, offset_) = _readAddressMem(_context, offset_);
        (delegation_.delegator, offset_) = _readAddressMem(_context, offset_);
        (delegation_.authority, offset_) = _readBytes32Mem(_context, offset_);
        bytes32 saltWord_;
        (saltWord_, offset_) = _readBytes32Mem(_context, offset_);
        delegation_.salt = uint256(saltWord_);

        if (offset_ >= _context.length) revert CompactOrderTruncated();
        uint256 caveatCount_ = uint8(_context[offset_]);
        ++offset_;

        delegation_.caveats = new Caveat[](caveatCount_);
        for (uint256 c_; c_ < caveatCount_; ++c_) {
            Caveat memory caveat_;
            (caveat_.enforcer, offset_) = _readAddressMem(_context, offset_);
            uint256 termsLen_;
            (termsLen_, offset_) = _readUint16Mem(_context, offset_);
            (caveat_.terms, offset_) = _readBytesSliceMem(_context, offset_, termsLen_);
            uint256 argsLen_;
            (argsLen_, offset_) = _readUint16Mem(_context, offset_);
            (caveat_.args, offset_) = _readBytesSliceMem(_context, offset_, argsLen_);
            delegation_.caveats[c_] = caveat_;
        }

        uint256 sigLen_;
        (sigLen_, offset_) = _readUint16Mem(_context, offset_);
        (delegation_.signature, offset_) = _readBytesSliceMem(_context, offset_, sigLen_);

        if (offset_ != _context.length) revert CompactOrderTruncated();
    }

    function decodeSingleDelegationCalldata(bytes calldata _context) internal pure returns (Delegation memory delegation_) {
        if (!isCompact(_context)) revert CompactOrderInvalidMagic();

        uint256 offset_ = 4;
        (delegation_.delegate, offset_) = _readAddress(_context, offset_);
        (delegation_.delegator, offset_) = _readAddress(_context, offset_);
        (delegation_.authority, offset_) = _readBytes32(_context, offset_);
        bytes32 saltWord_;
        (saltWord_, offset_) = _readBytes32(_context, offset_);
        delegation_.salt = uint256(saltWord_);

        if (offset_ >= _context.length) revert CompactOrderTruncated();
        uint256 caveatCount_ = uint8(_context[offset_]);
        ++offset_;

        delegation_.caveats = new Caveat[](caveatCount_);
        for (uint256 c_; c_ < caveatCount_; ++c_) {
            Caveat memory caveat_;
            (caveat_.enforcer, offset_) = _readAddress(_context, offset_);
            uint256 termsLen_;
            (termsLen_, offset_) = _readUint16(_context, offset_);
            (caveat_.terms, offset_) = _readBytesSlice(_context, offset_, termsLen_);
            uint256 argsLen_;
            (argsLen_, offset_) = _readUint16(_context, offset_);
            (caveat_.args, offset_) = _readBytesSlice(_context, offset_, argsLen_);
            delegation_.caveats[c_] = caveat_;
        }

        uint256 sigLen_;
        (sigLen_, offset_) = _readUint16(_context, offset_);
        (delegation_.signature, offset_) = _readBytesSlice(_context, offset_, sigLen_);

        if (offset_ != _context.length) revert CompactOrderTruncated();
    }

    function decodeToArray(bytes calldata _context) internal pure returns (Delegation[] memory delegations_) {
        delegations_ = new Delegation[](1);
        delegations_[0] = decodeSingleDelegationCalldata(_context);
    }

    function _writeAddress(bytes memory _buf, uint256 _offset, address _value) private pure returns (uint256) {
        assembly {
            mstore(add(add(_buf, 0x20), _offset), shl(96, _value))
        }
        return _offset + 20;
    }

    function _writeBytes32(bytes memory _buf, uint256 _offset, bytes32 _value) private pure returns (uint256) {
        assembly {
            mstore(add(add(_buf, 0x20), _offset), _value)
        }
        return _offset + 32;
    }

    function _writeUint16(bytes memory _buf, uint256 _offset, uint16 _value) private pure returns (uint256) {
        _buf[_offset] = bytes1(uint8(_value >> 8));
        _buf[_offset + 1] = bytes1(uint8(_value));
        return _offset + 2;
    }

    function _writeBytes(bytes memory _buf, uint256 _offset, bytes memory _data) private pure returns (uint256) {
        uint256 len_ = _data.length;
        if (len_ == 0) return _offset;
        assembly {
            let dst := add(add(_buf, 0x20), _offset)
            let src := add(_data, 0x20)
            for { let i := 0 } lt(i, len_) { i := add(i, 0x20) } { mstore(add(dst, i), mload(add(src, i))) }
        }
        return _offset + len_;
    }

    function _readAddressMem(bytes memory _buf, uint256 _offset)
        private
        pure
        returns (address value_, uint256 nextOffset_)
    {
        if (_offset + 20 > _buf.length) revert CompactOrderTruncated();
        value_ = address(bytes20(_sliceMem(_buf, _offset, 20)));
        nextOffset_ = _offset + 20;
    }

    function _readBytes32Mem(bytes memory _buf, uint256 _offset)
        private
        pure
        returns (bytes32 value_, uint256 nextOffset_)
    {
        if (_offset + 32 > _buf.length) revert CompactOrderTruncated();
        value_ = bytes32(_sliceMem(_buf, _offset, 32));
        nextOffset_ = _offset + 32;
    }

    function _readUint16Mem(bytes memory _buf, uint256 _offset) private pure returns (uint256 value_, uint256 nextOffset_) {
        if (_offset + 2 > _buf.length) revert CompactOrderTruncated();
        value_ = (uint256(uint8(_buf[_offset])) << 8) | uint256(uint8(_buf[_offset + 1]));
        nextOffset_ = _offset + 2;
    }

    function _readBytesSliceMem(bytes memory _buf, uint256 _offset, uint256 _len)
        private
        pure
        returns (bytes memory slice_, uint256 nextOffset_)
    {
        if (_offset + _len > _buf.length) revert CompactOrderTruncated();
        slice_ = _sliceMem(_buf, _offset, _len);
        nextOffset_ = _offset + _len;
    }

    function _sliceMem(bytes memory _buf, uint256 _offset, uint256 _len) private pure returns (bytes memory slice_) {
        slice_ = new bytes(_len);
        for (uint256 i_; i_ < _len; ++i_) {
            slice_[i_] = _buf[_offset + i_];
        }
    }

    function _readAddress(bytes calldata _buf, uint256 _offset)
        private
        pure
        returns (address value_, uint256 nextOffset_)
    {
        if (_offset + 20 > _buf.length) revert CompactOrderTruncated();
        value_ = address(bytes20(_buf[_offset:_offset + 20]));
        nextOffset_ = _offset + 20;
    }

    function _readBytes32(bytes calldata _buf, uint256 _offset)
        private
        pure
        returns (bytes32 value_, uint256 nextOffset_)
    {
        if (_offset + 32 > _buf.length) revert CompactOrderTruncated();
        value_ = bytes32(_buf[_offset:_offset + 32]);
        nextOffset_ = _offset + 32;
    }

    function _readUint16(bytes calldata _buf, uint256 _offset) private pure returns (uint256 value_, uint256 nextOffset_) {
        if (_offset + 2 > _buf.length) revert CompactOrderTruncated();
        value_ = (uint256(uint8(_buf[_offset])) << 8) | uint256(uint8(_buf[_offset + 1]));
        nextOffset_ = _offset + 2;
    }

    function _readBytesSlice(bytes calldata _buf, uint256 _offset, uint256 _len)
        private
        pure
        returns (bytes memory slice_, uint256 nextOffset_)
    {
        if (_offset + _len > _buf.length) revert CompactOrderTruncated();
        slice_ = _buf[_offset:_offset + _len];
        nextOffset_ = _offset + _len;
    }

    function _readMagicMem(bytes memory _buf) private pure returns (bytes4 magic_) {
        magic_ = bytes4(
            (uint32(uint8(_buf[0])) << 24) | (uint32(uint8(_buf[1])) << 16) | (uint32(uint8(_buf[2])) << 8)
                | uint32(uint8(_buf[3]))
        );
    }
}
