// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { ServiceInstructionTypes } from "./ServiceInstructionTypes.sol";
import { ServiceInstructionLib } from "./ServiceInstructionLib.sol";
import { CaveatEnforcer } from "../../enforcers/CaveatEnforcer.sol";
import { ModeCode } from "../../utils/Types.sol";

contract SignedExecutionEnforcer is CaveatEnforcer {
    using ModeLib for ModeCode;
    using ExecutionLib for bytes;

    mapping(address manager => mapping(bytes32 delegationHash => mapping(uint256 nonce => bool used))) public usedNonces;

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
        virtual
        override
        onlySingleCallTypeMode(_mode)
        onlyDefaultExecutionMode(_mode)
    {
        ServiceInstructionTypes.MakerBounds memory bounds_ = ServiceInstructionLib.decodeMakerBoundsTerms(_terms);
        ServiceInstructionTypes.ServiceAttestation memory attestation_ =
            abi.decode(_args, (ServiceInstructionTypes.ServiceAttestation));

        _validateAttestation(
            bounds_, attestation_.instruction, attestation_.signature, _mode, _executionCallData, _delegationHash, _delegator
        );
    }

    function _validateAttestation(
        ServiceInstructionTypes.MakerBounds memory _bounds,
        ServiceInstructionTypes.ServiceInstruction memory _instruction,
        bytes memory _signature,
        ModeCode _mode,
        bytes calldata _executionCallData,
        bytes32 _delegationHash,
        address _delegator
    )
        internal
    {
        require(block.timestamp >= _instruction.issuedAt, "SignedExecutionEnforcer:quote-not-yet-valid");
        require(block.timestamp < _instruction.expiresAt, "SignedExecutionEnforcer:quote-expired");
        if (_bounds.maxQuoteLifetime > 0) {
            require(
                _instruction.expiresAt - _instruction.issuedAt <= _bounds.maxQuoteLifetime,
                "SignedExecutionEnforcer:quote-ttl-exceeded"
            );
        }

        require(
            keccak256(_executionCallData) == _instruction.executionHash, "SignedExecutionEnforcer:execution-hash-mismatch"
        );
        require(ModeCode.unwrap(_mode) == ModeCode.unwrap(_instruction.mode), "SignedExecutionEnforcer:mode-mismatch");
        require(_instruction.delegationHash == _delegationHash, "SignedExecutionEnforcer:delegation-hash-mismatch");
        require(_instruction.maker == _delegator, "SignedExecutionEnforcer:maker-mismatch");
        require(_instruction.chainId == block.chainid, "SignedExecutionEnforcer:chain-mismatch");
        require(_instruction.manager == msg.sender, "SignedExecutionEnforcer:manager-mismatch");
        require(_instruction.enforcer == address(this), "SignedExecutionEnforcer:enforcer-mismatch");
        require(_instruction.sellToken == _bounds.sellToken, "SignedExecutionEnforcer:sell-token-mismatch");
        require(_instruction.buyToken == _bounds.buyToken, "SignedExecutionEnforcer:buy-token-mismatch");
        require(_instruction.receiver == _bounds.receiver, "SignedExecutionEnforcer:receiver-mismatch");
        require(_instruction.sellAmount <= _bounds.maxSellAmount, "SignedExecutionEnforcer:sell-amount-exceeded");
        require(_instruction.minBuyAmount >= _bounds.minBuyAmount, "SignedExecutionEnforcer:min-buy-violation");

        (address target_,,) = _executionCallData.decodeSingle();
        require(target_ == _bounds.adapter, "SignedExecutionEnforcer:adapter-mismatch");

        require(!usedNonces[msg.sender][_delegationHash][_instruction.nonce], "SignedExecutionEnforcer:nonce-reused");
        usedNonces[msg.sender][_delegationHash][_instruction.nonce] = true;

        address recovered_ = ServiceInstructionLib.recoverSigner(_instruction, _signature, _bounds.quoteSigner);
        require(recovered_ == _bounds.quoteSigner, "SignedExecutionEnforcer:invalid-signer");
    }
}
