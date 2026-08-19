// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ExecutionHelper } from "@erc7579/core/ExecutionHelper.sol";

import { IDelegationManager } from "../../interfaces/IDelegationManager.sol";
import { CallType, ExecType, ModeCode } from "../../utils/Types.sol";
import { CALLTYPE_SINGLE, EXECTYPE_DEFAULT } from "../../utils/Constants.sol";

contract LimitOrderSwapAdapter is ExecutionHelper {
    using SafeERC20 for IERC20;
    using ModeLib for ModeCode;
    using ExecutionLib for bytes;

    IDelegationManager public immutable delegationManager;
    mapping(address router => bool allowed) public isRouterAllowed;

    error NotDelegationManager();
    error RouterNotAllowed(address router);
    error IdenticalTokens();
    error InsufficientBuyDelivered(uint256 required, uint256 received);
    error InvalidZeroAddress();
    error UnsupportedCallType(CallType callType);
    error UnsupportedExecType(ExecType execType);

    modifier onlyDelegationManager() {
        if (msg.sender != address(delegationManager)) revert NotDelegationManager();
        _;
    }

    constructor(IDelegationManager _delegationManager) {
        if (address(_delegationManager) == address(0)) revert InvalidZeroAddress();
        delegationManager = _delegationManager;
    }

    receive() external payable { }

    function swap(
        IERC20 _sellToken,
        IERC20 _buyToken,
        uint256 _sellAmount,
        uint256 _minBuyAmount,
        address _receiver,
        address _router,
        bytes calldata _routerCalldata
    )
        external
    {
        if (_sellToken == _buyToken) revert IdenticalTokens();
        if (!isRouterAllowed[_router]) revert RouterNotAllowed(_router);

        _sellToken.safeTransferFrom(msg.sender, address(this), _sellAmount);
        uint256 buyBefore_ = _buyToken.balanceOf(_receiver);
        _sellToken.forceApprove(_router, _sellAmount);

        (bool ok_,) = _router.call(_routerCalldata);
        require(ok_, "LimitOrderSwapAdapter:router-call-failed");

        uint256 buyReceived_ = _buyToken.balanceOf(_receiver) - buyBefore_;
        if (buyReceived_ < _minBuyAmount) revert InsufficientBuyDelivered(_minBuyAmount, buyReceived_);
    }

    function executeFromExecutor(
        ModeCode _mode,
        bytes calldata _executionCalldata
    )
        external
        payable
        onlyDelegationManager
        returns (bytes[] memory returnData_)
    {
        (CallType callType_, ExecType execType_,,) = _mode.decode();
        if (CallType.unwrap(CALLTYPE_SINGLE) != CallType.unwrap(callType_)) revert UnsupportedCallType(callType_);
        if (ExecType.unwrap(EXECTYPE_DEFAULT) != ExecType.unwrap(execType_)) revert UnsupportedExecType(execType_);

        (address target_, uint256 value_, bytes calldata callData_) = _executionCalldata.decodeSingle();
        returnData_ = new bytes[](1);
        returnData_[0] = _execute(target_, value_, callData_);
    }

    function setRouterAllowed(address _router, bool _allowed) external {
        isRouterAllowed[_router] = _allowed;
    }
}
