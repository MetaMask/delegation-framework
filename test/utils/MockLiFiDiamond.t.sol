// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockLiFiDiamond
 * @notice Minimal LiFi Diamond mock for LiFiSwapEnforcer tests.
 */
contract MockLiFiDiamond {
    using SafeERC20 for IERC20;

    struct SwapData {
        address callTo;
        address approveTo;
        address sendingAssetId;
        address receivingAssetId;
        uint256 fromAmount;
        bytes callData;
        bool requiresDeposit;
    }

    function swapTokensSingleV3ERC20ToERC20(
        bytes32,
        string calldata,
        string calldata,
        address payable _receiver,
        uint256 _minAmountOut,
        SwapData calldata _swapData
    )
        external
    {
        IERC20 sendingAsset_ = IERC20(_swapData.sendingAssetId);
        IERC20 receivingAsset_ = IERC20(_swapData.receivingAssetId);

        sendingAsset_.safeTransferFrom(msg.sender, address(this), _swapData.fromAmount);

        uint256 amountReceived_ = receivingAsset_.balanceOf(address(this));
        if (amountReceived_ < _minAmountOut) {
            revert("MockLiFiDiamond:slippage-too-high");
        }

        receivingAsset_.safeTransfer(_receiver, amountReceived_);
    }

    function execute(bytes calldata) external pure {
        return;
    }

    /// @notice Mock swap: ERC20 in, native ETH out. Assumes this contract holds ETH.
    /// @dev Named to match GenericSwapFacetV3.swapTokensSingleV3ERC20ToNative (selector 0x733214a3) so the
    ///      enforcer's SameChain selector allowlist accepts it.
    function swapTokensSingleV3ERC20ToNative(
        bytes32,
        string calldata,
        string calldata,
        address payable _receiver,
        uint256 _minAmountOut,
        SwapData calldata _swapData
    )
        external
    {
        IERC20 sendingAsset_ = IERC20(_swapData.sendingAssetId);
        sendingAsset_.safeTransferFrom(msg.sender, address(this), _swapData.fromAmount);

        uint256 ethBalance_ = address(this).balance;
        require(ethBalance_ >= _minAmountOut, "MockLiFiDiamond:insufficient-native-output");

        (bool ok_,) = _receiver.call{value: ethBalance_}("");
        require(ok_, "MockLiFiDiamond:native-transfer-failed");
    }

    /// @notice Mock swap: native ETH in, ERC20 out. Receives msg.value, sends ERC20.
    /// @dev Named to match GenericSwapFacetV3.swapTokensSingleV3NativeToERC20 (selector 0xaf7060fd) so the
    ///      enforcer's SameChain selector allowlist accepts it.
    function swapTokensSingleV3NativeToERC20(
        bytes32,
        string calldata,
        string calldata,
        address payable _receiver,
        uint256 _minAmountOut,
        SwapData calldata _swapData
    )
        external
        payable
    {
        require(msg.value == _swapData.fromAmount, "MockLiFiDiamond:wrong-native-input");

        IERC20 receivingAsset_ = IERC20(_swapData.receivingAssetId);
        uint256 amountReceived_ = receivingAsset_.balanceOf(address(this));
        require(amountReceived_ >= _minAmountOut, "MockLiFiDiamond:slippage-too-high");

        receivingAsset_.safeTransfer(_receiver, amountReceived_);
    }

    /// @notice Deposit native ETH into the mock for native-output swaps.
    function depositNative() external payable {
        // ETH is simply held by the contract
    }

    function depositOutputToken(address _token, uint256 _amount) external {
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
    }
}
