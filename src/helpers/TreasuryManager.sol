// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { IDelegationManager } from "../interfaces/IDelegationManager.sol";
import { Delegation, ModeCode } from "../utils/Types.sol";
import { IDeleGatorModule } from "./interfaces/IDeleGatorModule.sol";
import { IMetaBridge } from "./interfaces/IMetaBridge.sol";
import { IMetaSwap } from "./interfaces/IMetaSwap.sol";
import { IWstETH } from "./interfaces/IWstETH.sol";
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
 *      WETH is normalized to native (`address(0)`) for `pairLimits` and the source side of `bridgeRouteLimits` so one
 *      policy covers ETH and WETH on the same chain. The destination side of `bridgeRouteLimits` is NOT canonicalized
 *      — pass exact destination-chain addresses.
 *      Output-token gating is enforced solely by `PairLimit.enabled` on the route (`pairLimits[from][to].enabled` for
 *      `swap`, `bridgeRouteLimits[from][chain][to].enabled` for `bridge`).
 *
 *      Protocol addresses (`delegationManager`, MetaSwap/MetaBridge, WETH, stETH/wstETH) are set once via
 *      `initialize` so the constructor args stay minimal for deterministic (e.g. CREATE2) same-address deployments.
 *
 *      Canonical Ethereum mainnet stETH uses share-based ERC-20 accounting (transfers can under-credit by a few wei).
 *      Plain `transfer`, `swap`, and `bridge` require strict redemption equality on every asset including stETH.
 *      To pull stETH via delegation, wrap **all** received stETH to wstETH, and pay out wstETH, use `wrapStEth`.
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
     * @param slippage Signed API slippage (1e18 = 1%); capped per route when positive — per swap pair for `swap` and per
     *                 `(sourceTokenFrom, destinationChainId, destinationTokenTo)` route for `bridge`.
     * @param priceImpact Signed API price impact (1e18 = 1%); capped per route when positive (same routing as `slippage`).
     * @param destWalletAddress Same-chain swap output receiver, or authorized bridge destination (must pass allowlists).
     *                        For `swap` / `wrapStEth`, may instead match `IDeleGatorModule(rootDelegator).safe()` when not
     * allowlisted.
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
     * @notice Admin caps applied to an API-signed quote on a route — a swap pair (`pairLimits`) or a bridge route
     *         (`bridgeRouteLimits`).
     * @param maxSlippage Maximum allowed signed slippage when unfavorable (positive); 1e18 = 1%, up to `MAX_PERCENT`.
     * @param maxPriceImpact Maximum allowed signed price impact when unfavorable (positive); same units as `maxSlippage`.
     * @param enabled If false, the route is disabled — `swap` reverts with `PairDisabled` and `bridge` reverts with
     *                `BridgeRouteDisabled`.
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

    /**
     * @notice Batch input for `setBridgeRouteLimits`.
     * @dev Source token is canonicalized like swap pairs (WETH → native). Destination token is the raw destination-chain
     *      address and is NOT canonicalized.
     * @param sourceTokenFrom Source-chain input token (this chain). Pass WETH for native routes.
     * @param destinationChainId Destination chain id; must match the inner adapter `destinationChainId`.
     * @param destinationTokenTo Destination-chain output token address (raw, not canonicalized).
     * @param limit Caps and `enabled` flag for this route.
     */
    struct BridgeRouteLimitInput {
        IERC20 sourceTokenFrom;
        uint256 destinationChainId;
        address destinationTokenTo;
        PairLimit limit;
    }

    ////////////////////////////// State variables //////////////////////////////

    /// @dev 100% in 18-decimal fixed point (slippage / price impact magnitudes; 1e18 = 1%).
    uint120 public constant MAX_PERCENT = 100e18;

    /// @notice Trusted `DelegationManager` used to redeem delegations that pull assets into this contract.
    IDelegationManager public delegationManager;
    /// @notice MetaSwap router used by `swap` after redemption.
    IMetaSwap public metaSwap;
    /// @notice MetaBridge router used by `bridge` after redemption.
    IMetaBridge public metaBridge;
    /// @notice Chain WETH address; aliased to native `address(0)` for `pairLimits` and `bridgeRouteLimits` (source side).
    IERC20 public weth;
    /// @notice Lido stETH token address on Ethereum mainnet; `address(0)` when not applicable (other chains).
    address public stEth;
    /// @notice Lido wstETH token used by `wrapStEth`; `address(0)` when `stEth` is unset.
    address public wstEth;

    /// @dev Set to true at the end of the one-time `initialize` call; read via `isInitialized()`.
    bool private _initialized;

    /// @notice Address whose ECDSA signatures authorize `SignatureData` for `swap` and `bridge`.
    address public apiSigner;

    /// @notice Allowlist of addresses authorized to call `transfer`, `swap`, and `bridge`.
    mapping(address caller => bool allowed) public isCallerAllowed;
    /// @notice Payout allowlist for transfer and signed-swap / wrap paths; `swap` and `wrapStEth` also allow payout to
    ///         `IDeleGatorModule(rootDelegator).safe()`. Not used for `bridge` (see `isBridgeDestWalletAllowed`).
    mapping(address destWalletAddress => bool allowed) public isDestWalletAllowed;
    /// @notice Chain-id kill switch for `bridge`; must match the inner adapter `destinationChainId`.
    mapping(uint256 destinationChainId => bool allowed) public isDestinationChainAllowed;
    /// @notice Per-chain allowlist for signed bridge payout, not transfer / swap.
    mapping(uint256 destinationChainId => mapping(address destWalletAddress => bool allowed)) public isBridgeDestWalletAllowed;

    mapping(IERC20 tokenFrom => mapping(IERC20 tokenTo => PairLimit)) private pairLimits;

    /// @dev Per-route bridge caps keyed by `(sourceTokenFrom canonicalized, destinationChainId, destinationTokenTo raw)`.
    mapping(IERC20 sourceTokenFrom => mapping(uint256 destinationChainId => mapping(address destinationTokenTo => PairLimit)))
        private bridgeRouteLimits;

    ////////////////////////////// Events //////////////////////////////

    event ApiSignerUpdated(address indexed oldSigner, address indexed newSigner);
    /// @notice Emitted when `initialize` completes; mirrors configured protocol references for indexing.
    event TreasuryInitialized(
        address indexed apiSigner,
        IDelegationManager indexed delegationManager,
        IMetaSwap indexed metaSwap,
        IMetaBridge metaBridge,
        IERC20 weth,
        address stEth,
        address wstEth
    );
    event BridgeInitiated(
        address indexed caller,
        IERC20 indexed tokenFrom,
        uint256 indexed destinationChainId,
        address destWalletAddress,
        address tokenTo,
        uint256 amount
    );
    event ChangedBridgeDestWalletStatus(uint256 indexed destinationChainId, address indexed destWalletAddress, bool indexed status);
    event ChangedCallerStatus(address indexed caller, bool indexed status);
    event ChangedDestinationChainStatus(uint256 indexed destinationChainId, bool indexed status);
    event ChangedDestWalletStatus(address indexed destWalletAddress, bool indexed status);
    event PairLimitSet(IERC20 indexed tokenFrom, IERC20 indexed tokenTo, uint120 maxSlippage, uint120 maxPriceImpact, bool enabled);
    event BridgeRouteLimitSet(
        IERC20 indexed sourceTokenFrom,
        uint256 indexed destinationChainId,
        address indexed destinationTokenTo,
        uint120 maxSlippage,
        uint120 maxPriceImpact,
        bool enabled
    );
    event SentTokens(IERC20 indexed token, address indexed destWalletAddress, uint256 amount);
    event SwapExecuted(
        address indexed caller,
        IERC20 indexed tokenFrom,
        IERC20 indexed tokenTo,
        address destWalletAddress,
        uint256 amountFrom,
        uint256 amountTo
    );
    event TransferExecuted(address indexed caller, IERC20 indexed token, address indexed destWalletAddress, uint256 amount);
    /// @notice Emitted after a successful `wrapStEth` (stETH pulled, wrapped, wstETH forwarded).
    event StEthWrapped(address indexed caller, address indexed destWalletAddress, uint256 stEthReceived, uint256 wstEthSent);
    /// @notice Emitted when the owner sweeps balances via `withdraw` (after the underlying `SentTokens` send).
    event Withdrawal(address indexed owner, IERC20 indexed token, address indexed destWalletAddress, uint256 amount);

    ////////////////////////////// Errors //////////////////////////////

    error BridgeDestinationNotAllowed(uint256 destinationChainId, address destWalletAddress);
    error BridgePriceImpactExceedsCap(
        IERC20 sourceTokenFrom, uint256 destinationChainId, address destinationTokenTo, int120 signedPriceImpact, uint120 cap
    );
    error BridgeRouteDisabled(IERC20 sourceTokenFrom, uint256 destinationChainId, address destinationTokenTo);
    error BridgeSlippageExceedsCap(
        IERC20 sourceTokenFrom, uint256 destinationChainId, address destinationTokenTo, int120 signedSlippage, uint120 cap
    );
    error BridgeSourceNotConsumed(uint256 expected, uint256 consumed);
    error CallerNotAllowed();
    error DestinationChainNotAllowed(uint256 destinationChainId);
    error DestinationWalletNotAllowed();
    error FailedNativeTokenTransfer(address destWalletAddress);
    error InputLengthsMismatch();
    error InvalidApiSignature();
    error InvalidEmptyDelegations();
    error InvalidIdenticalTokens();
    error InvalidPercent(uint256 percent);
    error InvalidZeroAddress();
    error PairDisabled(IERC20 tokenFrom, IERC20 tokenTo);
    error PriceImpactExceedsCap(IERC20 tokenFrom, IERC20 tokenTo, int120 signedPriceImpact, uint120 cap);
    error SignatureExpired();
    error SlippageExceedsCap(IERC20 tokenFrom, IERC20 tokenTo, int120 signedSlippage, uint120 cap);
    error UnexpectedRedeemedAmount(uint256 expected, uint256 obtained);
    error StEthFlowNotConfigured();
    error AlreadyInitialized();
    error NotInitialized();

    ////////////////////////////// Modifiers //////////////////////////////

    /// @notice Restricts calls to addresses marked allowed by the owner via `updateAllowedCallers`.
    modifier onlyAllowedCaller() {
        if (!isCallerAllowed[msg.sender]) revert CallerNotAllowed();
        _;
    }

    /// @notice Ensures `initialize` has been called successfully.
    /// @dev Reverts with `NotInitialized` when `_initialized` is false.
    modifier whenInitialized() {
        if (!_initialized) revert NotInitialized();
        _;
    }

    ////////////////////////////// Constructor //////////////////////////////

    /**
     * @notice Minimal constructor for deterministic cross-chain deployments; call `initialize` once before use.
     * @param _owner Initial owner (`Ownable2Step`).
     */
    constructor(address _owner) Ownable(_owner) { }

    /**
     * @notice One-time wiring of protocol addresses and API signer. Must be called by the owner after deployment.
     * @param _apiSigner Address that signs `SignatureData` for swap and bridge.
     * @param _delegationManager Trusted delegation manager contract.
     * @param _metaSwap Trusted MetaSwap implementation.
     * @param _metaBridge Trusted MetaBridge implementation.
     * @param _weth This chain’s WETH token for native aliasing in policies.
     * @param _stEth Lido stETH; `address(0)` on chains without stETH.
     * @param _wstEth Lido wstETH; `address(0)` if `stEth` is `address(0)`.
     */
    function initialize(
        address _apiSigner,
        IDelegationManager _delegationManager,
        IMetaSwap _metaSwap,
        IMetaBridge _metaBridge,
        IERC20 _weth,
        address _stEth,
        address _wstEth
    )
        external
        onlyOwner
    {
        if (_initialized) revert AlreadyInitialized();
        _requireNonZero(address(_delegationManager));
        _requireNonZero(address(_metaSwap));
        _requireNonZero(address(_metaBridge));
        _requireNonZero(address(_weth));

        delegationManager = _delegationManager;
        metaSwap = _metaSwap;
        metaBridge = _metaBridge;
        weth = _weth;
        stEth = _stEth;
        wstEth = _wstEth;
        _setApiSigner(_apiSigner);

        _initialized = true;
        emit TreasuryInitialized(_apiSigner, _delegationManager, _metaSwap, _metaBridge, _weth, _stEth, _wstEth);
    }

    /// @notice Accepts native token when delegation redemption sends ETH to this contract.
    receive() external payable { }

    ////////////////////////////// External methods — redeemers //////////////////////////////

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
        whenInitialized
        onlyAllowedCaller
        nonReentrant
    {
        if (!isDestWalletAllowed[_destWalletAddress]) revert DestinationWalletNotAllowed();

        _redeemTransfer(_delegations, _token, _amount, _amount);

        _sendTokens(_token, _amount, _destWalletAddress);
        emit TransferExecuted(msg.sender, _token, _destWalletAddress, _amount);
    }

    /**
     * @notice Pulls stETH via delegation, wraps whatever was received to wstETH, sends the minted wstETH to `_destWalletAddress`.
     * @dev `redeemDelegations` executes `stETH.transfer(this, _amount)` as authorized by delegations; the **actual** stETH
     *      credited can differ from `_amount` (e.g. share rounding). We measure the balance delta and wrap that entirely.
     *      No API signature. Payout must be `isDestWalletAllowed` or match `IDeleGatorModule(rootDelegator).safe()`
     *      (same as `swap`).
     * @param _delegations Delegation chain authorizing the pull into this contract.
     * @param _amount Amount requested in the redemption execution (must match what delegations authorize).
     * @param _destWalletAddress Payout address; allowlisted or the root delegator’s Safe.
     * @return wstEthSent_ Measured wstETH minted and forwarded.
     */
    function wrapStEth(
        Delegation[] calldata _delegations,
        uint256 _amount,
        address _destWalletAddress
    )
        external
        whenInitialized
        onlyAllowedCaller
        nonReentrant
        returns (uint256 wstEthSent_)
    {
        if (stEth == address(0) || wstEth == address(0)) revert StEthFlowNotConfigured();
        _validateSwapOrWrapDestWallet(_destWalletAddress, _delegations);

        uint256 stEthReceived_ = _redeemTransfer(_delegations, IERC20(stEth), _amount, 0);

        IERC20 stEthToken_ = IERC20(stEth);
        IERC20 wstEthToken_ = IERC20(wstEth);

        if (stEthToken_.allowance(address(this), wstEth) < stEthReceived_) {
            stEthToken_.forceApprove(wstEth, type(uint256).max);
        }

        wstEthSent_ = IWstETH(wstEth).wrap(stEthReceived_);

        _sendTokens(wstEthToken_, wstEthSent_, _destWalletAddress);
        emit StEthWrapped(msg.sender, _destWalletAddress, stEthReceived_, wstEthSent_);
    }

    /**
     * @notice Redeems input tokens via delegation, executes MetaSwap, and sends output to `_signatureData.destWalletAddress`.
     * @dev Validates signature (including destination wallet via `destWalletAddress`), per-pair caps and `enabled` flag in
     *      `pairLimits`, and destination policy (`isDestWalletAllowed` or root Safe via `IDeleGatorModule.safe()`).
     * @param _signatureData API-signed swap payload; `destWalletAddress` is where output tokens are sent.
     * @param _delegations Delegation chain authorizing the pull of `tokenFrom` / `amountFrom` derived from
     *                     `_signatureData.apiData`.
     */
    function swap(
        SignatureData calldata _signatureData,
        Delegation[] calldata _delegations
    )
        external
        whenInitialized
        onlyAllowedCaller
        nonReentrant
    {
        _validateApiSignature(_signatureData);
        _validateSwapOrWrapDestWallet(_signatureData.destWalletAddress, _delegations);

        (string memory aggregatorId_, IERC20 tokenFrom_, IERC20 tokenTo_, uint256 amountFrom_, bytes memory swapData_) =
            TreasuryCalldataDecoder.decodeSwapApiData(_signatureData.apiData);

        _validatePairPolicy(tokenFrom_, tokenTo_, _signatureData.slippage, _signatureData.priceImpact);

        _redeemTransfer(_delegations, tokenFrom_, amountFrom_, amountFrom_);

        uint256 amountTo_ =
            _swapTokens(aggregatorId_, tokenFrom_, tokenTo_, amountFrom_, swapData_, _signatureData.destWalletAddress);
        emit SwapExecuted(msg.sender, tokenFrom_, tokenTo_, _signatureData.destWalletAddress, amountFrom_, amountTo_);
    }

    /**
     * @notice Redeems source tokens via delegation then calls MetaBridge with the signed opaque adapter payload.
     * @dev Validates signature (including `destWalletAddress`), chain policy, `isBridgeDestWalletAllowed` for the signed
     *      destination wallet, and per-route caps and `enabled` flag in
     *      `bridgeRouteLimits[sourceTokenFrom][destinationChainId][destinationTokenTo]` against the signed slippage and
     *      price impact. The adapter's own `destWalletAddress` is intentionally ignored — only
     *      `_signatureData.destWalletAddress` governs payout.
     * @param _signatureData API-signed bridge payload (`apiData` encodes `IMetaBridge.bridge`-style calldata).
     * @param _delegations Delegation chain authorizing the pull of outer `amountFrom` / `tokenFrom`.
     */
    function bridge(
        SignatureData calldata _signatureData,
        Delegation[] calldata _delegations
    )
        external
        whenInitialized
        onlyAllowedCaller
        nonReentrant
    {
        _validateApiSignature(_signatureData);

        (
            string memory adapterId_,
            IERC20 tokenFromOuter_,
            uint256 amountFrom_,
            bytes memory bridgeInnerBytes_,
            TreasuryCalldataDecoder.BridgeAdapterDecoded memory inner_
        ) = TreasuryCalldataDecoder.decodeBridgeApiData(_signatureData.apiData);

        _validateBridgePolicies(inner_, _signatureData.destWalletAddress);

        _validateBridgeRoutePolicy(
            tokenFromOuter_, inner_.destinationChainId, inner_.tokenTo, _signatureData.slippage, _signatureData.priceImpact
        );

        _redeemTransfer(_delegations, tokenFromOuter_, amountFrom_, amountFrom_);

        _bridgeTokens(adapterId_, tokenFromOuter_, amountFrom_, bridgeInnerBytes_);

        emit BridgeInitiated(
            msg.sender, tokenFromOuter_, inner_.destinationChainId, _signatureData.destWalletAddress, inner_.tokenTo, amountFrom_
        );
    }

    ////////////////////////////// External methods — owner //////////////////////////////

    /**
     * @notice Rotates the address authorized to sign swap and bridge API payloads.
     * @param _newSigner New signer; must not be the zero address.
     */
    function setApiSigner(address _newSigner) external onlyOwner whenInitialized {
        _setApiSigner(_newSigner);
    }

    /**
     * @notice Owner-only sweep of native or ERC-20 balances held by this contract.
     * @dev Any residual stETH/wstETH dust held by this contract can be withdrawn here.
     * @param _token Asset to send; `address(0)` denotes native.
     * @param _amount Amount to transfer.
     * @param _destWalletAddress Receiver of the withdrawal.
     */
    function withdraw(IERC20 _token, uint256 _amount, address _destWalletAddress) external onlyOwner whenInitialized {
        _sendTokens(_token, _amount, _destWalletAddress);
        emit Withdrawal(msg.sender, _token, _destWalletAddress, _amount);
    }

    /**
     * @notice Configures enabled swap pairs and signed slippage / price-impact ceilings.
     * @dev Rejects identical `tokenFrom` / `tokenTo`. WETH inputs are canonicalized to native for storage keys.
     * @param _inputs Per-pair policies to apply.
     */
    function setPairLimits(PairLimitInput[] calldata _inputs) external onlyOwner whenInitialized {
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
     * @notice Configures enabled bridge routes and signed slippage / price-impact ceilings used by `bridge`.
     * @dev Mirrors `setPairLimits` but keyed by `(sourceTokenFrom, destinationChainId, destinationTokenTo)`. Source token
     *      is canonicalized (WETH → native); destination token is stored raw (per-chain addresses, no canonicalization).
     *      No identical-token check: source is on this chain and `destinationTokenTo` is on another.
     * @param _inputs Per-route policies to apply.
     */
    function setBridgeRouteLimits(BridgeRouteLimitInput[] calldata _inputs) external onlyOwner whenInitialized {
        uint256 length_ = _inputs.length;
        for (uint256 i = 0; i < length_;) {
            BridgeRouteLimitInput calldata routeInput_ = _inputs[i];

            if (routeInput_.limit.maxSlippage > MAX_PERCENT) revert InvalidPercent(routeInput_.limit.maxSlippage);
            if (routeInput_.limit.maxPriceImpact > MAX_PERCENT) revert InvalidPercent(routeInput_.limit.maxPriceImpact);

            IERC20 sourceTokenFrom_ = _canonNative(routeInput_.sourceTokenFrom);
            bridgeRouteLimits[sourceTokenFrom_][routeInput_.destinationChainId][routeInput_.destinationTokenTo] = routeInput_.limit;
            emit BridgeRouteLimitSet(
                sourceTokenFrom_,
                routeInput_.destinationChainId,
                routeInput_.destinationTokenTo,
                routeInput_.limit.maxSlippage,
                routeInput_.limit.maxPriceImpact,
                routeInput_.limit.enabled
            );

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Sets `isBridgeDestWalletAllowed` for the signed `destWalletAddress` on `bridge` (per destination chain). Not
     *         used for `transfer` or swap; see `updateAllowedDestWallets` for those.
     * @param _destinationChainId Chain id as encoded in bridge adapter data (inner `destinationChainId`).
     * @param _destWalletAddresses Addresses to update (typically bridge destination wallets).
     * @param _statuses Parallel allow flags; must match `_destWalletAddresses.length`.
     */
    function updateAllowedBridgeDestWallets(
        uint256 _destinationChainId,
        address[] calldata _destWalletAddresses,
        bool[] calldata _statuses
    )
        external
        onlyOwner
        whenInitialized
    {
        uint256 length_ = _destWalletAddresses.length;
        if (length_ != _statuses.length) revert InputLengthsMismatch();
        for (uint256 i = 0; i < length_;) {
            address destWallet_ = _destWalletAddresses[i];
            bool status_ = _statuses[i];
            if (isBridgeDestWalletAllowed[_destinationChainId][destWallet_] != status_) {
                isBridgeDestWalletAllowed[_destinationChainId][destWallet_] = status_;
                emit ChangedBridgeDestWalletStatus(_destinationChainId, destWallet_, status_);
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
    function updateAllowedCallers(address[] calldata _callers, bool[] calldata _statuses) external onlyOwner whenInitialized {
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
     * @notice Updates `isDestWalletAllowed`: payout destinations for `transfer`, and the allowlist branch for `wrapStEth` /
     *         `swap` (both also accept the root delegator’s Safe from `IDeleGatorModule.safe()`).
     * @dev Bridge payout wallets are configured with `updateAllowedBridgeDestWallets`, not here.
     * @param _destWalletAddresses Addresses to update.
     * @param _statuses Parallel flags; must match `_destWalletAddresses.length`.
     */
    function updateAllowedDestWallets(
        address[] calldata _destWalletAddresses,
        bool[] calldata _statuses
    )
        external
        onlyOwner
        whenInitialized
    {
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
     * @notice Allowlists destination chain ids for `bridge` (must match inner `destinationChainId`).
     * @param _chainIds Chain ids to update.
     * @param _statuses Parallel flags; must match `_chainIds.length`.
     */
    function updateDestinationChains(uint256[] calldata _chainIds, bool[] calldata _statuses) external onlyOwner whenInitialized {
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

    ////////////////////////////// Public view //////////////////////////////

    /// @return True after `initialize` has succeeded.
    function isInitialized() public view returns (bool) {
        return _initialized;
    }

    /**
     * @notice Returns stored swap policy for a pair, with WETH normalized to native for lookups.
     * @param _tokenFrom Swap input token for the pair key.
     * @param _tokenTo Swap output token for the pair key.
     * @return limit_ Stored caps and `enabled` flag; zeroed if never configured.
     */
    function getPairLimit(IERC20 _tokenFrom, IERC20 _tokenTo) public view whenInitialized returns (PairLimit memory limit_) {
        limit_ = pairLimits[_canonNative(_tokenFrom)][_canonNative(_tokenTo)];
    }

    /**
     * @notice Returns stored bridge route policy. WETH on the source side is normalized to native; destination token is
     *         looked up raw (per-chain addresses, no canonicalization).
     * @param _sourceTokenFrom Source-chain input token (this chain); WETH is canonicalized to native.
     * @param _destinationChainId Destination chain id (raw).
     * @param _destinationTokenTo Destination-chain output token address (raw, not canonicalized).
     * @return limit_ Stored caps and `enabled` flag; zeroed if never configured.
     */
    function getBridgeRouteLimit(
        IERC20 _sourceTokenFrom,
        uint256 _destinationChainId,
        address _destinationTokenTo
    )
        public
        view
        whenInitialized
        returns (PairLimit memory limit_)
    {
        limit_ = bridgeRouteLimits[_canonNative(_sourceTokenFrom)][_destinationChainId][_destinationTokenTo];
    }

    ////////////////////////////// Internal view //////////////////////////////

    /**
     * @dev Verifies expiry and ECDSA recover against `apiSigner` for swap and bridge `SignatureData`.
     * @param _signatureData User-supplied signed API envelope.
     */
    function _validateApiSignature(SignatureData calldata _signatureData) internal view {
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

    ////////////////////////////// Private //////////////////////////////

    /// @dev Sets `apiSigner` and emits `ApiSignerUpdated(old, new)`. Used by `initialize` and `setApiSigner`.
    function _setApiSigner(address _newSigner) private {
        _requireNonZero(_newSigner);
        address oldSigner_ = apiSigner;
        apiSigner = _newSigner;
        emit ApiSignerUpdated(oldSigner_, _newSigner);
    }

    /**
     * @dev Calls `DelegationManager.redeemDelegations` with a single execution that pulls `transferAmount_` of `_tokenFrom`
     *      into this contract (or native receive). Validates the balance delta `obtained` satisfies
     *      `expectedAmount_ <= obtained <= transferAmount_` (inclusive). `transfer` / `swap` / `bridge` use
     *      `expectedAmount_ == transferAmount_` (exact). `wrapStEth` uses `expectedAmount_ == 0` so any under-credit down to
     *      zero is allowed up to the requested `transferAmount_`.
     * @param _delegations Permission contexts (ABI-encoded single batch); must be non-empty.
     * @param _tokenFrom Asset to pull; `address(0)` schedules a native transfer to this contract.
     * @param transferAmount_ Amount requested in the redemption execution (`transfer` calldata or native `value`); upper bound.
     * @param expectedAmount_ Lower bound on credit received (wei).
     * @return obtained_ Measured balance increase from this redemption.
     */
    function _redeemTransfer(
        Delegation[] calldata _delegations,
        IERC20 _tokenFrom,
        uint256 transferAmount_,
        uint256 expectedAmount_
    )
        private
        returns (uint256 obtained_)
    {
        if (_delegations.length == 0) revert InvalidEmptyDelegations();

        uint256 balanceBefore_ = _getSelfBalance(_tokenFrom);

        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(_delegations);

        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = ModeLib.encodeSimpleSingle();

        bytes[] memory executionCallDatas_ = new bytes[](1);

        if (address(_tokenFrom) == address(0)) {
            executionCallDatas_[0] = ExecutionLib.encodeSingle(address(this), transferAmount_, hex"");
        } else {
            executionCallDatas_[0] = ExecutionLib.encodeSingle(
                address(_tokenFrom), 0, abi.encodeCall(IERC20.transfer, (address(this), transferAmount_))
            );
        }

        delegationManager.redeemDelegations(permissionContexts_, modes_, executionCallDatas_);

        obtained_ = _getSelfBalance(_tokenFrom) - balanceBefore_;

        if (obtained_ < expectedAmount_ || obtained_ > transferAmount_) {
            revert UnexpectedRedeemedAmount(transferAmount_, obtained_);
        }
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
        IMetaSwap metaSwap_ = metaSwap;
        uint256 value_ = _etherValueOrApprove(_tokenFrom, _amountFrom, address(metaSwap_));

        uint256 balanceToBefore_ = _getSelfBalance(_tokenTo);

        metaSwap_.swap{ value: value_ }(_aggregatorId, _tokenFrom, _amountFrom, _swapData);

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

    ////////////////////////////// Private view //////////////////////////////

    /**
     * @dev Requires payout `isDestWalletAllowed` or equality with `IDeleGatorModule(rootDelegator).safe()` (non-zero).
     *      If the destination is not allowlisted, delegations must be non-empty so the root delegator can be read.
     *      Used only by `swap` and `wrapStEth`.
     */
    function _validateSwapOrWrapDestWallet(address _destWalletAddress, Delegation[] calldata _delegations) private view {
        if (isDestWalletAllowed[_destWalletAddress]) return;

        if (_delegations.length == 0) revert DestinationWalletNotAllowed();

        address rootDelegator_ = _delegations[_delegations.length - 1].delegator;
        if (rootDelegator_ == address(0)) revert DestinationWalletNotAllowed();

        address safe_;
        try IDeleGatorModule(rootDelegator_).safe() returns (address s) {
            safe_ = s;
        } catch {
            revert DestinationWalletNotAllowed();
        }
        if (safe_ == address(0) || _destWalletAddress != safe_) revert DestinationWalletNotAllowed();
    }

    /**
     * @dev Ensures the swap pair is enabled and that signed unfavorable slippage / price impact do not exceed stored caps.
     */
    function _validatePairPolicy(
        IERC20 _tokenFrom,
        IERC20 _tokenTo,
        int120 _signedSlippage,
        int120 _signedPriceImpact
    )
        private
        view
    {
        PairLimit memory limit_ = getPairLimit(_tokenFrom, _tokenTo);
        if (!limit_.enabled) revert PairDisabled(_tokenFrom, _tokenTo);
        if (_isQuoteCapExceeded(_signedSlippage, limit_.maxSlippage)) {
            revert SlippageExceedsCap(_tokenFrom, _tokenTo, _signedSlippage, limit_.maxSlippage);
        }
        if (_isQuoteCapExceeded(_signedPriceImpact, limit_.maxPriceImpact)) {
            revert PriceImpactExceedsCap(_tokenFrom, _tokenTo, _signedPriceImpact, limit_.maxPriceImpact);
        }
    }

    /**
     * @dev Ensures the bridge route is enabled and that signed unfavorable slippage / price impact do not exceed stored
     *      caps. Mirrors `_validatePairPolicy` but emits bridge-specific reverts that include the destination chain and
     *      destination token for ops triage.
     */
    function _validateBridgeRoutePolicy(
        IERC20 _sourceTokenFrom,
        uint256 _destinationChainId,
        address _destinationTokenTo,
        int120 _signedSlippage,
        int120 _signedPriceImpact
    )
        private
        view
    {
        PairLimit memory limit_ = getBridgeRouteLimit(_sourceTokenFrom, _destinationChainId, _destinationTokenTo);
        if (!limit_.enabled) revert BridgeRouteDisabled(_sourceTokenFrom, _destinationChainId, _destinationTokenTo);
        if (_isQuoteCapExceeded(_signedSlippage, limit_.maxSlippage)) {
            revert BridgeSlippageExceedsCap(
                _sourceTokenFrom, _destinationChainId, _destinationTokenTo, _signedSlippage, limit_.maxSlippage
            );
        }
        if (_isQuoteCapExceeded(_signedPriceImpact, limit_.maxPriceImpact)) {
            revert BridgePriceImpactExceedsCap(
                _sourceTokenFrom, _destinationChainId, _destinationTokenTo, _signedPriceImpact, limit_.maxPriceImpact
            );
        }
    }

    /**
     * @dev Bundles the per-bridge allowlist checks: destination chain kill switch and per-chain bridge destination wallet
     *      allowlist. Per-route caps and the `tokenTo` policy are enforced by `_validateBridgeRoutePolicy`. The adapter's
     *      own `destWalletAddress` is parsed but intentionally ignored; only the API-signed `_signedDestWalletAddress`
     *      governs payout policy.
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
        if (!isBridgeDestWalletAllowed[destChain_][_signedDestWalletAddress]) {
            revert BridgeDestinationNotAllowed(destChain_, _signedDestWalletAddress);
        }
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

    ////////////////////////////// Private pure //////////////////////////////

    /// @dev Reverts with `InvalidZeroAddress` if `_addr` is the zero address.
    function _requireNonZero(address _addr) private pure {
        if (_addr == address(0)) revert InvalidZeroAddress();
    }

    /**
     * @dev Shared cap check for swap and bridge: caps only constrain unfavorable (positive) signed values; non-positive
     *      values are accepted.
     */
    function _isQuoteCapExceeded(int120 _signedValue, uint120 _cap) private pure returns (bool exceeded_) {
        exceeded_ = _signedValue > 0 && uint120(_signedValue) > _cap;
    }
}
