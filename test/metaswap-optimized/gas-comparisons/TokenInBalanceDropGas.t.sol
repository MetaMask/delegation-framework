// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { AllowedMethodsEnforcer } from "../../../src/enforcers/AllowedMethodsEnforcer.sol";
import { AllowedTargetsEnforcer } from "../../../src/enforcers/AllowedTargetsEnforcer.sol";
import { ERC20BalanceChangeEnforcer } from "../../../src/enforcers/ERC20BalanceChangeEnforcer.sol";
import { ExactExecutionEnforcer } from "../../../src/enforcers/ExactExecutionEnforcer.sol";
import { IdEnforcer } from "../../../src/enforcers/IdEnforcer.sol";
import { NativeBalanceChangeEnforcer } from "../../../src/enforcers/NativeBalanceChangeEnforcer.sol";
import { NativeTokenTransferAmountEnforcer } from "../../../src/enforcers/NativeTokenTransferAmountEnforcer.sol";
import { RedeemerEnforcer } from "../../../src/enforcers/RedeemerEnforcer.sol";
import { TimestampEnforcer } from "../../../src/enforcers/TimestampEnforcer.sol";
import { ValueLteEnforcer } from "../../../src/enforcers/ValueLteEnforcer.sol";
import { IMetaSwap } from "../../../src/helpers/interfaces/IMetaSwap.sol";
import { Caveat, Delegation, Execution, ModeCode } from "../../../src/utils/Types.sol";
import { GasComparisonFixture, LimitGasComparison } from "./GasComparisonFixture.t.sol";

/**
 * @notice Two delegations. An ERC-20 swap requires the user's `tokenIn` balance to fall by the signed amount.
 * @dev Native pays with `msg.value`, so that swap has no `tokenIn` balance check. Approve id is 2 and swap id is 1.
 */
contract TokenInBalanceDropGasTest is LimitGasComparison {
    uint256 private constant SWAP_ID = 1;
    uint256 private constant APPROVAL_ID = 2;

    AllowedTargetsEnforcer private allowedTargets;
    AllowedMethodsEnforcer private allowedMethods;
    ExactExecutionEnforcer private exactExecution;
    ValueLteEnforcer private valueLte;
    NativeTokenTransferAmountEnforcer private nativeTransferAmount;
    ERC20BalanceChangeEnforcer private erc20BalanceChange;
    NativeBalanceChangeEnforcer private nativeBalanceChange;
    TimestampEnforcer private timestampEnforcer;
    IdEnforcer private idEnforcer;
    RedeemerEnforcer private redeemerEnforcer;

    function _comparisonName() internal pure override returns (string memory) {
        return "TokenInBalanceDrop";
    }

    function _installComparison() internal override {
        allowedTargets = new AllowedTargetsEnforcer();
        allowedMethods = new AllowedMethodsEnforcer();
        exactExecution = new ExactExecutionEnforcer();
        valueLte = new ValueLteEnforcer();
        nativeTransferAmount = new NativeTokenTransferAmountEnforcer();
        erc20BalanceChange = new ERC20BalanceChangeEnforcer();
        nativeBalanceChange = new NativeBalanceChangeEnforcer();
        timestampEnforcer = new TimestampEnforcer();
        idEnforcer = new IdEnforcer();
        redeemerEnforcer = new RedeemerEnforcer();
        _installUser(address(delegationManager));
    }

    function _armLater(Shape shape_) internal override {
        _prepareLaterFill(shape_, address(idEnforcer), 0, true);
    }

    function _run(Shape shape_) internal override returns (uint256) {
        (Delegation[] memory chains_, ModeCode[] memory modes_, bytes[] memory executionCallDatas_) = _redemption(shape_);
        return _redeemDelegations(address(delegationManager), chains_, modes_, executionCallDatas_, shape_);
    }

    function _redemption(Shape shape_)
        private
        returns (Delegation[] memory chains_, ModeCode[] memory modes_, bytes[] memory executionCallDatas_)
    {
        if (shape_ == Shape.NativeToErc20) {
            chains_ = new Delegation[](1);
            modes_ = new ModeCode[](1);
            executionCallDatas_ = new bytes[](1);
            chains_[0] = _signRoot(ANY_DELEGATE, ROOT_AUTHORITY, delegationManager.getDomainHash(), _swapCaveats(shape_), 1);
            modes_[0] = _singleMode();
            Execution memory nativeSwap_ = _swapExecution(address(0), TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, address(tokenOut));
            executionCallDatas_[0] = ExecutionLib.encodeSingle(nativeSwap_.target, nativeSwap_.value, nativeSwap_.callData);
            return (chains_, modes_, executionCallDatas_);
        }

        chains_ = new Delegation[](2);
        modes_ = new ModeCode[](2);
        executionCallDatas_ = new bytes[](2);
        Execution memory approval_ = _approvalExecution(TOKEN_IN_AMOUNT);
        executionCallDatas_[0] = ExecutionLib.encodeSingle(approval_.target, approval_.value, approval_.callData);
        chains_[0] = _signRoot(
            ANY_DELEGATE, ROOT_AUTHORITY, delegationManager.getDomainHash(), _approvalCaveats(executionCallDatas_[0]), 1
        );
        modes_[0] = _singleMode();

        address tokenOut_ = shape_ == Shape.Erc20ToNative ? address(0) : address(tokenOut);
        Execution memory erc20Swap_ = _swapExecution(address(tokenIn), TOKEN_IN_AMOUNT, 0, tokenOut_);
        executionCallDatas_[1] = ExecutionLib.encodeSingle(erc20Swap_.target, erc20Swap_.value, erc20Swap_.callData);
        chains_[1] = _signRoot(ANY_DELEGATE, ROOT_AUTHORITY, delegationManager.getDomainHash(), _swapCaveats(shape_), 2);
        modes_[1] = _singleMode();
    }

    function _approvalCaveats(bytes memory executionTerms_) private view returns (Caveat[] memory caveats_) {
        caveats_ = new Caveat[](4);
        caveats_[0] = Caveat({ enforcer: address(exactExecution), terms: executionTerms_, args: hex"" });
        caveats_[1] = Caveat({ enforcer: address(timestampEnforcer), terms: _timestampTerms(), args: hex"" });
        caveats_[2] = Caveat({ enforcer: address(idEnforcer), terms: abi.encode(APPROVAL_ID), args: hex"" });
        caveats_[3] = Caveat({ enforcer: address(redeemerEnforcer), terms: _redeemerTerms(), args: hex"" });
    }

    function _swapCaveats(Shape shape_) private view returns (Caveat[] memory caveats_) {
        uint256 n_ = shape_ == Shape.NativeToErc20 ? 7 : 8;
        caveats_ = new Caveat[](n_);
        caveats_[0] = Caveat({ enforcer: address(allowedTargets), terms: abi.encodePacked(address(metaSwap)), args: hex"" });
        caveats_[1] = Caveat({ enforcer: address(allowedMethods), terms: abi.encodePacked(IMetaSwap.swap.selector), args: hex"" });
        uint256 i_ = 2;
        if (shape_ == Shape.NativeToErc20) {
            caveats_[i_++] = Caveat({ enforcer: address(nativeTransferAmount), terms: abi.encode(TOKEN_IN_AMOUNT), args: hex"" });
            caveats_[i_++] = Caveat({
                enforcer: address(erc20BalanceChange),
                terms: abi.encodePacked(false, address(tokenOut), user, TOKEN_OUT_MIN),
                args: hex""
            });
        } else {
            caveats_[i_++] = Caveat({ enforcer: address(valueLte), terms: abi.encode(uint256(0)), args: hex"" });
            caveats_[i_++] = Caveat({
                enforcer: address(erc20BalanceChange),
                terms: abi.encodePacked(true, address(tokenIn), user, TOKEN_IN_AMOUNT),
                args: hex""
            });
            if (shape_ == Shape.Erc20ToNative) {
                caveats_[i_++] = Caveat({
                    enforcer: address(nativeBalanceChange), terms: abi.encodePacked(false, user, TOKEN_OUT_MIN), args: hex""
                });
            } else {
                caveats_[i_++] = Caveat({
                    enforcer: address(erc20BalanceChange),
                    terms: abi.encodePacked(false, address(tokenOut), user, TOKEN_OUT_MIN),
                    args: hex""
                });
            }
        }
        caveats_[i_++] = Caveat({ enforcer: address(timestampEnforcer), terms: _timestampTerms(), args: hex"" });
        caveats_[i_++] = Caveat({ enforcer: address(idEnforcer), terms: abi.encode(SWAP_ID), args: hex"" });
        caveats_[i_] = Caveat({ enforcer: address(redeemerEnforcer), terms: _redeemerTerms(), args: hex"" });
    }
}
