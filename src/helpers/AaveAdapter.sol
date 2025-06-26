// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IDelegationManager } from "../interfaces/IDelegationManager.sol";
import { IAavePool } from "./interfaces/IAavePool.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Delegation, ModeCode, Execution } from "../utils/Types.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

/// @title AaveAdapter
/// @notice Proof of concept adapter contract for Aave lending operations using delegations
/// @dev Handles token transfers and Aave supply operations through delegation-based permissions
contract AaveAdapter {
    using SafeERC20 for IERC20;

    IDelegationManager public immutable delegationManager;
    IAavePool public immutable aavePool;

    /// @notice Initializes the adapter with delegation manager and Aave pool addresses
    /// @param _delegationManager Address of the delegation manager contract
    /// @param _aavePool Address of the Aave lending pool contract
    constructor(address _delegationManager, address _aavePool) {
        delegationManager = IDelegationManager(_delegationManager);
        aavePool = IAavePool(_aavePool);
    }

    /// @notice Ensures sufficient token allowance for Aave operations
    /// @dev Checks current allowance and increases to max if needed
    /// @param _token Token to manage allowance for
    /// @param _amount Amount needed for the operation
    function _ensureAllowance(IERC20 _token, uint256 _amount) private {
        uint256 allowance_ = _token.allowance(address(this), address(aavePool));
        if (allowance_ < _amount) {
            _token.safeIncreaseAllowance(address(aavePool), type(uint256).max);
        }
    }

    /// @notice Supplies tokens to Aave using delegation-based token transfer
    /// @dev Only the delegator can execute this function, ensuring full control over supply parameters
    /// @param _delegations Array containing a single delegation for token transfer
    /// @param _token Address of the token to supply to Aave
    /// @param _amount Amount of tokens to supply
    function supplyByDelegation(Delegation[] memory _delegations, address _token, uint256 _amount) external {
        require(_delegations.length == 1, "Wrong number of delegations");
        require(_delegations[0].delegator == msg.sender, "Not allowed");

        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(_delegations);

        ModeCode[] memory encodedModes_ = new ModeCode[](1);
        encodedModes_[0] = ModeLib.encodeSimpleSingle();

        bytes[] memory executionCallDatas_ = new bytes[](1);

        bytes memory encodedTransfer_ = abi.encodeCall(IERC20.transfer, (address(this), _amount));
        executionCallDatas_[0] = ExecutionLib.encodeSingle(address(_token), 0, encodedTransfer_);

        delegationManager.redeemDelegations(permissionContexts_, encodedModes_, executionCallDatas_);

        _ensureAllowance(IERC20(_token), _amount);
        aavePool.supply(_token, _amount, msg.sender, 0);
    }

    /// @notice Supplies tokens to Aave using delegation-based token transfer with open-ended execution
    /// @dev Any delegate can execute this function, but aTokens are always credited to the delegator
    /// @param _delegations Array containing a single delegation for token transfer
    /// @param _token Address of the token to supply to Aave
    /// @param _amount Amount of tokens to supply
    function supplyByDelegationOpenEnded(Delegation[] memory _delegations, address _token, uint256 _amount) external {
        require(_delegations.length == 1, "Wrong number of delegations");

        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(_delegations);

        ModeCode[] memory encodedModes_ = new ModeCode[](1);
        encodedModes_[0] = ModeLib.encodeSimpleSingle();

        bytes[] memory executionCallDatas_ = new bytes[](1);

        bytes memory encodedTransfer_ = abi.encodeCall(IERC20.transfer, (address(this), _amount));
        executionCallDatas_[0] = ExecutionLib.encodeSingle(address(_token), 0, encodedTransfer_);

        delegationManager.redeemDelegations(permissionContexts_, encodedModes_, executionCallDatas_);

        _ensureAllowance(IERC20(_token), _amount);
        aavePool.supply(_token, _amount, _delegations[0].delegator, 0);
    }

    /// @notice Withdraws tokens from Aave using delegation-based aToken transfer
    /// @dev Only the delegator can execute this function, ensuring full control over withdrawal parameters
    /// @param _delegations Array containing a single delegation for aToken transfer
    /// @param _token Address of the underlying token to withdraw from Aave
    /// @param _amount Amount of tokens to withdraw (or type(uint256).max for all)
    function withdrawByDelegation(Delegation[] memory _delegations, address _token, uint256 _amount) external {
        require(_delegations.length == 1, "Wrong number of delegations");
        require(_delegations[0].delegator == msg.sender, "Not allowed");

        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(_delegations);

        ModeCode[] memory encodedModes_ = new ModeCode[](1);
        encodedModes_[0] = ModeLib.encodeSimpleSingle();

        bytes[] memory executionCallDatas_ = new bytes[](1);

        // Get the aToken address for the underlying token
        IERC20 aToken_ = IERC20(aavePool.getReserveAToken(_token));

        bytes memory encodedTransfer_ = abi.encodeCall(IERC20.transfer, (address(this), _amount));
        executionCallDatas_[0] = ExecutionLib.encodeSingle(address(aToken_), 0, encodedTransfer_);

        delegationManager.redeemDelegations(permissionContexts_, encodedModes_, executionCallDatas_);

        // Withdraw from Aave directly to the delegator
        aavePool.withdraw(_token, _amount, msg.sender);
    }

    /// @notice Withdraws tokens from Aave using delegation-based aToken transfer with open-ended execution
    /// @dev Any delegate can execute this function, but underlying tokens are always sent to the delegator
    /// @param _delegations Array containing a single delegation for aToken transfer
    /// @param _token Address of the underlying token to withdraw from Aave
    /// @param _amount Amount of tokens to withdraw (or type(uint256).max for all)
    function withdrawByDelegationOpenEnded(Delegation[] memory _delegations, address _token, uint256 _amount) external {
        require(_delegations.length == 1, "Wrong number of delegations");

        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(_delegations);

        ModeCode[] memory encodedModes_ = new ModeCode[](1);
        encodedModes_[0] = ModeLib.encodeSimpleSingle();

        bytes[] memory executionCallDatas_ = new bytes[](1);

        // Get the aToken address for the underlying token
        IERC20 aToken_ = IERC20(aavePool.getReserveAToken(_token));

        bytes memory encodedTransfer_ = abi.encodeCall(IERC20.transfer, (address(this), _amount));
        executionCallDatas_[0] = ExecutionLib.encodeSingle(address(aToken_), 0, encodedTransfer_);

        delegationManager.redeemDelegations(permissionContexts_, encodedModes_, executionCallDatas_);

        // Withdraw from Aave directly to the delegator
        aavePool.withdraw(_token, _amount, _delegations[0].delegator);
    }
}
