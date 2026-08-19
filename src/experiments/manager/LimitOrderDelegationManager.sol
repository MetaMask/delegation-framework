// SPDX-License-Identifier: MIT AND Apache-2.0
/// forge-config: via_ir = true
pragma solidity 0.8.23;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib, CallType } from "@erc7579/lib/ModeLib.sol";

import { ICaveatEnforcer } from "../../interfaces/ICaveatEnforcer.sol";
import { IDelegationManager } from "../../interfaces/IDelegationManager.sol";
import { IDeleGatorCore } from "../../interfaces/IDeleGatorCore.sol";
import { Delegation, ModeCode, ExecType } from "../../utils/Types.sol";
import { CALLTYPE_SINGLE, EXECTYPE_DEFAULT } from "../../utils/Constants.sol";
import { EncoderLib } from "../../libraries/EncoderLib.sol";
import { ERC1271Lib } from "../../libraries/ERC1271Lib.sol";
import { OrderTermsLib } from "../partial-fill/OrderTermsLib.sol";

/**
 * @title LimitOrderDelegationManager
 * @notice P2 integrated manager for direct bilateral partial-fill RFQ limit orders.
 */
contract LimitOrderDelegationManager is IDelegationManager, ICaveatEnforcer, Ownable2Step, Pausable, EIP712 {
    using ModeLib for ModeCode;
    using ExecutionLib for bytes;
    using OrderTermsLib for OrderTermsLib.OrderTerms;

    string public constant NAME = "LimitOrderDelegationManager";
    string public constant VERSION = "1.0.0-experiment";
    string public constant DOMAIN_VERSION = "1";

    bytes32 public constant ROOT_AUTHORITY = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
    address public constant ANY_DELEGATE = address(0xa11);

    mapping(bytes32 delegationHash => uint256 filledSell) public filledSell;
    mapping(address maker => uint64 epoch) public makerEpoch;
    mapping(bytes32 delegationHash => bool isDisabled) public disabledDelegations;

    event EpochBumped(address indexed maker, uint64 newEpoch);
    event PartialFill(bytes32 indexed delegationHash, uint256 fillSell, uint256 buyAmount, uint256 totalFilled);

    error InvalidOrderProfile();
    error BuyTransferFailed();
    error MakerSellDeltaMismatch(uint256 expected, uint256 actual);
    error SolverSellDeltaMismatch(uint256 expected, uint256 actual);
    error ReceiverBuyDeltaInsufficient(uint256 required, uint256 actual);
    error SolverBuyDeltaInsufficient(uint256 required, uint256 actual);
    error OrderNotYetValid();
    error OrderExpired();
    error StaleEpoch(uint64 orderEpoch, uint64 currentEpoch);

    struct FillContext {
        bytes32 delegationHash;
        OrderTermsLib.OrderTerms terms;
        uint256 fillSellAmount;
        uint256 minBuyAmount;
        uint256 makerSellBefore;
        uint256 solverSellBefore;
        uint256 receiverBuyBefore;
        uint256 solverBuyBefore;
        address maker;
        address solver;
    }

    modifier onlyDeleGator(address delegator) {
        if (delegator != msg.sender) revert InvalidDelegator();
        _;
    }

    constructor(address _owner) Ownable(_owner) EIP712(NAME, DOMAIN_VERSION) {
        emit SetDomain(_domainSeparatorV4(), NAME, DOMAIN_VERSION, block.chainid, address(this));
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function bumpEpoch() external {
        uint64 newEpoch_ = makerEpoch[msg.sender] + 1;
        makerEpoch[msg.sender] = newEpoch_;
        emit EpochBumped(msg.sender, newEpoch_);
    }

    function disableDelegation(Delegation calldata _delegation) external onlyDeleGator(_delegation.delegator) {
        bytes32 delegationHash_ = getDelegationHash(_delegation);
        if (disabledDelegations[delegationHash_]) revert AlreadyDisabled();
        disabledDelegations[delegationHash_] = true;
        emit DisabledDelegation(delegationHash_, _delegation.delegator, _delegation.delegate, _delegation);
    }

    function enableDelegation(Delegation calldata _delegation) external onlyDeleGator(_delegation.delegator) {
        bytes32 delegationHash_ = getDelegationHash(_delegation);
        if (!disabledDelegations[delegationHash_]) revert AlreadyEnabled();
        disabledDelegations[delegationHash_] = false;
        emit EnabledDelegation(delegationHash_, _delegation.delegator, _delegation.delegate, _delegation);
    }

    function fillOrder(Delegation calldata _delegation, uint256 _fillSellAmount) external whenNotPaused {
        _fillOrder(_delegation, _fillSellAmount);
    }

    function redeemDelegations(
        bytes[] calldata _permissionContexts,
        ModeCode[] calldata _modes,
        bytes[] calldata _executionCallDatas
    )
        external
        whenNotPaused
    {
        if (_permissionContexts.length != 1 || _modes.length != 1 || _executionCallDatas.length != 1) {
            revert BatchDataLengthMismatch();
        }

        Delegation[] memory delegations_ = abi.decode(_permissionContexts[0], (Delegation[]));
        if (delegations_.length != 1) revert InvalidOrderProfile();

        Delegation memory delegation_ = delegations_[0];
        _validateDirectSettlementProfile(delegation_, _modes[0], _executionCallDatas[0]);

        uint256 fillSellAmount_ = _executionCallDataFillAmount(_executionCallDatas[0]);
        _fillOrder(delegation_, fillSellAmount_);
    }

    function getDomainHash() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function getDelegationHash(Delegation calldata _input) public pure returns (bytes32) {
        return EncoderLib._getDelegationHash(_input);
    }

    function beforeAllHook(bytes calldata, bytes calldata, ModeCode, bytes calldata, bytes32, address, address) external pure { }
    function beforeHook(bytes calldata, bytes calldata, ModeCode, bytes calldata, bytes32, address, address) external pure { }
    function afterHook(bytes calldata, bytes calldata, ModeCode, bytes calldata, bytes32, address, address) external pure { }
    function afterAllHook(bytes calldata, bytes calldata, ModeCode, bytes calldata, bytes32, address, address) external pure { }

    function _fillOrder(Delegation memory _delegation, uint256 _fillSellAmount) private {
        FillContext memory ctx_ = _prepareFill(_delegation, _fillSellAmount);
        _settleFill(_delegation, ctx_);
    }

    function _prepareFill(Delegation memory _delegation, uint256 _fillSellAmount)
        private
        returns (FillContext memory ctx_)
    {
        if (_delegation.delegate != msg.sender && _delegation.delegate != ANY_DELEGATE) revert InvalidDelegate();
        if (_delegation.authority != ROOT_AUTHORITY) revert InvalidAuthority();
        if (_delegation.caveats.length == 0 || _delegation.caveats[0].enforcer != address(this)) {
            revert InvalidOrderProfile();
        }

        ctx_.delegationHash = EncoderLib._getDelegationHash(_delegation);
        _validateSignature(
            _delegation.delegator,
            MessageHashUtils.toTypedDataHash(_domainSeparatorV4(), ctx_.delegationHash),
            _delegation.signature
        );
        if (disabledDelegations[ctx_.delegationHash]) revert CannotUseADisabledDelegation();

        ctx_.terms = OrderTermsLib.decodeTermsOnly(_delegation.caveats[0].terms);
        ctx_.terms.validateTerms();
        _validateTiming(ctx_.terms);
        _validateEpoch(ctx_.terms, _delegation.delegator);

        uint256 filledBefore_ = filledSell[ctx_.delegationHash];
        ctx_.terms.validateFill(filledBefore_, _fillSellAmount);
        ctx_.fillSellAmount = _fillSellAmount;
        ctx_.minBuyAmount = ctx_.terms.minBuyAmount(_fillSellAmount);
        ctx_.maker = _delegation.delegator;
        ctx_.solver = msg.sender;

        ctx_.makerSellBefore = IERC20(ctx_.terms.sellToken).balanceOf(ctx_.maker);
        ctx_.solverSellBefore = IERC20(ctx_.terms.sellToken).balanceOf(ctx_.solver);
        ctx_.receiverBuyBefore = IERC20(ctx_.terms.buyToken).balanceOf(ctx_.terms.receiver);
        ctx_.solverBuyBefore = IERC20(ctx_.terms.buyToken).balanceOf(ctx_.solver);

        filledSell[ctx_.delegationHash] = filledBefore_ + _fillSellAmount;
    }

    function _settleFill(Delegation memory _delegation, FillContext memory _ctx) private {
        if (!IERC20(_ctx.terms.buyToken).transferFrom(_ctx.solver, _ctx.terms.receiver, _ctx.minBuyAmount)) {
            revert BuyTransferFailed();
        }

        bytes memory executionCalldata_ = ExecutionLib.encodeSingle(
            _ctx.terms.sellToken, 0, abi.encodeCall(IERC20.transfer, (_ctx.solver, _ctx.fillSellAmount))
        );
        IDeleGatorCore(_ctx.maker).executeFromExecutor(ModeLib.encodeSimpleSingle(), executionCalldata_);

        if (_ctx.makerSellBefore - IERC20(_ctx.terms.sellToken).balanceOf(_ctx.maker) != _ctx.fillSellAmount) {
            revert MakerSellDeltaMismatch(_ctx.fillSellAmount, _ctx.makerSellBefore - IERC20(_ctx.terms.sellToken).balanceOf(_ctx.maker));
        }
        if (IERC20(_ctx.terms.sellToken).balanceOf(_ctx.solver) - _ctx.solverSellBefore != _ctx.fillSellAmount) {
            revert SolverSellDeltaMismatch(_ctx.fillSellAmount, IERC20(_ctx.terms.sellToken).balanceOf(_ctx.solver) - _ctx.solverSellBefore);
        }
        if (IERC20(_ctx.terms.buyToken).balanceOf(_ctx.terms.receiver) - _ctx.receiverBuyBefore < _ctx.minBuyAmount) {
            revert ReceiverBuyDeltaInsufficient(_ctx.minBuyAmount, IERC20(_ctx.terms.buyToken).balanceOf(_ctx.terms.receiver) - _ctx.receiverBuyBefore);
        }
        if (_ctx.solverBuyBefore - IERC20(_ctx.terms.buyToken).balanceOf(_ctx.solver) < _ctx.minBuyAmount) {
            revert SolverBuyDeltaInsufficient(_ctx.minBuyAmount, _ctx.solverBuyBefore - IERC20(_ctx.terms.buyToken).balanceOf(_ctx.solver));
        }

        emit RedeemedDelegation(_ctx.maker, _ctx.solver, _delegation);
        emit PartialFill(_ctx.delegationHash, _ctx.fillSellAmount, _ctx.minBuyAmount, filledSell[_ctx.delegationHash]);
    }

    function _validateDirectSettlementProfile(
        Delegation memory _delegation,
        ModeCode _mode,
        bytes calldata _executionCallData
    )
        private
        view
    {
        if (_delegation.authority != ROOT_AUTHORITY) revert InvalidAuthority();
        if (_delegation.caveats.length == 0 || _delegation.caveats[0].enforcer != address(this)) revert InvalidOrderProfile();
        if (CallType.unwrap(ModeLib.getCallType(_mode)) != CallType.unwrap(CALLTYPE_SINGLE)) revert InvalidOrderProfile();
        (, ExecType execType_,,) = _mode.decode();
        if (ExecType.unwrap(execType_) != ExecType.unwrap(EXECTYPE_DEFAULT)) revert InvalidOrderProfile();

        OrderTermsLib.OrderTerms memory terms_ = OrderTermsLib.decodeTermsOnly(_delegation.caveats[0].terms);
        (address target_, uint256 value_, bytes calldata callData_) = _executionCallData.decodeSingle();
        if (target_ != terms_.sellToken || value_ != 0) revert InvalidOrderProfile();
        if (bytes4(callData_[:4]) != IERC20.transfer.selector) revert InvalidOrderProfile();

        (address to_,) = abi.decode(callData_[4:], (address, uint256));
        if (to_ != msg.sender) revert InvalidOrderProfile();
    }

    function _executionCallDataFillAmount(bytes calldata _executionCallData) private pure returns (uint256 fillAmount_) {
        (,, bytes calldata callData_) = _executionCallData.decodeSingle();
        (, fillAmount_) = abi.decode(callData_[4:], (address, uint256));
    }

    function _validateTiming(OrderTermsLib.OrderTerms memory _terms) private view {
        if (_terms.validAfter != 0 && block.timestamp <= _terms.validAfter) revert OrderNotYetValid();
        if (_terms.validUntil != 0 && block.timestamp >= _terms.validUntil) revert OrderExpired();
    }

    function _validateEpoch(OrderTermsLib.OrderTerms memory _terms, address _delegator) private view {
        if (_terms.epoch != makerEpoch[_delegator]) revert StaleEpoch(_terms.epoch, makerEpoch[_delegator]);
    }

    function _validateSignature(address _delegator, bytes32 _typedDataHash, bytes memory _signature) private view {
        if (_delegator.code.length == 0) {
            if (ECDSA.recover(_typedDataHash, _signature) != _delegator) revert InvalidEOASignature();
            return;
        }

        if (IERC1271(_delegator).isValidSignature(_typedDataHash, _signature) != ERC1271Lib.EIP1271_MAGIC_VALUE) {
            revert InvalidERC1271Signature();
        }
    }
}
