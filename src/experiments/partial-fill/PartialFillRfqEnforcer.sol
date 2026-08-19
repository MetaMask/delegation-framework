// SPDX-License-Identifier: MIT AND Apache-2.0
/// forge-config: via_ir = true
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { CaveatEnforcer } from "../../enforcers/CaveatEnforcer.sol";
import { ModeCode } from "../../utils/Types.sol";
import { OrderTermsLib } from "./OrderTermsLib.sol";

/**
 * @title PartialFillRfqEnforcer
 * @notice P1 combined before/after enforcer for partial-fill RFQ orders on the canonical manager.
 * @dev Tracks cumulative filled sell volume, pulls buy-side payment from the redeemer in `beforeAllHook`,
 *      updates fill state before execution, and verifies balance deltas in `afterHook`. Reverts atomically
 *      on failed payment, invalid execution, or fee-on-transfer sell tokens.
 */
contract PartialFillRfqEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;
    using SafeERC20 for IERC20;
    using OrderTermsLib for OrderTermsLib.OrderTerms;

    struct FillSnapshot {
        uint256 makerSellBefore;
        uint256 solverSellBefore;
        uint256 receiverBuyBefore;
        uint256 solverBuyBefore;
        uint256 fillSellAmount;
        uint256 minBuyAmount;
    }

    mapping(bytes32 delegationHash => uint256 filledSell) public filledSell;
    mapping(address maker => uint64 epoch) public makerEpoch;
    mapping(bytes32 delegationHash => FillSnapshot snapshot) private _snapshots;
    mapping(bytes32 delegationHash => bool locked) private _locked;

    event EpochBumped(address indexed maker, uint64 newEpoch);
    event PartialFill(bytes32 indexed delegationHash, uint256 fillSell, uint256 buyAmount, uint256 totalFilled);

    error EnforcerLocked();
    error OrderExpired();
    error OrderNotYetValid();
    error StaleEpoch(uint64 orderEpoch, uint64 currentEpoch);
    error InvalidSettlementAdapter();
    error InvalidExecution();
    error BuyTransferFailed();
    error MakerSellDeltaMismatch(uint256 expected, uint256 actual);
    error SolverSellDeltaMismatch(uint256 expected, uint256 actual);
    error ReceiverBuyDeltaInsufficient(uint256 required, uint256 actual);
    error SolverBuyDeltaInsufficient(uint256 required, uint256 actual);

    function bumpEpoch() external {
        uint64 newEpoch_ = makerEpoch[msg.sender] + 1;
        makerEpoch[msg.sender] = newEpoch_;
        emit EpochBumped(msg.sender, newEpoch_);
    }

    function beforeAllHook(
        bytes calldata _terms,
        bytes calldata _args,
        ModeCode _mode,
        bytes calldata _executionCallData,
        bytes32 _delegationHash,
        address _delegator,
        address _redeemer
    )
        public
        override
        onlySingleCallTypeMode(_mode)
        onlyDefaultExecutionMode(_mode)
    {
        if (_locked[_delegationHash]) revert EnforcerLocked();
        _locked[_delegationHash] = true;
        _runBeforeAll(_terms, _args, _executionCallData, _delegationHash, _delegator, _redeemer);
    }

    function _runBeforeAll(
        bytes calldata _terms,
        bytes calldata _args,
        bytes calldata _executionCallData,
        bytes32 _delegationHash,
        address _delegator,
        address _redeemer
    )
        private
    {
        (OrderTermsLib.OrderTerms memory terms_, address settlementAdapter_) = OrderTermsLib.decodeTermsCalldata(_terms);
        uint256 fillSellAmount_ = abi.decode(_args, (uint256));
        _validateFillTerms(terms_, fillSellAmount_, _delegationHash, _delegator);
        _validateExecution(terms_, settlementAdapter_, fillSellAmount_, _redeemer, _executionCallData);
        _commitBeforeAll(terms_, fillSellAmount_, _delegationHash, _delegator, _redeemer);
    }

    function _validateFillTerms(
        OrderTermsLib.OrderTerms memory _terms,
        uint256 _fillSellAmount,
        bytes32 _delegationHash,
        address _delegator
    )
        private
        view
    {
        _terms.validateTerms();
        _validateTiming(_terms);
        _validateEpoch(_terms, _delegator);
        _terms.validateFill(filledSell[_delegationHash], _fillSellAmount);
    }

    function _commitBeforeAll(
        OrderTermsLib.OrderTerms memory _terms,
        uint256 _fillSellAmount,
        bytes32 _delegationHash,
        address _delegator,
        address _redeemer
    )
        private
    {
        uint256 minBuyAmount_ = _terms.minBuyAmount(_fillSellAmount);

        _snapshots[_delegationHash] = FillSnapshot({
            makerSellBefore: IERC20(_terms.sellToken).balanceOf(_delegator),
            solverSellBefore: IERC20(_terms.sellToken).balanceOf(_redeemer),
            receiverBuyBefore: IERC20(_terms.buyToken).balanceOf(_terms.receiver),
            solverBuyBefore: IERC20(_terms.buyToken).balanceOf(_redeemer),
            fillSellAmount: _fillSellAmount,
            minBuyAmount: minBuyAmount_
        });

        filledSell[_delegationHash] = filledSell[_delegationHash] + _fillSellAmount;

        if (!IERC20(_terms.buyToken).transferFrom(_redeemer, _terms.receiver, minBuyAmount_)) {
            revert BuyTransferFailed();
        }
    }

    function beforeHook(bytes calldata, bytes calldata, ModeCode, bytes calldata, bytes32, address, address)
        public
        pure
        override
    { }

    function afterHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode,
        bytes calldata,
        bytes32 _delegationHash,
        address _delegator,
        address _redeemer
    )
        public
        override
    {
        _finalizeAfterHook(_terms, _delegationHash, _delegator, _redeemer);
    }

    function _finalizeAfterHook(
        bytes calldata _terms,
        bytes32 _delegationHash,
        address _delegator,
        address _redeemer
    )
        private
    {
        FillSnapshot memory snap_ = _snapshots[_delegationHash];
        (OrderTermsLib.OrderTerms memory terms_,) = OrderTermsLib.decodeTermsCalldata(_terms);
        _verifyAfterHookDeltas(terms_, snap_, _delegator, _redeemer);

        delete _snapshots[_delegationHash];
        _locked[_delegationHash] = false;

        emit PartialFill(_delegationHash, snap_.fillSellAmount, snap_.minBuyAmount, filledSell[_delegationHash]);
    }

    function _verifyAfterHookDeltas(
        OrderTermsLib.OrderTerms memory _terms,
        FillSnapshot memory _snap,
        address _delegator,
        address _redeemer
    )
        private
        view
    {
        uint256 makerSellDelta_ = _snap.makerSellBefore - IERC20(_terms.sellToken).balanceOf(_delegator);
        if (makerSellDelta_ != _snap.fillSellAmount) revert MakerSellDeltaMismatch(_snap.fillSellAmount, makerSellDelta_);

        uint256 solverSellDelta_ = IERC20(_terms.sellToken).balanceOf(_redeemer) - _snap.solverSellBefore;
        if (solverSellDelta_ != _snap.fillSellAmount) revert SolverSellDeltaMismatch(_snap.fillSellAmount, solverSellDelta_);

        uint256 receiverBuyDelta_ = IERC20(_terms.buyToken).balanceOf(_terms.receiver) - _snap.receiverBuyBefore;
        if (receiverBuyDelta_ < _snap.minBuyAmount) revert ReceiverBuyDeltaInsufficient(_snap.minBuyAmount, receiverBuyDelta_);

        uint256 solverBuyDelta_ = _snap.solverBuyBefore - IERC20(_terms.buyToken).balanceOf(_redeemer);
        if (solverBuyDelta_ < _snap.minBuyAmount) revert SolverBuyDeltaInsufficient(_snap.minBuyAmount, solverBuyDelta_);
    }

    function afterAllHook(bytes calldata, bytes calldata, ModeCode, bytes calldata, bytes32 _delegationHash, address, address)
        public
        override
    {
        if (_locked[_delegationHash]) {
            delete _snapshots[_delegationHash];
            _locked[_delegationHash] = false;
        }
    }

    function getTermsInfo(bytes calldata _terms)
        external
        pure
        returns (OrderTermsLib.OrderTerms memory terms_, address settlementAdapter_)
    {
        return OrderTermsLib.decodeTermsCalldata(_terms);
    }

    function _validateTiming(OrderTermsLib.OrderTerms memory _terms) private view {
        if (_terms.validAfter != 0 && block.timestamp <= _terms.validAfter) revert OrderNotYetValid();
        if (_terms.validUntil != 0 && block.timestamp >= _terms.validUntil) revert OrderExpired();
    }

    function _validateEpoch(OrderTermsLib.OrderTerms memory _terms, address _delegator) private view {
        if (_terms.epoch != makerEpoch[_delegator]) revert StaleEpoch(_terms.epoch, makerEpoch[_delegator]);
    }

    function _validateExecution(
        OrderTermsLib.OrderTerms memory _terms,
        address _settlementAdapter,
        uint256 _fillSellAmount,
        address _redeemer,
        bytes calldata _executionCallData
    )
        private
        view
    {
        if (_settlementAdapter == address(0)) revert InvalidSettlementAdapter();

        (address target_, uint256 value_, bytes calldata callData_) = _executionCallData.decodeSingle();
        if (target_ != _terms.sellToken || value_ != 0) revert InvalidExecution();
        if (bytes4(callData_[:4]) != IERC20.transfer.selector) revert InvalidExecution();

        (address to_, uint256 amount_) = abi.decode(callData_[4:], (address, uint256));
        if (to_ != _redeemer || amount_ != _fillSellAmount) revert InvalidExecution();
    }
}
