// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { IDelegationManager } from "../../../../src/interfaces/IDelegationManager.sol";
import { Delegation, ModeCode } from "../../../../src/utils/Types.sol";
import { MockSwapProtocol } from "./MockSwapProtocol.sol";

/**
 * @notice Exposes two token-acquisition paths around one shared swap implementation.
 * @dev This contract is benchmark-only. It intentionally leaves policy to the supplied delegation so the
 *      measurement isolates external batch acquisition from adapter-initiated redemption.
 */
contract TokenAcquisitionBenchmarkAdapter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IDelegationManager public immutable delegationManager;
    MockSwapProtocol public immutable swapProtocol;

    event SwapExecuted(
        address indexed recipient, IERC20 indexed tokenIn, IERC20 indexed tokenOut, uint256 tokenInAmount, uint256 tokenOutAmount
    );

    error InvalidDelegationChain();
    error UnexpectedInputBalance(uint256 expected, uint256 actual);

    constructor(IDelegationManager _delegationManager, MockSwapProtocol _swapProtocol) {
        delegationManager = _delegationManager;
        swapProtocol = _swapProtocol;
    }

    /**
     * @notice Swaps tokens transferred to this adapter by the preceding execution in an atomic batch.
     */
    function swapPrefunded(IERC20 _tokenIn, IERC20 _tokenOut, uint256 _tokenInAmount) external nonReentrant {
        _swap(_tokenIn, _tokenOut, _tokenInAmount, msg.sender);
    }

    /**
     * @notice Redeems a delegation internally to acquire input before running the same swap implementation.
     */
    function swapByDelegation(
        Delegation[] calldata _delegations,
        IERC20 _tokenIn,
        IERC20 _tokenOut,
        uint256 _tokenInAmount
    )
        external
        nonReentrant
    {
        uint256 delegationCount_ = _delegations.length;
        if (delegationCount_ == 0) revert InvalidDelegationChain();

        address rootDelegator_ = _delegations[delegationCount_ - 1].delegator;

        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(_delegations);

        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = ModeLib.encodeSimpleSingle();

        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] =
            ExecutionLib.encodeSingle(address(_tokenIn), 0, abi.encodeCall(IERC20.transfer, (address(this), _tokenInAmount)));

        delegationManager.redeemDelegations(permissionContexts_, modes_, executionCallDatas_);

        _swap(_tokenIn, _tokenOut, _tokenInAmount, rootDelegator_);
    }

    function _swap(
        IERC20 _tokenIn,
        IERC20 _tokenOut,
        uint256 _tokenInAmount,
        address _recipient
    )
        private
        returns (uint256 tokenOutAmount_)
    {
        uint256 inputBalance_ = _tokenIn.balanceOf(address(this));
        if (inputBalance_ != _tokenInAmount) revert UnexpectedInputBalance(_tokenInAmount, inputBalance_);

        _tokenIn.forceApprove(address(swapProtocol), _tokenInAmount);
        tokenOutAmount_ = swapProtocol.swap(_tokenIn, _tokenOut, _tokenInAmount, address(this));
        _tokenOut.safeTransfer(_recipient, tokenOutAmount_);

        emit SwapExecuted(_recipient, _tokenIn, _tokenOut, _tokenInAmount, tokenOutAmount_);
    }
}
