// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ServiceInstructionTypes } from "./ServiceInstructionTypes.sol";
import { SignedExecutionEnforcer } from "./SignedExecutionEnforcer.sol";
import { ModeCode } from "../../utils/Types.sol";

contract SignedExecutionReceiptEnforcer is SignedExecutionEnforcer {
    mapping(bytes32 receiptKey => uint256 balanceBefore) internal balanceBeforeCache;

    function beforeHook(
        bytes calldata _terms,
        bytes calldata _args,
        ModeCode _mode,
        bytes calldata _executionCallData,
        bytes32 _delegationHash,
        address _delegator,
        address
    )
        public
        override
        onlySingleCallTypeMode(_mode)
        onlyDefaultExecutionMode(_mode)
    {
        super.beforeHook(_terms, _args, _mode, _executionCallData, _delegationHash, _delegator, address(0));

        ServiceInstructionTypes.ServiceAttestation memory attestation_ =
            abi.decode(_args, (ServiceInstructionTypes.ServiceAttestation));
        bytes32 key_ = _receiptKey(_delegationHash, attestation_.instruction);
        balanceBeforeCache[key_] = IERC20(attestation_.instruction.buyToken).balanceOf(attestation_.instruction.receiver);
    }

    function afterHook(
        bytes calldata,
        bytes calldata _args,
        ModeCode,
        bytes calldata,
        bytes32 _delegationHash,
        address,
        address
    )
        public
        override
    {
        ServiceInstructionTypes.ServiceAttestation memory attestation_ =
            abi.decode(_args, (ServiceInstructionTypes.ServiceAttestation));
        ServiceInstructionTypes.ServiceInstruction memory instruction_ = attestation_.instruction;

        bytes32 key_ = _receiptKey(_delegationHash, instruction_);
        uint256 before_ = balanceBeforeCache[key_];
        delete balanceBeforeCache[key_];

        uint256 after_ = IERC20(instruction_.buyToken).balanceOf(instruction_.receiver);
        require(after_ >= before_ + instruction_.minBuyAmount, "SignedExecutionReceiptEnforcer:insufficient-balance-increase");
    }

    function _receiptKey(
        bytes32 _delegationHash,
        ServiceInstructionTypes.ServiceInstruction memory _instruction
    )
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(_delegationHash, _instruction.nonce, _instruction.executionHash));
    }
}
