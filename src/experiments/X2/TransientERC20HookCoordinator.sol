// SPDX-License-Identifier: MIT AND Apache-2.0
/// forge-config: evm_version = 'cancun'
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { CaveatEnforcer } from "../../enforcers/CaveatEnforcer.sol";
import { ModeCode } from "../../utils/Types.sol";
import { TransientStorageLib } from "./TransientStorageLib.sol";

/**
 * @title TransientERC20HookCoordinator
 * @notice X2 experiment: before/after ERC-20 balance coordination via EIP-1153 transient storage.
 * @dev Portable control is `PersistentERC20HookCoordinator` in the same folder.
 */
contract TransientERC20HookCoordinator is CaveatEnforcer {
    bytes32 private constant LOCK_SLOT = keccak256("X2.transient.lock");
    bytes32 private constant BALANCE_SLOT = keccak256("X2.transient.balance");

    function beforeHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode _mode,
        bytes calldata,
        bytes32,
        address,
        address
    )
        public
        override
        onlyDefaultExecutionMode(_mode)
    {
        (, address token_, address recipient_,) = getTermsInfo(_terms);
        require(!TransientStorageLib.tloadBool(LOCK_SLOT), "TransientERC20HookCoordinator:locked");
        TransientStorageLib.tstoreBool(LOCK_SLOT, true);
        TransientStorageLib.tstore(BALANCE_SLOT, IERC20(token_).balanceOf(recipient_));
    }

    function afterHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode,
        bytes calldata,
        bytes32,
        address,
        address
    )
        public
        override
    {
        (bool enforceDecrease_, address token_, address recipient_, uint256 amount_) = getTermsInfo(_terms);
        uint256 cached_ = TransientStorageLib.tload(BALANCE_SLOT);
        TransientStorageLib.tstoreBool(LOCK_SLOT, false);
        TransientStorageLib.tstore(BALANCE_SLOT, 0);

        uint256 balance_ = IERC20(token_).balanceOf(recipient_);
        if (enforceDecrease_) {
            require(balance_ >= cached_ - amount_, "TransientERC20HookCoordinator:exceeded-decrease");
        } else {
            require(balance_ >= cached_ + amount_, "TransientERC20HookCoordinator:insufficient-increase");
        }
    }

    function getTermsInfo(bytes calldata _terms)
        public
        pure
        returns (bool enforceDecrease_, address token_, address recipient_, uint256 amount_)
    {
        require(_terms.length == 73, "TransientERC20HookCoordinator:invalid-terms");
        enforceDecrease_ = _terms[0] != 0;
        token_ = address(bytes20(_terms[1:21]));
        recipient_ = address(bytes20(_terms[21:41]));
        amount_ = uint256(bytes32(_terms[41:]));
    }
}
