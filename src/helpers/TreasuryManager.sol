// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { IDelegationManager } from "../interfaces/IDelegationManager.sol";
import { Delegation, ModeCode } from "../utils/Types.sol";
import { IMetaBridge } from "./interfaces/IMetaBridge.sol";
import { IMetaSwap } from "./interfaces/IMetaSwap.sol";
import { TreasuryCalldataDecoder } from "./libraries/TreasuryCalldataDecoder.sol";

/**
 * @title TreasuryManager
 * @notice Orchestrates ERC-7710 delegation redemption into this contract, then executes a same-chain transfer,
 *         MetaSwap swap, or MetaBridge bridge according to owner policies.
 * @dev Not an ERC-4337 account: the redeemer is this contract’s address as configured on `DelegationManager`.
 *      `transfer` is not `IERC20.transfer`: it redeems a pull of `_token` / `_amount` from the delegator, then pays
 *      `_destWalletAddress`.
 *      Swap and bridge require an API signature from `apiSigner` over `apiData`, `expiration`, `slippage`, `priceImpact`,
 *      and `destWalletAddress` (EIP-191). `transfer` does not use an API signature.
 *      WETH is normalized to native (`address(0)`) for `pairLimits` and the same-chain `isTokenToAllowed` allowlist
 *      so one policy covers ETH and WETH on the same chain. Bridge destination tokens (`isBridgeTokenToAllowed`) are
 *      NOT canonicalized — pass exact destination-chain addresses.
 *
 *      Multichain stETH support: this contract is meant to be deployed across multiple EVM chains.
 *      `stEth` is an immutable that may be set to `address(0)` on chains where Lido stETH does not exist (everything
 *      except Ethereum mainnet). When `stEth` is set, redemption of stETH from a delegation tolerates the canonical
 *      1-2 wei share-rounding shortfall by topping up from the contract's pre-funded stETH balance, up to
 *      `STETH_TRANSFER_TOLERANCE` per redemption. The admin must seed the contract with enough stETH (via direct
 *      ERC-20 transfer) to cover the cumulative dust across expected redemptions.
 */
contract TreasuryManager is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    ////////////////////////////// Structs //////////////////////////////

    /**
     * @notice Signed authorization for swap and bridge API payloads.
     * @dev Message: `keccak256(abi.encode(apiData, expiration, slippage, priceImpact, destWalletAddress))`, then EIP-191 via
     *      `MessageHashUtils`. `destWalletAddress` is the payout or bridge destination bound to the quote.
     * @param apiData ABI-encoded outer calldata (`IMetaSwap.swap` or `IMetaBridge.bridge` style), including function
     *                selector.
     * @param expiration Unix timestamp after which the signature is invalid.
     * @param slippage Signed API slippage for swaps (1e18 = 1%); capped per pair when positive. May be zero for bridge.
     * @param priceImpact Signed API price impact for swaps (1e18 = 1%); capped per pair when positive.
     * @param destWalletAddress Same-chain swap output receiver, or authorized bridge destination (must pass allowlists).
     * @param signature ECDSA signature over the Ethereum-signed message hash of the encoded tuple above.
     */
    struct SignatureData {
        bytes apiData;
        uint256 expiration;
        int120 slippage;
        int120 priceImpact;
        address destWalletAddress;
        bytes signature;
    }

    /**
     * @notice Admin caps for swap execution on a canonical `(tokenFrom, tokenTo)` pair.
     * @param maxSlippage Maximum allowed signed slippage when unfavorable (positive); 1e18 = 1%, up to `MAX_PERCENT`.
     * @param maxPriceImpact Maximum allowed signed price impact when unfavorable (positive); same units as `maxSlippage`.
     * @param enabled If false, `swap` reverts with `PairDisabled` for this pair.
     */
    struct PairLimit {
        uint120 maxSlippage;
        uint120 maxPriceImpact;
        bool enabled;
    }

    /**
     * @notice Batch input for `setPairLimits`.
     * @param tokenFrom Input asset for the pair (WETH may be passed; canonicalized like `getPairLimit`).
     * @param tokenTo Output asset for the pair.
     * @param limit Policy for this pair.
     */
    struct PairLimitInput {
        IERC20 tokenFrom;
        IERC20 tokenTo;
        PairLimit limit;
    }

    ////////////////////////////// Constants //////////////////////////////

    /// @dev 100% in 18-decimal fixed point (slippage / price impact magnitudes; 1e18 = 1%).
    uint120 public constant MAX_PERCENT = 100e18;

    /// @notice Maximum acceptable wei shortfall on a stETH redemption. Lido per-transfer share rounding loses up to
    ///         2 wei per hop; 10 wei is a 5x safety margin. Shortfalls within this bound are silently covered from
    ///         the contract's pre-funded stETH balance; anything larger reverts.
    uint256 public constant STETH_TRANSFER_TOLERANCE = 10;

    ////////////////////////////// State //////////////////////////////

    /// @notice Trusted `DelegationManager` used to redeem delegations that pull assets into this contract.
    IDelegationManager public immutable delegationManager;
    /// @notice MetaSwap router used by `swap` after redemption.
    IMetaSwap public immutable metaSwap;
    /// @notice MetaBridge router used by `bridge` after redemption.
    IMetaBridge public immutable metaBridge;
    /// @notice Chain WETH address; aliased to native `address(0)` for `pairLimits` and `isTokenToAllowed` keys only.
    IERC20 public immutable weth;
    /// @notice Lido stETH address on chains where it exists; `address(0)` disables the share-rounding tolerance
    ///         (non-mainnet chains). When non-zero, the contract should be pre-funded with stETH by the admin to
    ///         cover dust shortfalls on stETH redemptions.
    address public immutable stEth;

    /// @notice Address whose ECDSA signatures authorize `SignatureData` for `swap` and `bridge`.
    address public apiSigner;

    /// @notice Allowlist of addresses authorized to call `transfer`, `swap`, and `bridge`.
    mapping(address caller => bool allowed) public isCallerAllowed;
    /// @notice Allowlist of payout recipients used by `transfer` and the swap output address.
    mapping(address destWalletAddress => bool allowed) public isDestWalletAllowed;
    /// @notice Same-chain swap output token allowlist; pass WETH to allow native (canonicalized to `address(0)`).
    mapping(IERC20 token => bool allowed) public isTokenToAllowed;
    /// @notice Chain-id kill switch for `bridge`; must match the inner adapter `destinationChainId`.
    mapping(uint256 destinationChainId => bool allowed) public isDestinationChainAllowed;
    /// @notice Per-chain bridge destination wallet allowlist (must match the signed `destWalletAddress`).
    mapping(uint256 destinationChainId => mapping(address destWalletAddress => bool allowed)) public allowedBridgeDestination;
    /// @notice Per-chain bridge destination token allowlist; raw destination-chain addresses (NOT canonicalized).
    mapping(uint256 destinationChainId => mapping(address token => bool allowed)) public isBridgeTokenToAllowed;

    mapping(IERC20 tokenFrom => mapping(IERC20 tokenTo => PairLimit)) private pairLimits;

    ////////////////////////////// Events //////////////////////////////

    event ApiSignerUpdated(address indexed oldSigner, address indexed newSigner);
    event BridgeInitiated(
        address indexed caller,
        IERC20 indexed tokenFrom,
        uint256 indexed destinationChainId,
        address destWalletAddress,
        address tokenTo,
        uint256 amount
    );
    event ChangedBridgeDestinationStatus(
        uint256 indexed destinationChainId, address indexed destWalletAddress, bool indexed status
    );
    event ChangedBridgeTokenToStatus(uint256 indexed destinationChainId, address indexed token, bool indexed status);
    event ChangedCallerStatus(address indexed caller, bool indexed status);
    event ChangedDestinationChainStatus(uint256 indexed destinationChainId, bool indexed status);
    event ChangedDestWalletStatus(address indexed destWalletAddress, bool indexed status);
    event ChangedTokenToStatus(IERC20 indexed token, bool indexed status);
    event PairLimitSet(IERC20 indexed tokenFrom, IERC20 indexed tokenTo, uint120 maxSlippage, uint120 maxPriceImpact, bool enabled);
    event SentTokens(IERC20 indexed token, address indexed destWalletAddress, uint256 amount);
    event StEthShortfallCovered(uint256 shortfall);
    event SwapExecuted(
        address indexed caller,
        IERC20 indexed tokenFrom,
        IERC20 indexed tokenTo,
        address destWalletAddress,
        uint256 amountFrom,
        uint256 amountTo
    );
    event TransferExecuted(address indexed caller, IERC20 indexed token, address indexed destWalletAddress, uint256 amount);

    ////////////////////////////// Errors //////////////////////////////

    error BridgeDestinationNotAllowed(uint256 destinationChainId, address destWalletAddress);
    error BridgeSourceNotConsumed(uint256 expected, uint256 consumed);
    error BridgeTokenToNotAllowed(uint256 destinationChainId, address token);
    error CallerNotAllowed();
    error DestinationChainNotAllowed(uint256 destinationChainId);
    error DestinationWalletNotAllowed();
    error FailedNativeTokenTransfer(address destWalletAddress);
    error InputLengthsMismatch();
    error InsufficientStEthPrefund(uint256 shortfall, uint256 available);
    error InvalidApiSignature();
    error InvalidEmptyDelegations();
    error InvalidIdenticalTokens();
    error InvalidPercent(uint256 percent);
    error InvalidZeroAddress();
    error PairDisabled(IERC20 tokenFrom, IERC20 tokenTo);
    error PriceImpactExceedsCap(IERC20 tokenFrom, IERC20 tokenTo, int256 signedPriceImpact, uint256 cap);
    error SignatureExpired();
    error SlippageExceedsCap(IERC20 tokenFrom, IERC20 tokenTo, int256 signedSlippage, uint256 cap);
    error TokenToNotAllowed();
    error UnexpectedTokenFromAmount(uint256 expected, uint256 obtained);

    ////////////////////////////// Modifiers //////////////////////////////

    /// @notice Restricts calls to addresses marked allowed by the owner via `updateAllowedCallers`.
    modifier onlyAllowedCaller() {
        if (!isCallerAllowed[msg.sender]) revert CallerNotAllowed();
        _;
    }

    ////////////////////////////// Constructor //////////////////////////////

    /**
     * @notice Deploys the treasury with immutable protocol references and initial API signer.
     * @param _owner Initial owner (`Ownable2Step`).
     * @param _apiSigner Address that signs `SignatureData` for swap and bridge.
     * @param _delegationManager Trusted delegation manager contract.
     * @param _metaSwap Trusted MetaSwap implementation.
     * @param _metaBridge Trusted MetaBridge implementation.
     * @param _weth This chain’s WETH token for native aliasing in policies.
     * @param _stEth Lido stETH on chains where it exists; pass `address(0)` on chains without Lido (disables
     *               share-rounding tolerance).
     */
    constructor(
        address _owner,
        address _apiSigner,
        IDelegationManager _delegationManager,
        IMetaSwap _metaSwap,
        IMetaBridge _metaBridge,
        IERC20 _weth,
        address _stEth
    )
        Ownable(_owner)
    {
        _requireNonZero(address(_delegationManager));
        _requireNonZero(address(_metaSwap));
        _requireNonZero(address(_metaBridge));
        _requireNonZero(address(_weth));

        delegationManager = _delegationManager;
        metaSwap = _metaSwap;
        metaBridge = _metaBridge;
        weth = _weth;
        stEth = _stEth;
        _setApiSigner(_apiSigner);
    }

    /// @notice Accepts native token when delegation redemption sends ETH to this contract.
    receive() external payable { }

    ////////////////////////////// External Methods - User Actions //////////////////////////////

    /**
     * @notice Redeems a delegation pull then transfers `_amount` of `_token` to `_destWalletAddress`.
     * @dev Does not require API signatures; enforces `isDestWalletAllowed` only. Which assets may be moved are enforced
     *      by delegation caveats.
     * @param _delegations Delegation chain (leaf-to-root) authorizing the pull into this contract.
     * @param _token Asset to pull and forward; `address(0)` denotes the native token.
     * @param _amount Exact amount expected from redemption (reverts if balance delta differs).
     * @param _destWalletAddress Payout address; must be allowlisted.
     */
    function transfer(
        Delegation[] calldata _delegations,
        IERC20 _token,
        uint256 _amount,
        address _destWalletAddress
    )
        external
        onlyAllowedCaller
        nonReentrant
    {
        if (_delegations.length == 0) revert InvalidEmptyDelegations();
        if (!isDestWalletAllowed[_destWalletAddress]) revert DestinationWalletNotAllowed();

        _redeemTransfer(_delegations, _token, _amount);

        _sendTokens(_token, _amount, _destWalletAddress);
        emit TransferExecuted(msg.sender, _token, _destWalletAddress, _amount);
    }

    /**
     * @notice Redeems input tokens via delegation, executes MetaSwap, and sends output to `_signatureData.destWalletAddress`.
     * @dev Validates signature (including destination wallet via `destWalletAddress`), pair limits, `isDestWalletAllowed`,
     *      and `isTokenToAllowed` on output token.
     * @param _signatureData API-signed swap payload; `destWalletAddress` is where output tokens are sent.
     * @param _delegations Delegation chain authorizing the pull of `tokenFrom` / `amountFrom` derived from
     *                     `_signatureData.apiData`.
     */
    function swap(
        SignatureData calldata _signatureData,
        Delegation[] calldata _delegations
    )
        external
        onlyAllowedCaller
        nonReentrant
    {
        _validateSignedSwapOrBridge(_signatureData, _delegations);

        (string memory aggregatorId_, IERC20 tokenFrom_, IERC20 tokenTo_, uint256 amountFrom_, bytes memory swapData_) =
            TreasuryCalldataDecoder.decodeSwapApiData(_signatureData.apiData);

        IERC20 canonicalTokenTo_ = _canonNative(tokenTo_);
        if (!isTokenToAllowed[canonicalTokenTo_]) revert TokenToNotAllowed();

        _validatePairPolicy(tokenFrom_, tokenTo_, _signatureData.slippage, _signatureData.priceImpact);

        _redeemTransfer(_delegations, tokenFrom_, amountFrom_);

        uint256 amountTo_ =
            _swapTokens(aggregatorId_, tokenFrom_, tokenTo_, amountFrom_, swapData_, _signatureData.destWalletAddress);
        emit SwapExecuted(msg.sender, tokenFrom_, tokenTo_, _signatureData.destWalletAddress, amountFrom_, amountTo_);
    }

    /**
     * @notice Redeems source tokens via delegation then calls MetaBridge with the signed opaque adapter payload.
     * @dev Validates signature (including `destWalletAddress`), chain policy, `allowedBridgeDestination` for the signed
     *      destination wallet, and `isBridgeTokenToAllowed[chain][tokenTo]` on inner `tokenTo`. The adapter's own
     *      `destWalletAddress` is intentionally ignored — only `_signatureData.destWalletAddress` governs payout.
     * @param _signatureData API-signed bridge payload (`apiData` encodes `IMetaBridge.bridge`-style calldata).
     * @param _delegations Delegation chain authorizing the pull of outer `amountFrom` / `tokenFrom`.
     */
    function bridge(
        SignatureData calldata _signatureData,
        Delegation[] calldata _delegations
    )
        external
        onlyAllowedCaller
        nonReentrant
    {
        _validateSignedSwapOrBridge(_signatureData, _delegations);

        (
            string memory adapterId_,
            IERC20 tokenFromOuter_,
            uint256 amountFrom_,
            bytes memory bridgeInnerBytes_,
            TreasuryCalldataDecoder.BridgeAdapterDecoded memory inner_
        ) = TreasuryCalldataDecoder.decodeBridgeApiData(_signatureData.apiData);

        _validateBridgePolicies(inner_, _signatureData.destWalletAddress);

        _redeemTransfer(_delegations, tokenFromOuter_, amountFrom_);

        _bridgeTokens(adapterId_, tokenFromOuter_, amountFrom_, bridgeInnerBytes_);
        emit BridgeInitiated(
            msg.sender, tokenFromOuter_, inner_.destinationChainId, _signatureData.destWalletAddress, inner_.tokenTo, amountFrom_
        );
    }

    ////////////////////////////// External Methods - Owner Admin //////////////////////////////

    /**
     * @notice Rotates the address authorized to sign swap and bridge API payloads.
     * @param _newSigner New signer; must not be the zero address.
     */
    function setApiSigner(address _newSigner) external onlyOwner {
        _setApiSigner(_newSigner);
    }

    /**
     * @notice Owner-only sweep of native or ERC-20 balances held by this contract.
     * @dev WARNING: when withdrawing the configured `stEth` token, the admin is also draining the share-rounding
     *      prefund. After draining, subsequent stETH redemptions with even a 1-wei shortfall will revert with
     *      `InsufficientStEthPrefund` until the prefund is replenished (via direct `stEth.transfer(treasury, ...)`).
     *      Leave a buffer of stETH in this contract proportional to expected stETH redemption volume.
     * @param _token Asset to send; `address(0)` denotes native.
     * @param _amount Amount to transfer.
     * @param _destWalletAddress Receiver of the withdrawal.
     */
    function withdraw(IERC20 _token, uint256 _amount, address _destWalletAddress) external onlyOwner {
        _sendTokens(_token, _amount, _destWalletAddress);
    }

    /**
     * @notice Configures enabled swap pairs and signed slippage / price-impact ceilings.
     * @dev Rejects identical `tokenFrom` / `tokenTo`. WETH inputs are canonicalized to native for storage keys.
     * @param _inputs Per-pair policies to apply.
     */
    function setPairLimits(PairLimitInput[] calldata _inputs) external onlyOwner {
        uint256 length_ = _inputs.length;
        for (uint256 i = 0; i < length_;) {
            PairLimitInput calldata pairInput_ = _inputs[i];

            IERC20 tokenFrom_ = _canonNative(pairInput_.tokenFrom);
            IERC20 tokenTo_ = _canonNative(pairInput_.tokenTo);
            if (tokenFrom_ == tokenTo_) revert InvalidIdenticalTokens();
            if (pairInput_.limit.maxSlippage > MAX_PERCENT) revert InvalidPercent(pairInput_.limit.maxSlippage);
            if (pairInput_.limit.maxPriceImpact > MAX_PERCENT) revert InvalidPercent(pairInput_.limit.maxPriceImpact);

            pairLimits[tokenFrom_][tokenTo_] = pairInput_.limit;
            emit PairLimitSet(
                tokenFrom_, tokenTo_, pairInput_.limit.maxSlippage, pairInput_.limit.maxPriceImpact, pairInput_.limit.enabled
            );

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Sets whether a destination wallet is permitted for bridge flows on `_destinationChainId`.
     * @param _destinationChainId Chain id as encoded in bridge adapter data (inner `destinationChainId`).
     * @param _destWalletAddresses Addresses to update (typically bridge destination wallets).
     * @param _statuses Parallel allow flags; must match `_destWalletAddresses.length`.
     */
    function updateAllowedBridgeDestinations(
        uint256 _destinationChainId,
        address[] calldata _destWalletAddresses,
        bool[] calldata _statuses
    )
        external
        onlyOwner
    {
        uint256 length_ = _destWalletAddresses.length;
        if (length_ != _statuses.length) revert InputLengthsMismatch();
        for (uint256 i = 0; i < length_;) {
            address destWallet_ = _destWalletAddresses[i];
            bool status_ = _statuses[i];
            if (allowedBridgeDestination[_destinationChainId][destWallet_] != status_) {
                allowedBridgeDestination[_destinationChainId][destWallet_] = status_;
                emit ChangedBridgeDestinationStatus(_destinationChainId, destWallet_, status_);
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Allowlists destination-chain output tokens for `bridge` (matched against inner adapter `tokenTo`).
     * @dev Tokens are NOT canonicalized; pass the exact address as it appears on the destination chain. WETH-on-Arbitrum
     *      and WETH-on-mainnet are different addresses, so each must be configured per chain explicitly.
     * @param _destinationChainId Chain id whose token allowlist to update.
     * @param _tokens Destination-chain token addresses to update.
     * @param _statuses Parallel flags; must match `_tokens.length`.
     */
    function updateAllowedBridgeTokensTo(
        uint256 _destinationChainId,
        address[] calldata _tokens,
        bool[] calldata _statuses
    )
        external
        onlyOwner
    {
        uint256 length_ = _tokens.length;
        if (length_ != _statuses.length) revert InputLengthsMismatch();
        for (uint256 i = 0; i < length_;) {
            address token_ = _tokens[i];
            bool status_ = _statuses[i];
            if (isBridgeTokenToAllowed[_destinationChainId][token_] != status_) {
                isBridgeTokenToAllowed[_destinationChainId][token_] = status_;
                emit ChangedBridgeTokenToStatus(_destinationChainId, token_, status_);
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Allowlists which addresses may invoke `transfer`, `swap`, and `bridge`.
     * @param _callers Addresses to update.
     * @param _statuses Parallel flags; must match `_callers.length`.
     */
    function updateAllowedCallers(address[] calldata _callers, bool[] calldata _statuses) external onlyOwner {
        uint256 length_ = _callers.length;
        if (length_ != _statuses.length) revert InputLengthsMismatch();
        for (uint256 i = 0; i < length_;) {
            address caller_ = _callers[i];
            bool status_ = _statuses[i];
            if (isCallerAllowed[caller_] != status_) {
                isCallerAllowed[caller_] = status_;
                emit ChangedCallerStatus(caller_, status_);
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Allowlists payout destination wallets for `transfer` and `swap`.
     * @param _destWalletAddresses Addresses to update.
     * @param _statuses Parallel flags; must match `_destWalletAddresses.length`.
     */
    function updateAllowedDestWallets(address[] calldata _destWalletAddresses, bool[] calldata _statuses) external onlyOwner {
        uint256 length_ = _destWalletAddresses.length;
        if (length_ != _statuses.length) revert InputLengthsMismatch();
        for (uint256 i = 0; i < length_;) {
            address destWallet_ = _destWalletAddresses[i];
            bool status_ = _statuses[i];
            if (isDestWalletAllowed[destWallet_] != status_) {
                isDestWalletAllowed[destWallet_] = status_;
                emit ChangedDestWalletStatus(destWallet_, status_);
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Allowlists same-chain swap output (`tokenTo`) assets.
     * @dev Swap-only. Bridge destination tokens are managed via `updateAllowedBridgeTokensTo` (per-chain).
     *      WETH entries are canonicalized to native for the mapping key.
     * @param _tokens ERC-20 contracts to flag; use WETH address where policies should track wrapped native.
     * @param _statuses Parallel flags; must match `_tokens.length`.
     */
    function updateAllowedTokensTo(IERC20[] calldata _tokens, bool[] calldata _statuses) external onlyOwner {
        uint256 length_ = _tokens.length;
        if (length_ != _statuses.length) revert InputLengthsMismatch();
        for (uint256 i = 0; i < length_;) {
            IERC20 token_ = _canonNative(_tokens[i]);
            bool status_ = _statuses[i];
            if (isTokenToAllowed[token_] != status_) {
                isTokenToAllowed[token_] = status_;
                emit ChangedTokenToStatus(token_, status_);
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Allowlists destination chain ids for `bridge` (must match inner `destinationChainId`).
     * @param _chainIds Chain ids to update.
     * @param _statuses Parallel flags; must match `_chainIds.length`.
     */
    function updateDestinationChains(uint256[] calldata _chainIds, bool[] calldata _statuses) external onlyOwner {
        uint256 length_ = _chainIds.length;
        if (length_ != _statuses.length) revert InputLengthsMismatch();
        for (uint256 i = 0; i < length_;) {
            uint256 chainId_ = _chainIds[i];
            bool status_ = _statuses[i];
            if (isDestinationChainAllowed[chainId_] != status_) {
                isDestinationChainAllowed[chainId_] = status_;
                emit ChangedDestinationChainStatus(chainId_, status_);
            }
            unchecked {
                ++i;
            }
        }
    }

    ////////////////////////////// Public View Methods //////////////////////////////

    /**
     * @notice Returns stored swap policy for a pair, with WETH normalized to native for lookups.
     * @param _tokenFrom Swap input token for the pair key.
     * @param _tokenTo Swap output token for the pair key.
     * @return limit_ Stored caps and `enabled` flag; zeroed if never configured.
     */
    function getPairLimit(IERC20 _tokenFrom, IERC20 _tokenTo) public view returns (PairLimit memory limit_) {
        limit_ = pairLimits[_canonNative(_tokenFrom)][_canonNative(_tokenTo)];
    }

    ////////////////////////////// Internal/Private Methods //////////////////////////////

    /**
     * @dev Verifies expiry and ECDSA recover against `apiSigner` for swap and bridge `SignatureData`.
     * @param _signatureData User-supplied signed API envelope.
     */
    function _validateSignature(SignatureData calldata _signatureData) internal view {
        if (block.timestamp >= _signatureData.expiration) revert SignatureExpired();

        bytes32 messageHash_ = keccak256(
            abi.encode(
                _signatureData.apiData,
                _signatureData.expiration,
                _signatureData.slippage,
                _signatureData.priceImpact,
                _signatureData.destWalletAddress
            )
        );
        bytes32 ethSignedMessageHash_ = MessageHashUtils.toEthSignedMessageHash(messageHash_);

        address recovered_ = ECDSA.recover(ethSignedMessageHash_, _signatureData.signature);
        if (recovered_ != apiSigner) revert InvalidApiSignature();
    }

    /// @dev Sets `apiSigner` and emits `ApiSignerUpdated(old, new)`. Used by both the constructor (where `old` is
    ///      `address(0)`) and `setApiSigner` (rotation).
    function _setApiSigner(address _newSigner) private {
        _requireNonZero(_newSigner);
        address oldSigner_ = apiSigner;
        apiSigner = _newSigner;
        emit ApiSignerUpdated(oldSigner_, _newSigner);
    }

    /// @dev Reverts with `InvalidZeroAddress` if `_addr` is the zero address.
    function _requireNonZero(address _addr) private pure {
        if (_addr == address(0)) revert InvalidZeroAddress();
    }

    /// @dev Shared by `swap` / `bridge`: non-empty delegations, API signature, destination wallet allowlist.
    function _validateSignedSwapOrBridge(SignatureData calldata _signatureData, Delegation[] calldata _delegations) private view {
        if (_delegations.length == 0) revert InvalidEmptyDelegations();
        _validateSignature(_signatureData);
        if (!isDestWalletAllowed[_signatureData.destWalletAddress]) revert DestinationWalletNotAllowed();
    }

    /**
     * @dev Calls `DelegationManager.redeemDelegations` with a single execution that pulls `_amount` of `_tokenFrom`
     *      into this contract (or native receive), then validates the actual balance delta. After this returns the
     *      contract is guaranteed to hold at least `_amount` of `_tokenFrom` available for the downstream call.
     *
     *      Strict equality is required for every token EXCEPT stETH. The stETH carve-out is handled by
     *      `_isWithinStEthTolerance`: if `_tokenFrom == stEth` and the redemption arrived short by up to
     *      `STETH_TRANSFER_TOLERANCE` wei (intrinsic Lido share-rounding loss), the shortfall is silently covered from
     *      the contract's pre-funded stETH balance. Over-credit (`obtained > _amount`), out-of-tolerance shortfalls,
     *      and any non-stETH mismatch revert with `UnexpectedTokenFromAmount`.
     * @param _delegations Permission contexts (ABI-encoded single batch).
     * @param _tokenFrom Asset to pull; `address(0)` schedules a native transfer to this contract.
     * @param _amount Amount the redemption execution will request from the delegator and that downstream code is
     *                entitled to spend.
     */
    function _redeemTransfer(Delegation[] calldata _delegations, IERC20 _tokenFrom, uint256 _amount) private {
        uint256 balanceBefore_ = _getSelfBalance(_tokenFrom);

        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(_delegations);

        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = ModeLib.encodeSimpleSingle();

        bytes[] memory executionCallDatas_ = new bytes[](1);

        if (address(_tokenFrom) == address(0)) {
            executionCallDatas_[0] = ExecutionLib.encodeSingle(address(this), _amount, hex"");
        } else {
            executionCallDatas_[0] =
                ExecutionLib.encodeSingle(address(_tokenFrom), 0, abi.encodeCall(IERC20.transfer, (address(this), _amount)));
        }

        delegationManager.redeemDelegations(permissionContexts_, modes_, executionCallDatas_);

        uint256 obtained_ = _getSelfBalance(_tokenFrom) - balanceBefore_;
        if (obtained_ == _amount) return;
        if (_isWithinStEthTolerance(_tokenFrom, _amount, obtained_, balanceBefore_)) {
            emit StEthShortfallCovered(_amount - obtained_);
            return;
        }

        revert UnexpectedTokenFromAmount(_amount, obtained_);
    }

    /**
     * @dev Returns `true` if the `_amount - _obtained` shortfall is an intrinsic stETH share-rounding loss within
     *      `STETH_TRANSFER_TOLERANCE` AND the contract's pre-funded stETH balance covers it. Returns `false` for any
     *      non-stETH token, for a non-shortfall (over-credit / equality), or when the shortfall exceeds the tolerance
     *      window — letting the caller revert generically. Reverts with `InsufficientStEthPrefund` when the shortfall
     *      is stETH-shaped and within tolerance but the pre-funded balance is too small to cover it.
     * @param _tokenFrom Asset that was redeemed.
     * @param _amount Amount the redemption requested.
     * @param _obtained Actual balance delta observed.
     * @param _balanceBefore This contract's `_tokenFrom` balance before the redemption (the available prefund).
     */
    function _isWithinStEthTolerance(
        IERC20 _tokenFrom,
        uint256 _amount,
        uint256 _obtained,
        uint256 _balanceBefore
    )
        private
        view
        returns (bool)
    {
        if (stEth == address(0) || address(_tokenFrom) != stEth || _obtained >= _amount) return false;

        uint256 shortfall_ = _amount - _obtained;
        if (shortfall_ > STETH_TRANSFER_TOLERANCE) return false;
        if (_balanceBefore < shortfall_) revert InsufficientStEthPrefund(shortfall_, _balanceBefore);
        return true;
    }

    /**
     * @dev Sends ERC-20 via `SafeERC20` or native via low-level call; emits `SentTokens`.
     */
    function _sendTokens(IERC20 _token, uint256 _amount, address _destWalletAddress) private {
        if (address(_token) == address(0)) {
            (bool success_,) = _destWalletAddress.call{ value: _amount }("");
            if (!success_) revert FailedNativeTokenTransfer(_destWalletAddress);
        } else {
            _token.safeTransfer(_destWalletAddress, _amount);
        }

        emit SentTokens(_token, _destWalletAddress, _amount);
    }

    /**
     * @dev Native input: returns wei to attach to the router call; ERC-20: ensures `_spender` allowance covers `_amount`
     *      and returns 0.
     */
    function _etherValueOrApprove(IERC20 _tokenFrom, uint256 _amount, address _spender) private returns (uint256) {
        if (address(_tokenFrom) == address(0)) return _amount;

        if (_tokenFrom.allowance(address(this), _spender) < _amount) {
            _tokenFrom.forceApprove(_spender, type(uint256).max);
        }
        return 0;
    }

    /**
     * @dev After `_redeemTransfer` has verified the input pull, approves `metaSwap` when needed, executes swap, pays
     *      full output to `_destWalletAddress`. Returns the actual `_tokenTo` amount delivered (balance delta).
     */
    function _swapTokens(
        string memory _aggregatorId,
        IERC20 _tokenFrom,
        IERC20 _tokenTo,
        uint256 _amountFrom,
        bytes memory _swapData,
        address _destWalletAddress
    )
        private
        returns (uint256 obtainedOut_)
    {
        uint256 value_ = _etherValueOrApprove(_tokenFrom, _amountFrom, address(metaSwap));

        uint256 balanceToBefore_ = _getSelfBalance(_tokenTo);

        metaSwap.swap{ value: value_ }(_aggregatorId, _tokenFrom, _amountFrom, _swapData);

        obtainedOut_ = _getSelfBalance(_tokenTo) - balanceToBefore_;

        _sendTokens(_tokenTo, obtainedOut_, _destWalletAddress);
    }

    /**
     * @dev Approves `metaBridge` for ERC-20 pulls when required, forwards the opaque adapter bytes to `metaBridge`,
     *      and verifies the source-side balance dropped by exactly `_amountFrom`. The check primarily protects ERC-20
     *      bridges where the router uses `transferFrom`; for native input the `value:` ETH leaves the contract via the
     *      call itself, so the check is structurally satisfied either way.
     */
    function _bridgeTokens(
        string memory _adapterId,
        IERC20 _tokenFrom,
        uint256 _amountFrom,
        bytes memory _bridgeOpaqueData
    )
        private
    {
        uint256 value_ = _etherValueOrApprove(_tokenFrom, _amountFrom, address(metaBridge));

        uint256 sourceBalanceBefore_ = _getSelfBalance(_tokenFrom);
        metaBridge.bridge{ value: value_ }(_adapterId, address(_tokenFrom), _amountFrom, _bridgeOpaqueData);
        uint256 consumed_ = sourceBalanceBefore_ - _getSelfBalance(_tokenFrom);
        if (consumed_ != _amountFrom) revert BridgeSourceNotConsumed(_amountFrom, consumed_);
    }

    /**
     * @dev Ensures the pair is enabled and that signed unfavorable slippage / price impact do not exceed stored caps.
     */
    function _validatePairPolicy(
        IERC20 _tokenFrom,
        IERC20 _tokenTo,
        int256 _signedSlippage,
        int256 _signedPriceImpact
    )
        private
        view
    {
        PairLimit memory limit_ = getPairLimit(_tokenFrom, _tokenTo);
        if (!limit_.enabled) revert PairDisabled(_tokenFrom, _tokenTo);
        if (_signedSlippage > 0 && uint256(_signedSlippage) > limit_.maxSlippage) {
            revert SlippageExceedsCap(_tokenFrom, _tokenTo, _signedSlippage, limit_.maxSlippage);
        }
        if (_signedPriceImpact > 0 && uint256(_signedPriceImpact) > limit_.maxPriceImpact) {
            revert PriceImpactExceedsCap(_tokenFrom, _tokenTo, _signedPriceImpact, limit_.maxPriceImpact);
        }
    }

    /**
     * @dev Bundles the per-bridge policy checks: destination chain allowlist, bridge destination wallet allowlist, and
     *      per-chain `tokenTo` allowlist. The adapter's own `destWalletAddress` is parsed but intentionally ignored;
     *      only the API-signed `_signedDestWalletAddress` governs payout policy.
     * @dev `tokenFrom` outer/inner consistency and `outer.amountFrom == inner.amountFrom + inner.fee` are validated
     *      upstream by `TreasuryCalldataDecoder.decodeBridgeApiData`.
     */
    function _validateBridgePolicies(
        TreasuryCalldataDecoder.BridgeAdapterDecoded memory _inner,
        address _signedDestWalletAddress
    )
        private
        view
    {
        uint256 destChain_ = _inner.destinationChainId;
        if (!isDestinationChainAllowed[destChain_]) revert DestinationChainNotAllowed(destChain_);
        if (!allowedBridgeDestination[destChain_][_signedDestWalletAddress]) {
            revert BridgeDestinationNotAllowed(destChain_, _signedDestWalletAddress);
        }
        if (!isBridgeTokenToAllowed[destChain_][_inner.tokenTo]) revert BridgeTokenToNotAllowed(destChain_, _inner.tokenTo);
    }

    /**
     * @dev Native balance when `_token` is zero address; otherwise `balanceOf` for this contract.
     * @param _token Asset to measure.
     * @return balance_ Whole-token amount (wei or token smallest units).
     */
    function _getSelfBalance(IERC20 _token) private view returns (uint256 balance_) {
        if (address(_token) == address(0)) return address(this).balance;

        balance_ = _token.balanceOf(address(this));
    }

    /**
     * @dev Maps `weth` to `IERC20(address(0))` for policy keys used by swaps and output-token allowlists.
     */
    function _canonNative(IERC20 _token) private view returns (IERC20 canonical_) {
        canonical_ = _token == weth ? IERC20(address(0)) : _token;
    }
}
