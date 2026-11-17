// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

/**
 * @title NonceBitmap
 * @notice Per-delegator unordered nonces, separate maps for **ExactBatch** and **LimitOrder** flows.
 * @dev A nonce is `wordPos(248) | bitPos(8)`. Signer-chosen, so orders fill in any order. Reusing a word
 *      costs ~5,000 instead of ~22,100. The same numeric `nonce` can be used once per flow without colliding.
 *      Fill and cancel share the bit within a flow.
 *
 * Users call `invalidateExactBatchNonce` / `invalidateLimitOrderNonce` with the ticket they signed.
 * The `*Nonces(wordPos, mask)` helpers burn many tickets in one word.
 * `isExactBatchNonceUsed` / `isLimitOrderNonceUsed` are the views.
 */
abstract contract NonceBitmap {
    mapping(address delegator => mapping(uint248 wordPos => uint256 bits)) public exactBatchNonceBitmap;
    mapping(address delegator => mapping(uint248 wordPos => uint256 bits)) public limitOrderNonceBitmap;

    event ExactBatchNoncesInvalidated(address indexed delegator, uint248 indexed wordPos, uint256 mask);
    event LimitOrderNoncesInvalidated(address indexed delegator, uint248 indexed wordPos, uint256 mask);

    error NonceAlreadyUsed();

    function invalidateExactBatchNonce(uint256 nonce_) external {
        (uint248 wordPos_, uint256 bit_) = _nonceParts(nonce_);
        exactBatchNonceBitmap[msg.sender][wordPos_] |= bit_;
        emit ExactBatchNoncesInvalidated(msg.sender, wordPos_, bit_);
    }

    function invalidateLimitOrderNonce(uint256 nonce_) external {
        (uint248 wordPos_, uint256 bit_) = _nonceParts(nonce_);
        limitOrderNonceBitmap[msg.sender][wordPos_] |= bit_;
        emit LimitOrderNoncesInvalidated(msg.sender, wordPos_, bit_);
    }

    function invalidateExactBatchNonces(uint248 wordPos_, uint256 mask_) external {
        exactBatchNonceBitmap[msg.sender][wordPos_] |= mask_;
        emit ExactBatchNoncesInvalidated(msg.sender, wordPos_, mask_);
    }

    function invalidateLimitOrderNonces(uint248 wordPos_, uint256 mask_) external {
        limitOrderNonceBitmap[msg.sender][wordPos_] |= mask_;
        emit LimitOrderNoncesInvalidated(msg.sender, wordPos_, mask_);
    }

    function isExactBatchNonceUsed(address delegator_, uint256 nonce_) external view returns (bool) {
        (uint248 wordPos_, uint256 bit_) = _nonceParts(nonce_);
        return exactBatchNonceBitmap[delegator_][wordPos_] & bit_ != 0;
    }

    function isLimitOrderNonceUsed(address delegator_, uint256 nonce_) external view returns (bool) {
        (uint248 wordPos_, uint256 bit_) = _nonceParts(nonce_);
        return limitOrderNonceBitmap[delegator_][wordPos_] & bit_ != 0;
    }

    function _useExactBatchNonce(address delegator_, uint256 nonce_) internal {
        _useNonce(exactBatchNonceBitmap[delegator_], nonce_);
    }

    function _useLimitOrderNonce(address delegator_, uint256 nonce_) internal {
        _useNonce(limitOrderNonceBitmap[delegator_], nonce_);
    }

    function _useNonce(mapping(uint248 => uint256) storage words_, uint256 nonce_) private {
        (uint248 wordPos_, uint256 bit_) = _nonceParts(nonce_);
        uint256 word_ = words_[wordPos_];
        if (word_ & bit_ != 0) revert NonceAlreadyUsed();
        words_[wordPos_] = word_ | bit_;
    }

    function _nonceParts(uint256 nonce_) private pure returns (uint248 wordPos_, uint256 bit_) {
        wordPos_ = uint248(nonce_ >> 8);
        bit_ = 1 << (nonce_ & 0xff);
    }
}
