// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { CaveatEnforcer } from "../../enforcers/CaveatEnforcer.sol";
import { ModeCode } from "../../utils/Types.sol";

/**
 * @title PersistentERC20HookCoordinator
 * @notice X2 portable control: same semantics as `TransientERC20HookCoordinator` using persistent storage.
 */
contract PersistentERC20HookCoordinator is CaveatEnforcer {
    mapping(bytes32 hashKey => uint256 balance) public balanceCache;
    mapping(bytes32 hashKey => bool lock) public isLocked;

    function beforeHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode _mode,
        bytes calldata,
        bytes32 _delegationHash,
        address,
        address _redeemer
    )
        public
        override
        onlyDefaultExecutionMode(_mode)
    {
        (, address token_, address recipient_,) = getTermsInfo(_terms);
        bytes32 hashKey_ = _getHashKey(_redeemer, token_, _delegationHash);
        require(!isLocked[hashKey_], "PersistentERC20HookCoordinator:locked");
        isLocked[hashKey_] = true;
        balanceCache[hashKey_] = IERC20(token_).balanceOf(recipient_);
    }

    function afterHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode,
        bytes calldata,
        bytes32 _delegationHash,
        address,
        address _redeemer
    )
        public
        override
    {
        (bool enforceDecrease_, address token_, address recipient_, uint256 amount_) = getTermsInfo(_terms);
        bytes32 hashKey_ = _getHashKey(_redeemer, token_, _delegationHash);
        delete isLocked[hashKey_];
        uint256 cached_ = balanceCache[hashKey_];
        delete balanceCache[hashKey_];

        uint256 balance_ = IERC20(token_).balanceOf(recipient_);
        if (enforceDecrease_) {
            require(balance_ >= cached_ - amount_, "PersistentERC20HookCoordinator:exceeded-decrease");
        } else {
            require(balance_ >= cached_ + amount_, "PersistentERC20HookCoordinator:insufficient-increase");
        }
    }

    function getTermsInfo(bytes calldata _terms)
        public
        pure
        returns (bool enforceDecrease_, address token_, address recipient_, uint256 amount_)
    {
        require(_terms.length == 73, "PersistentERC20HookCoordinator:invalid-terms");
        enforceDecrease_ = _terms[0] != 0;
        token_ = address(bytes20(_terms[1:21]));
        recipient_ = address(bytes20(_terms[21:41]));
        amount_ = uint256(bytes32(_terms[41:]));
    }

    function _getHashKey(address _caller, address _token, bytes32 _delegationHash) private pure returns (bytes32) {
        return keccak256(abi.encode(_caller, _token, _delegationHash));
    }
}
