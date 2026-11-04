// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title NativeSwapEnforcer
 * @notice Allows a limited amount of native ETH to be swapped for an ERC-20 token through a specified Uniswap
 * Universal Router-compatible contract while requiring a minimum output balance increase.
 *
 * @dev The execution MUST use single call type and default execution mode. It MUST target the signed swap contract,
 * transfer a non-zero native value, and call either Universal Router `execute` overload. Router calldata after the
 * selector is intentionally unrestricted.
 *
 * The signed native allowance is cumulative across every successful use of a delegation. The swap target must be
 * trusted because Universal Router commands can perform actions beyond a simple swap.
 */
contract NativeSwapEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;

    ////////////////////////////// Constants //////////////////////////////

    /// @dev `execute(bytes,bytes[])`.
    bytes4 public constant EXECUTE_SELECTOR = 0x24856bc3;

    /// @dev `execute(bytes,bytes[],uint256)`.
    bytes4 public constant EXECUTE_WITH_DEADLINE_SELECTOR = 0x3593564c;

    ////////////////////////////// Structs //////////////////////////////

    struct TermsData {
        address destinationToken;
        address swapTarget;
        address recipient;
        uint256 maxAmountIn;
        uint256 minAmountOut;
    }

    ////////////////////////////// State //////////////////////////////

    mapping(bytes32 hashKey => uint256 balance) public balanceCache;
    mapping(bytes32 hashKey => bool lock) public isLocked;
    mapping(address sender => mapping(bytes32 delegationHash => uint256 amount)) public spentMap;

    ////////////////////////////// Events //////////////////////////////

    event IncreasedSpentMap(
        address indexed sender, address indexed redeemer, bytes32 indexed delegationHash, uint256 limit, uint256 spent
    );

    ////////////////////////////// External Methods //////////////////////////////

    /**
     * @notice Generates the key used to isolate an active swap validation.
     */
    function getHashKey(address _caller, bytes32 _delegationHash) external pure returns (bytes32) {
        return _getHashKey(_caller, _delegationHash);
    }

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Validates the native-funded router execution and caches the recipient's destination-token balance.
     * @param _terms 124 packed bytes:
     * - destination ERC-20 token (20 bytes)
     * - swap target (20 bytes)
     * - output recipient (20 bytes)
     * - maximum cumulative native input amount (32 bytes)
     * - minimum destination amount (32 bytes)
     * @param _mode MUST be single call type and default execution mode.
     * @param _executionCallData The native-funded router execution.
     * @param _delegationHash The hash of the delegation carrying this caveat.
     */
    function beforeHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode _mode,
        bytes calldata _executionCallData,
        bytes32 _delegationHash,
        address,
        address _redeemer
    )
        public
        override
        onlySingleCallTypeMode(_mode)
        onlyDefaultExecutionMode(_mode)
    {
        TermsData memory terms_ = getTermsInfo(_terms);
        (address target_, uint256 value_, bytes calldata callData_) = _executionCallData.decodeSingle();

        require(target_ == terms_.swapTarget, "NativeSwapEnforcer:invalid-swap-target");
        require(value_ != 0, "NativeSwapEnforcer:zero-swap-value");
        require(callData_.length >= 4, "NativeSwapEnforcer:invalid-swap-calldata");

        bytes4 selector_ = bytes4(callData_[0:4]);
        require(
            selector_ == EXECUTE_SELECTOR || selector_ == EXECUTE_WITH_DEADLINE_SELECTOR, "NativeSwapEnforcer:invalid-swap-method"
        );

        bytes32 hashKey_ = _getHashKey(msg.sender, _delegationHash);
        require(!isLocked[hashKey_], "NativeSwapEnforcer:enforcer-is-locked");

        uint256 spent_ = spentMap[msg.sender][_delegationHash] + value_;
        require(spent_ <= terms_.maxAmountIn, "NativeSwapEnforcer:allowance-exceeded");
        spentMap[msg.sender][_delegationHash] = spent_;

        isLocked[hashKey_] = true;
        balanceCache[hashKey_] = IERC20(terms_.destinationToken).balanceOf(terms_.recipient);

        emit IncreasedSpentMap(msg.sender, _redeemer, _delegationHash, terms_.maxAmountIn, spent_);
    }

    /**
     * @notice Requires the recipient's destination-token balance to have increased by at least the signed minimum.
     */
    function afterHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode,
        bytes calldata,
        bytes32 _delegationHash,
        address,
        address
    )
        public
        override
    {
        TermsData memory terms_ = getTermsInfo(_terms);
        bytes32 hashKey_ = _getHashKey(msg.sender, _delegationHash);
        require(isLocked[hashKey_], "NativeSwapEnforcer:enforcer-not-locked");

        uint256 balanceBefore_ = balanceCache[hashKey_];
        uint256 balanceAfter_ = IERC20(terms_.destinationToken).balanceOf(terms_.recipient);

        delete isLocked[hashKey_];
        delete balanceCache[hashKey_];

        require(
            balanceAfter_ >= balanceBefore_ && balanceAfter_ - balanceBefore_ >= terms_.minAmountOut,
            "NativeSwapEnforcer:insufficient-output"
        );
    }

    /**
     * @notice Decodes and validates this enforcer's signed terms.
     */
    function getTermsInfo(bytes calldata _terms) public pure returns (TermsData memory termsData_) {
        require(_terms.length == 124, "NativeSwapEnforcer:invalid-terms-length");

        termsData_.destinationToken = address(bytes20(_terms[0:20]));
        termsData_.swapTarget = address(bytes20(_terms[20:40]));
        termsData_.recipient = address(bytes20(_terms[40:60]));
        termsData_.maxAmountIn = uint256(bytes32(_terms[60:92]));
        termsData_.minAmountOut = uint256(bytes32(_terms[92:124]));

        require(termsData_.destinationToken != address(0), "NativeSwapEnforcer:invalid-destination-token");
        require(termsData_.swapTarget != address(0), "NativeSwapEnforcer:invalid-swap-target");
        require(termsData_.recipient != address(0), "NativeSwapEnforcer:invalid-recipient");
        require(termsData_.maxAmountIn != 0, "NativeSwapEnforcer:zero-max-amount-in");
        require(termsData_.minAmountOut != 0, "NativeSwapEnforcer:zero-min-amount-out");
    }

    ////////////////////////////// Private Methods //////////////////////////////

    function _getHashKey(address _caller, bytes32 _delegationHash) private pure returns (bytes32) {
        return keccak256(abi.encode(_caller, _delegationHash));
    }
}
