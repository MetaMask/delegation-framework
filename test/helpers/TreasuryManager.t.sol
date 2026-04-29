// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { BasicERC20 } from "../utils/BasicERC20.t.sol";
import { TreasuryManager } from "../../src/helpers/TreasuryManager.sol";
import { TreasuryCalldataDecoder } from "../../src/helpers/libraries/TreasuryCalldataDecoder.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";
import { IMetaSwap } from "../../src/helpers/interfaces/IMetaSwap.sol";
import { IMetaBridge } from "../../src/helpers/interfaces/IMetaBridge.sol";
import { Caveat, Delegation, ModeCode } from "../../src/utils/Types.sol";

contract MockDelegationManager is IDelegationManager {
    using SafeERC20 for IERC20;

    IERC20 public pullToken;
    uint256 public pullAmount;
    address public pullFrom;
    /// @dev Number of wei to subtract from the redeemed amount; simulates short pulls (Lido share rounding,
    ///      fee-on-transfer behavior, or buggy DelegationManager). Set via `setPullShortBy`.
    uint256 public pullShortBy;
    /// @dev Number of wei to add to the redeemed amount; simulates over-credit so the contract's strict equality
    ///      check fires. Set via `setPullExtra`.
    uint256 public pullExtra;

    function setPull(IERC20 t, uint256 a, address f) external {
        pullToken = t;
        pullAmount = a;
        pullFrom = f;
        pullShortBy = 0;
        pullExtra = 0;
    }

    function setPullShortBy(uint256 s) external {
        pullShortBy = s;
        pullExtra = 0;
    }

    function setPullExtra(uint256 e) external {
        pullExtra = e;
        pullShortBy = 0;
    }

    function redeemDelegations(bytes[] calldata, ModeCode[] calldata, bytes[] calldata) external override {
        uint256 actual = pullAmount + pullExtra - pullShortBy;
        if (address(pullToken) == address(0)) {
            payable(msg.sender).transfer(actual);
        } else {
            pullToken.safeTransferFrom(pullFrom, msg.sender, actual);
        }
    }

    function pause() external pure override { }
    function unpause() external pure override { }
    function enableDelegation(Delegation calldata) external pure override { }
    function disableDelegation(Delegation calldata) external pure override { }

    function disabledDelegations(bytes32) external pure override returns (bool) {
        return false;
    }

    function getDelegationHash(Delegation calldata d) external pure override returns (bytes32) {
        return keccak256(abi.encode(d.delegate, d.delegator, d.authority, d.salt));
    }

    function getDomainHash() external pure override returns (bytes32) {
        return bytes32(0);
    }

    receive() external payable { }
}

contract MockMetaSwap is IMetaSwap {
    IERC20 public immutable tokenOut;

    constructor(IERC20 _tokenOut) {
        tokenOut = _tokenOut;
    }

    function swap(string calldata, IERC20 tokenFrom, uint256 amount, bytes calldata) external payable override {
        if (address(tokenFrom) != address(0)) {
            IERC20(tokenFrom).transferFrom(msg.sender, address(this), amount);
        }
        IERC20(tokenOut).transfer(msg.sender, amount);
    }
}

contract MockMetaBridge is IMetaBridge {
    /// @dev When true, `bridge` returns success without pulling the source token (used to test
    ///      `BridgeSourceNotConsumed`).
    bool public noOp;

    function setNoOp(bool _noOp) external {
        noOp = _noOp;
    }

    function bridge(string calldata, address srcToken, uint256 amount, bytes calldata) external payable override {
        if (noOp) return;
        if (srcToken == address(0)) return;
        IERC20(srcToken).transferFrom(msg.sender, address(this), amount);
    }
}

/// @dev Fails on receive(); used to trigger `FailedNativeTokenTransfer` via destination wallet.
contract NativeRejecter {
    receive() external payable {
        revert("nope");
    }
}

/// @dev Simulates Lido stETH per-transfer share-rounding by crediting `transfer`/`transferFrom` recipients with
///      `amount - shortBy` instead of `amount`. Internal accounting still debits the full `amount` from the sender.
contract MockStEth is BasicERC20 {
    uint256 public shortBy;

    constructor(address _owner) BasicERC20(_owner, "stETH", "stETH", 0) { }

    function setShortBy(uint256 _shortBy) external {
        shortBy = _shortBy;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        // Mimic real stETH: debit sender by the full declared amount, credit recipient by amount - shortBy. The
        // missing wei is captured by this contract (representing the rounding "evaporation").
        super.transfer(address(this), shortBy);
        return super.transfer(to, amount - shortBy);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        // Same model on the pull side: debit `from` by the full amount, credit `to` by amount - shortBy.
        super.transferFrom(from, address(this), shortBy);
        return super.transferFrom(from, to, amount - shortBy);
    }
}

contract TreasuryManagerTest is Test {
    uint256 internal constant SLIPPAGE = 1e18;
    uint256 internal constant PRICE_IMPACT = 1e18;
    uint256 internal constant DEST_CHAIN = 42161;

    MockDelegationManager internal delegationManager;
    MockMetaSwap internal metaSwap;
    MockMetaBridge internal metaBridge;
    BasicERC20 internal tokenA;
    BasicERC20 internal tokenB;
    BasicERC20 internal weth;
    MockStEth internal stEth;
    TreasuryManager internal treasury;
    /// @dev Pre-funded stETH balance the treasury holds in `setUp` to cover share-rounding shortfalls.
    uint256 internal constant STETH_PREFUND = 100 ether;

    address internal owner = makeAddr("owner");
    address internal caller = makeAddr("caller");
    address internal destWalletAddress = makeAddr("destWalletAddress");
    address internal pullFrom = makeAddr("pullFrom");
    address internal stranger = makeAddr("stranger");

    uint256 internal signerPk;
    address internal apiSigner;
    uint256 internal otherPk;

    function setUp() public {
        delegationManager = new MockDelegationManager();
        (apiSigner, signerPk) = makeAddrAndKey("apiSigner");
        (, otherPk) = makeAddrAndKey("otherSigner");

        vm.startPrank(owner);
        tokenA = new BasicERC20(owner, "A", "A", 0);
        tokenB = new BasicERC20(owner, "B", "B", 0);
        weth = new BasicERC20(owner, "WETH", "WETH", 0);
        stEth = new MockStEth(owner);
        metaSwap = new MockMetaSwap(tokenB);
        metaBridge = new MockMetaBridge();

        tokenB.mint(address(metaSwap), type(uint128).max);

        treasury =
            new TreasuryManager(owner, apiSigner, delegationManager, metaSwap, metaBridge, IERC20(address(weth)), address(stEth));

        treasury.updateAllowedCallers(_singleAddr(caller), _singleBool(true));
        treasury.updateAllowedDestWallets(_singleAddr(destWalletAddress), _singleBool(true));
        treasury.updateAllowedTokensTo(_singleTok(tokenB), _singleBool(true));
        treasury.setPairLimits(_pairLimits(tokenA, tokenB, true));
        tokenA.mint(pullFrom, 1_000 ether);
        stEth.mint(pullFrom, 1_000 ether);
        // Pre-fund the treasury with stETH so the share-rounding tolerance has a balance to draw from.
        stEth.mint(address(treasury), STETH_PREFUND);
        vm.stopPrank();

        vm.prank(pullFrom);
        tokenA.approve(address(delegationManager), type(uint256).max);
        vm.prank(pullFrom);
        stEth.approve(address(delegationManager), type(uint256).max);
    }

    /////////////////////// Constructor ///////////////////////

    function test_constructor_setsImmutables() public {
        assertEq(address(treasury.delegationManager()), address(delegationManager));
        assertEq(address(treasury.metaSwap()), address(metaSwap));
        assertEq(address(treasury.metaBridge()), address(metaBridge));
        assertEq(address(treasury.weth()), address(weth));
        assertEq(treasury.stEth(), address(stEth));
        assertEq(treasury.apiSigner(), apiSigner);
        assertEq(treasury.owner(), owner);
    }

    function test_revert_constructor_zeroDelegationManager() public {
        vm.expectRevert(TreasuryManager.InvalidZeroAddress.selector);
        new TreasuryManager(
            owner, apiSigner, IDelegationManager(address(0)), metaSwap, metaBridge, IERC20(address(weth)), address(stEth)
        );
    }

    function test_revert_constructor_zeroMetaSwap() public {
        vm.expectRevert(TreasuryManager.InvalidZeroAddress.selector);
        new TreasuryManager(
            owner, apiSigner, delegationManager, IMetaSwap(address(0)), metaBridge, IERC20(address(weth)), address(stEth)
        );
    }

    function test_revert_constructor_zeroMetaBridge() public {
        vm.expectRevert(TreasuryManager.InvalidZeroAddress.selector);
        new TreasuryManager(
            owner, apiSigner, delegationManager, metaSwap, IMetaBridge(address(0)), IERC20(address(weth)), address(stEth)
        );
    }

    function test_revert_constructor_zeroWeth() public {
        vm.expectRevert(TreasuryManager.InvalidZeroAddress.selector);
        new TreasuryManager(owner, apiSigner, delegationManager, metaSwap, metaBridge, IERC20(address(0)), address(stEth));
    }

    function test_revert_constructor_zeroApiSigner() public {
        vm.expectRevert(TreasuryManager.InvalidZeroAddress.selector);
        new TreasuryManager(owner, address(0), delegationManager, metaSwap, metaBridge, IERC20(address(weth)), address(stEth));
    }

    /////////////////////// setApiSigner ///////////////////////

    function test_setApiSigner_rotatesAndAcceptsNewSignerOnly() public {
        // Strong rotation test: after setApiSigner, signatures from the OLD signer must be rejected and signatures
        // from the NEW signer must be accepted. Storage equality alone wouldn't catch a bug where _validateSignature
        // hard-coded the old signer.
        (address newSigner, uint256 newPk) = makeAddrAndKey("newSigner");

        vm.prank(owner);
        vm.expectEmit(true, true, false, true, address(treasury));
        emit TreasuryManager.ApiSignerUpdated(apiSigner, newSigner);
        treasury.setApiSigner(newSigner);
        assertEq(treasury.apiSigner(), newSigner, "storage updated");

        // Old signer is now rejected.
        uint256 amt = 1 ether;
        bytes memory apiData = _swapApi(tokenA, tokenB, amt, amt, true);
        delegationManager.setPull(IERC20(address(tokenA)), amt, pullFrom);
        TreasuryManager.SignatureData memory oldSig = _signWith(
            apiData, destWalletAddress, block.timestamp + 1 days, int120(int256(SLIPPAGE)), int120(int256(PRICE_IMPACT)), signerPk
        );
        vm.prank(caller);
        vm.expectRevert(TreasuryManager.InvalidApiSignature.selector);
        treasury.swap(oldSig, _dummyDelegations());

        // New signer is accepted.
        TreasuryManager.SignatureData memory newSig = _signWith(
            apiData, destWalletAddress, block.timestamp + 1 days, int120(int256(SLIPPAGE)), int120(int256(PRICE_IMPACT)), newPk
        );
        vm.prank(caller);
        treasury.swap(newSig, _dummyDelegations());
        assertEq(tokenB.balanceOf(destWalletAddress), amt, "swap with new signer succeeded");
    }

    function test_revert_setApiSigner_zeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(TreasuryManager.InvalidZeroAddress.selector);
        treasury.setApiSigner(address(0));
    }

    function test_revert_setApiSigner_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        treasury.setApiSigner(stranger);
    }

    /////////////////////// transfer ///////////////////////

    function test_transfer_pullsAndPaysDestWallet() public {
        uint256 amt = 3 ether;
        delegationManager.setPull(IERC20(address(tokenA)), amt, pullFrom);

        uint256 balBefore = tokenA.balanceOf(destWalletAddress);
        vm.expectEmit(true, true, true, true, address(treasury));
        emit TreasuryManager.SentTokens(IERC20(address(tokenA)), destWalletAddress, amt);
        vm.expectEmit(true, true, true, true, address(treasury));
        emit TreasuryManager.TransferExecuted(caller, IERC20(address(tokenA)), destWalletAddress, amt);
        vm.prank(caller);
        treasury.transfer(_dummyDelegations(), IERC20(address(tokenA)), amt, destWalletAddress);
        assertEq(tokenA.balanceOf(destWalletAddress) - balBefore, amt);
    }

    function test_transfer_native() public {
        uint256 amt = 1 ether;
        delegationManager.setPull(IERC20(address(0)), amt, address(0));
        vm.deal(address(delegationManager), amt);

        uint256 balBefore = destWalletAddress.balance;
        vm.expectEmit(true, true, true, true, address(treasury));
        emit TreasuryManager.SentTokens(IERC20(address(0)), destWalletAddress, amt);
        vm.expectEmit(true, true, true, true, address(treasury));
        emit TreasuryManager.TransferExecuted(caller, IERC20(address(0)), destWalletAddress, amt);
        vm.prank(caller);
        treasury.transfer(_dummyDelegations(), IERC20(address(0)), amt, destWalletAddress);
        assertEq(destWalletAddress.balance - balBefore, amt);
    }

    function test_revert_transfer_CallerNotAllowed() public {
        vm.prank(stranger);
        vm.expectRevert(TreasuryManager.CallerNotAllowed.selector);
        treasury.transfer(_dummyDelegations(), IERC20(address(tokenA)), 1 ether, destWalletAddress);
    }

    function test_revert_transfer_DestinationWalletNotAllowed() public {
        vm.prank(owner);
        treasury.updateAllowedDestWallets(_singleAddr(destWalletAddress), _singleBool(false));
        vm.prank(caller);
        vm.expectRevert(TreasuryManager.DestinationWalletNotAllowed.selector);
        treasury.transfer(_dummyDelegations(), IERC20(address(tokenA)), 1 ether, destWalletAddress);
    }

    function test_revert_transfer_InvalidEmptyDelegations() public {
        Delegation[] memory empty = new Delegation[](0);
        vm.prank(caller);
        vm.expectRevert(TreasuryManager.InvalidEmptyDelegations.selector);
        treasury.transfer(empty, IERC20(address(tokenA)), 1 ether, destWalletAddress);
    }

    function test_revert_transfer_UnexpectedTokenFromAmount() public {
        uint256 amt = 1 ether;
        delegationManager.setPull(IERC20(address(tokenA)), amt, pullFrom);
        delegationManager.setPullShortBy(1);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(TreasuryManager.UnexpectedTokenFromAmount.selector, amt, amt - 1));
        treasury.transfer(_dummyDelegations(), IERC20(address(tokenA)), amt, destWalletAddress);
    }

    function test_revert_transfer_overCredit() public {
        // Even a benign over-credit (delegator-side bug or callback-on-transfer) must trip strict equality.
        uint256 amt = 1 ether;
        // pullFrom already has 1_000 ether tokenA from setUp, plenty for the extra wei.
        delegationManager.setPull(IERC20(address(tokenA)), amt, pullFrom);
        delegationManager.setPullExtra(1);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(TreasuryManager.UnexpectedTokenFromAmount.selector, amt, amt + 1));
        treasury.transfer(_dummyDelegations(), IERC20(address(tokenA)), amt, destWalletAddress);
    }

    function test_revert_transfer_FailedNativeTokenTransfer() public {
        NativeRejecter rejecter = new NativeRejecter();
        vm.prank(owner);
        treasury.updateAllowedDestWallets(_singleAddr(address(rejecter)), _singleBool(true));

        uint256 amt = 1 ether;
        delegationManager.setPull(IERC20(address(0)), amt, address(0));
        vm.deal(address(delegationManager), amt);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(TreasuryManager.FailedNativeTokenTransfer.selector, address(rejecter)));
        treasury.transfer(_dummyDelegations(), IERC20(address(0)), amt, address(rejecter));
    }

    /////////////////////// swap ///////////////////////

    function test_swap_deliversOutputToDestWallet() public {
        uint256 amt = 2 ether;
        delegationManager.setPull(IERC20(address(tokenA)), amt, pullFrom);
        bytes memory apiData = _swapApi(tokenA, tokenB, amt, amt, true);
        TreasuryManager.SignatureData memory sig = _sign(apiData, destWalletAddress);

        uint256 rBefore = tokenB.balanceOf(destWalletAddress);
        vm.expectEmit(true, true, true, true, address(treasury));
        emit TreasuryManager.SentTokens(IERC20(address(tokenB)), destWalletAddress, amt);
        vm.expectEmit(true, true, true, true, address(treasury));
        emit TreasuryManager.SwapExecuted(caller, IERC20(address(tokenA)), IERC20(address(tokenB)), destWalletAddress, amt, amt);
        vm.prank(caller);
        treasury.swap(sig, _dummyDelegations());
        assertEq(tokenB.balanceOf(destWalletAddress) - rBefore, amt);
    }

    function test_swap_reusesAllowanceOnRepeatCall() public {
        // First swap force-approves metaSwap to type(uint256).max; second swap finds the allowance already sufficient
        // and skips the approve step. Exercises the "allowance >= amount" branch of `_etherValueOrApprove` (the only
        // branch unreachable with a single swap).
        uint256 amt = 1 ether;
        bytes memory apiData = _swapApi(tokenA, tokenB, amt, amt, true);
        TreasuryManager.SignatureData memory sig = _sign(apiData, destWalletAddress);

        delegationManager.setPull(IERC20(address(tokenA)), amt, pullFrom);
        vm.prank(caller);
        treasury.swap(sig, _dummyDelegations());
        assertEq(tokenA.allowance(address(treasury), address(metaSwap)), type(uint256).max, "first swap force-approves to max");

        // Re-arm. Identical sig (same block.timestamp); the second call hits the no-op branch (allowance already max).
        delegationManager.setPull(IERC20(address(tokenA)), amt, pullFrom);
        vm.prank(caller);
        treasury.swap(sig, _dummyDelegations());

        assertEq(tokenB.balanceOf(destWalletAddress), 2 * amt, "dest receives both swaps' output");
        // OZ ERC20 does NOT decrement infinite approvals; the allowance stays at max regardless of how many times
        // metaSwap's transferFrom is invoked. The point of the assertion is that the second swap did not call
        // forceApprove again — if it had, allowance would still be max either way, so we instead rely on coverage to
        // confirm the no-op branch executed (the "allowance >= amount" path in `_etherValueOrApprove`).
        assertEq(tokenA.allowance(address(treasury), address(metaSwap)), type(uint256).max, "allowance still max");
    }

    function test_swap_stETHInput_appliesTolerance() public {
        // stETH-as-swap-input: redemption short by 1 wei; topup applied; metaSwap pulls full `amt` from treasury.
        uint256 amt = 2 ether;
        delegationManager.setPull(IERC20(address(stEth)), amt, pullFrom);
        stEth.setShortBy(1);

        vm.startPrank(owner);
        treasury.setPairLimits(_pairLimits(IERC20(address(stEth)), tokenB, true));
        vm.stopPrank();

        bytes memory apiData = _swapApi(IERC20(address(stEth)), tokenB, amt, amt, true);
        TreasuryManager.SignatureData memory sig = _sign(apiData, destWalletAddress);

        uint256 prefundBefore = stEth.balanceOf(address(treasury));
        uint256 destBefore = tokenB.balanceOf(destWalletAddress);

        vm.prank(caller);
        treasury.swap(sig, _dummyDelegations());

        // Treasury net stETH change: +(amt - 1) [redeem] - amt [metaSwap.transferFrom] = -1 wei.
        assertEq(prefundBefore - stEth.balanceOf(address(treasury)), 1, "prefund covers 1 wei");
        assertEq(tokenB.balanceOf(destWalletAddress) - destBefore, amt, "dest receives full tokenB output");
    }

    function test_swap_wethInput_canonicalizesAtRuntime() public {
        // Pass the actual WETH address (not `address(0)`) as the swap input. `_canonNative` runs at execution time
        // for both the pair-limit lookup AND the `isTokenToAllowed` check, so the swap proceeds against the
        // canonical (address(0), tokenB) entries set up via WETH at config time.
        uint256 amt = 1 ether;
        vm.startPrank(owner);
        weth.mint(pullFrom, amt);
        treasury.setPairLimits(_pairLimits(IERC20(address(weth)), tokenB, true));
        vm.stopPrank();
        vm.prank(pullFrom);
        weth.approve(address(delegationManager), type(uint256).max);

        delegationManager.setPull(IERC20(address(weth)), amt, pullFrom);
        bytes memory apiData = _swapApi(IERC20(address(weth)), tokenB, amt, amt, true);
        TreasuryManager.SignatureData memory sig = _sign(apiData, destWalletAddress);

        uint256 destBefore = tokenB.balanceOf(destWalletAddress);
        vm.prank(caller);
        treasury.swap(sig, _dummyDelegations());
        assertEq(tokenB.balanceOf(destWalletAddress) - destBefore, amt, "dest receives tokenB after swap from WETH");
    }

    function test_swap_nativeInput_routesEthThroughMetaSwap() public {
        // Pull native ETH from the delegation; covers the native branch of `_etherValueOrApprove`.
        uint256 amt = 1 ether;
        delegationManager.setPull(IERC20(address(0)), amt, address(0));
        vm.deal(address(delegationManager), amt);

        // Allow the (native, tokenB) pair so swap can proceed.
        vm.prank(owner);
        treasury.setPairLimits(_pairLimits(IERC20(address(0)), tokenB, true));

        bytes memory apiData = _swapApi(IERC20(address(0)), tokenB, amt, amt, true);
        TreasuryManager.SignatureData memory sig = _sign(apiData, destWalletAddress);

        uint256 rBefore = tokenB.balanceOf(destWalletAddress);
        uint256 metaSwapEthBefore = address(metaSwap).balance;

        vm.prank(caller);
        treasury.swap(sig, _dummyDelegations());

        assertEq(tokenB.balanceOf(destWalletAddress) - rBefore, amt, "dest wallet should receive tokenB");
        assertEq(address(metaSwap).balance - metaSwapEthBefore, amt, "metaSwap should have received native ETH");
    }

    function test_revert_swap_InvalidEmptyDelegations() public {
        bytes memory apiData = _swapApi(tokenA, tokenB, 1 ether, 1 ether, true);
        TreasuryManager.SignatureData memory sig = _sign(apiData, destWalletAddress);
        vm.prank(caller);
        vm.expectRevert(TreasuryManager.InvalidEmptyDelegations.selector);
        treasury.swap(sig, new Delegation[](0));
    }

    function test_revert_swap_SignatureExpired() public {
        bytes memory apiData = _swapApi(tokenA, tokenB, 1 ether, 1 ether, true);
        // expiration in the past (relative to block.timestamp)
        vm.warp(1_000_000);
        TreasuryManager.SignatureData memory sig = _signWith(
            apiData, destWalletAddress, block.timestamp, int120(int256(SLIPPAGE)), int120(int256(PRICE_IMPACT)), signerPk
        );
        vm.prank(caller);
        vm.expectRevert(TreasuryManager.SignatureExpired.selector);
        treasury.swap(sig, _dummyDelegations());
    }

    function test_revert_swap_InvalidApiSignature() public {
        bytes memory apiData = _swapApi(tokenA, tokenB, 1 ether, 1 ether, true);
        TreasuryManager.SignatureData memory sig = _signWith(
            apiData, destWalletAddress, block.timestamp + 1 days, int120(int256(SLIPPAGE)), int120(int256(PRICE_IMPACT)), otherPk
        );
        vm.prank(caller);
        vm.expectRevert(TreasuryManager.InvalidApiSignature.selector);
        treasury.swap(sig, _dummyDelegations());
    }

    function test_revert_swap_DestinationWalletNotAllowed() public {
        bytes memory apiData = _swapApi(tokenA, tokenB, 1 ether, 1 ether, true);
        address other = makeAddr("notAllowedDest");
        TreasuryManager.SignatureData memory sig = _sign(apiData, other);
        vm.prank(caller);
        vm.expectRevert(TreasuryManager.DestinationWalletNotAllowed.selector);
        treasury.swap(sig, _dummyDelegations());
    }

    function test_revert_swap_TokenToNotAllowed() public {
        vm.prank(owner);
        treasury.updateAllowedTokensTo(_singleTok(tokenB), _singleBool(false));

        bytes memory apiData = _swapApi(tokenA, tokenB, 1 ether, 1 ether, true);
        TreasuryManager.SignatureData memory sig = _sign(apiData, destWalletAddress);
        vm.prank(caller);
        vm.expectRevert(TreasuryManager.TokenToNotAllowed.selector);
        treasury.swap(sig, _dummyDelegations());
    }

    function test_revert_swap_PairDisabled() public {
        vm.prank(owner);
        treasury.setPairLimits(_pairLimits(tokenA, tokenB, false));

        bytes memory apiData = _swapApi(tokenA, tokenB, 1 ether, 1 ether, true);
        TreasuryManager.SignatureData memory sig = _sign(apiData, destWalletAddress);
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(TreasuryManager.PairDisabled.selector, IERC20(address(tokenA)), IERC20(address(tokenB)))
        );
        treasury.swap(sig, _dummyDelegations());
    }

    function test_revert_swap_SlippageExceedsCap() public {
        vm.prank(owner);
        TreasuryManager.PairLimitInput[] memory pin = new TreasuryManager.PairLimitInput[](1);
        pin[0] = TreasuryManager.PairLimitInput({
            tokenFrom: IERC20(address(tokenA)),
            tokenTo: IERC20(address(tokenB)),
            limit: TreasuryManager.PairLimit({ maxSlippage: 1, maxPriceImpact: uint120(100e18), enabled: true })
        });
        treasury.setPairLimits(pin);

        bytes memory apiData = _swapApi(tokenA, tokenB, 1 ether, 1 ether, true);
        TreasuryManager.SignatureData memory sig =
            _signWith(apiData, destWalletAddress, block.timestamp + 1 days, int120(2), int120(0), signerPk);
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(
                TreasuryManager.SlippageExceedsCap.selector, IERC20(address(tokenA)), IERC20(address(tokenB)), int256(2), uint256(1)
            )
        );
        treasury.swap(sig, _dummyDelegations());
    }

    function test_revert_swap_PriceImpactExceedsCap() public {
        vm.prank(owner);
        TreasuryManager.PairLimitInput[] memory pin = new TreasuryManager.PairLimitInput[](1);
        pin[0] = TreasuryManager.PairLimitInput({
            tokenFrom: IERC20(address(tokenA)),
            tokenTo: IERC20(address(tokenB)),
            limit: TreasuryManager.PairLimit({ maxSlippage: uint120(100e18), maxPriceImpact: 1, enabled: true })
        });
        treasury.setPairLimits(pin);

        bytes memory apiData = _swapApi(tokenA, tokenB, 1 ether, 1 ether, true);
        TreasuryManager.SignatureData memory sig =
            _signWith(apiData, destWalletAddress, block.timestamp + 1 days, int120(0), int120(2), signerPk);
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(
                TreasuryManager.PriceImpactExceedsCap.selector,
                IERC20(address(tokenA)),
                IERC20(address(tokenB)),
                int256(2),
                uint256(1)
            )
        );
        treasury.swap(sig, _dummyDelegations());
    }

    function test_revert_swap_InvalidSwapFunctionSelector() public {
        bytes memory apiData = abi.encodeWithSelector(bytes4(0xdeadbeef), "agg", IERC20(address(tokenA)), uint256(1), bytes(""));
        TreasuryManager.SignatureData memory sig = _sign(apiData, destWalletAddress);
        vm.prank(caller);
        vm.expectRevert(TreasuryCalldataDecoder.InvalidSwapFunctionSelector.selector);
        treasury.swap(sig, _dummyDelegations());
    }

    function test_revert_swap_TokenFromMismatch() public {
        // outer tokenFrom = tokenA, inner tokenFrom = tokenB → mismatch
        bytes memory swapData = abi.encode(tokenB, tokenB, uint256(1 ether), uint256(1 ether), hex"", uint256(0), address(0), true);
        bytes memory apiData =
            abi.encodeWithSelector(IMetaSwap.swap.selector, "agg", IERC20(address(tokenA)), uint256(1 ether), swapData);
        TreasuryManager.SignatureData memory sig = _sign(apiData, destWalletAddress);
        vm.prank(caller);
        vm.expectRevert(TreasuryCalldataDecoder.TokenFromMismatch.selector);
        treasury.swap(sig, _dummyDelegations());
    }

    function test_revert_swap_AmountFromMismatch() public {
        // feeTo=false, fee=1, inner.amountFrom=1 ether, outer=2 ether → 1+1ether ≠ 2 ether
        bytes memory swapData = abi.encode(tokenA, tokenB, uint256(1 ether), uint256(1 ether), hex"", uint256(1), address(0), false);
        bytes memory apiData =
            abi.encodeWithSelector(IMetaSwap.swap.selector, "agg", IERC20(address(tokenA)), uint256(2 ether), swapData);
        TreasuryManager.SignatureData memory sig = _sign(apiData, destWalletAddress);
        vm.prank(caller);
        vm.expectRevert(TreasuryCalldataDecoder.AmountFromMismatch.selector);
        treasury.swap(sig, _dummyDelegations());
    }

    /////////////////////// bridge ///////////////////////

    function test_bridge_happy() public {
        uint256 amt = 1 ether;
        delegationManager.setPull(IERC20(address(tokenA)), amt, pullFrom);
        _allowBridge(DEST_CHAIN, address(tokenB));

        bytes memory tail = _bridgeTail(DEST_CHAIN, address(tokenA), address(tokenB), amt, 0);
        bytes memory apiData = _bridgeApi(address(tokenA), amt, tail);
        TreasuryManager.SignatureData memory sig = _sign(apiData, destWalletAddress);

        vm.expectEmit(true, true, true, true, address(treasury));
        emit TreasuryManager.BridgeInitiated(caller, IERC20(address(tokenA)), DEST_CHAIN, destWalletAddress, address(tokenB), amt);
        vm.prank(caller);
        treasury.bridge(sig, _dummyDelegations());
        assertEq(tokenA.balanceOf(address(metaBridge)), amt);
    }

    function test_revert_bridge_InvalidEmptyDelegations() public {
        bytes memory tail = _bridgeTail(DEST_CHAIN, address(tokenA), address(tokenB), 1 ether, 0);
        bytes memory apiData = _bridgeApi(address(tokenA), 1 ether, tail);
        TreasuryManager.SignatureData memory sig = _sign(apiData, destWalletAddress);
        vm.prank(caller);
        vm.expectRevert(TreasuryManager.InvalidEmptyDelegations.selector);
        treasury.bridge(sig, new Delegation[](0));
    }

    function test_revert_bridge_DestinationChainNotAllowed() public {
        uint256 amt = 1 ether;
        bytes memory tail = _bridgeTail(DEST_CHAIN, address(tokenA), address(tokenB), amt, 0);
        bytes memory apiData = _bridgeApi(address(tokenA), amt, tail);
        TreasuryManager.SignatureData memory sig = _sign(apiData, destWalletAddress);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(TreasuryManager.DestinationChainNotAllowed.selector, DEST_CHAIN));
        treasury.bridge(sig, _dummyDelegations());
    }

    function test_revert_bridge_BridgeDestinationNotAllowed() public {
        uint256 amt = 1 ether;
        // Allow the chain but NOT the destination wallet for that chain.
        uint256[] memory chains = new uint256[](1);
        chains[0] = DEST_CHAIN;
        vm.prank(owner);
        treasury.updateDestinationChains(chains, _singleBool(true));

        bytes memory tail = _bridgeTail(DEST_CHAIN, address(tokenA), address(tokenB), amt, 0);
        bytes memory apiData = _bridgeApi(address(tokenA), amt, tail);
        TreasuryManager.SignatureData memory sig = _sign(apiData, destWalletAddress);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(TreasuryManager.BridgeDestinationNotAllowed.selector, DEST_CHAIN, destWalletAddress));
        treasury.bridge(sig, _dummyDelegations());
    }

    function test_revert_bridge_BridgeTokenToNotAllowed() public {
        uint256 amt = 1 ether;
        // Allow chain + dest wallet, but NOT the token.
        uint256[] memory chains = new uint256[](1);
        chains[0] = DEST_CHAIN;
        vm.startPrank(owner);
        treasury.updateDestinationChains(chains, _singleBool(true));
        treasury.updateAllowedBridgeDestinations(DEST_CHAIN, _singleAddr(destWalletAddress), _singleBool(true));
        vm.stopPrank();

        bytes memory tail = _bridgeTail(DEST_CHAIN, address(tokenA), address(tokenB), amt, 0);
        bytes memory apiData = _bridgeApi(address(tokenA), amt, tail);
        TreasuryManager.SignatureData memory sig = _sign(apiData, destWalletAddress);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(TreasuryManager.BridgeTokenToNotAllowed.selector, DEST_CHAIN, address(tokenB)));
        treasury.bridge(sig, _dummyDelegations());
    }

    function test_revert_bridge_DestinationWalletNotAllowed() public {
        bytes memory tail = _bridgeTail(DEST_CHAIN, address(tokenA), address(tokenB), 1 ether, 0);
        bytes memory apiData = _bridgeApi(address(tokenA), 1 ether, tail);
        address other = makeAddr("notAllowedDest");
        TreasuryManager.SignatureData memory sig = _sign(apiData, other);
        vm.prank(caller);
        vm.expectRevert(TreasuryManager.DestinationWalletNotAllowed.selector);
        treasury.bridge(sig, _dummyDelegations());
    }

    function test_revert_bridge_InvalidBridgeFunctionSelector() public {
        bytes memory apiData = abi.encodeWithSelector(bytes4(0xdeadbeef), "relay", address(tokenA), uint256(1), bytes(""));
        TreasuryManager.SignatureData memory sig = _sign(apiData, destWalletAddress);
        vm.prank(caller);
        vm.expectRevert(TreasuryCalldataDecoder.InvalidBridgeFunctionSelector.selector);
        treasury.bridge(sig, _dummyDelegations());
    }

    function test_revert_bridge_TokenFromMismatch() public {
        // outer tokenFrom = tokenA, inner tokenFrom = tokenB → mismatch
        bytes memory tail = _bridgeTail(DEST_CHAIN, address(tokenB), address(tokenB), 1 ether, 0);
        bytes memory apiData = _bridgeApi(address(tokenA), 1 ether, tail);
        TreasuryManager.SignatureData memory sig = _sign(apiData, destWalletAddress);
        vm.prank(caller);
        vm.expectRevert(TreasuryCalldataDecoder.TokenFromMismatch.selector);
        treasury.bridge(sig, _dummyDelegations());
    }

    function test_revert_bridge_AmountFromMismatch() public {
        // inner amountFrom + fee = 1 + 1 = 2; outer = 3 → mismatch
        bytes memory tail = _bridgeTail(DEST_CHAIN, address(tokenA), address(tokenB), 1, 1);
        bytes memory apiData = _bridgeApi(address(tokenA), 3, tail);
        TreasuryManager.SignatureData memory sig = _sign(apiData, destWalletAddress);
        vm.prank(caller);
        vm.expectRevert(TreasuryCalldataDecoder.AmountFromMismatch.selector);
        treasury.bridge(sig, _dummyDelegations());
    }

    function test_bridge_nativeInput_happy() public {
        // Native ETH bridge: treasury pulls ETH, forwards via `value:` to metaBridge, balance check passes because
        // `value:` itself drains treasury by `amt` regardless of metaBridge internals.
        uint256 amt = 1 ether;
        delegationManager.setPull(IERC20(address(0)), amt, address(0));
        vm.deal(address(delegationManager), amt);
        _allowBridge(DEST_CHAIN, address(tokenB));

        bytes memory tail = _bridgeTail(DEST_CHAIN, address(0), address(tokenB), amt, 0);
        bytes memory apiData = _bridgeApi(address(0), amt, tail);
        TreasuryManager.SignatureData memory sig = _sign(apiData, destWalletAddress);

        uint256 metaBridgeEthBefore = address(metaBridge).balance;

        vm.prank(caller);
        treasury.bridge(sig, _dummyDelegations());

        assertEq(address(metaBridge).balance - metaBridgeEthBefore, amt, "metaBridge receives the native ETH");
    }

    function test_bridge_stETHInput_appliesTolerance() public {
        // stETH-as-bridge-input: redemption short by 1 wei; topup applied; metaBridge pulls full `amt`.
        uint256 amt = 1 ether;
        delegationManager.setPull(IERC20(address(stEth)), amt, pullFrom);
        stEth.setShortBy(1);
        _allowBridge(DEST_CHAIN, address(tokenB));

        bytes memory tail = _bridgeTail(DEST_CHAIN, address(stEth), address(tokenB), amt, 0);
        bytes memory apiData = _bridgeApi(address(stEth), amt, tail);
        TreasuryManager.SignatureData memory sig = _sign(apiData, destWalletAddress);

        uint256 prefundBefore = stEth.balanceOf(address(treasury));
        uint256 metaBridgeBefore = stEth.balanceOf(address(metaBridge));

        vm.prank(caller);
        treasury.bridge(sig, _dummyDelegations());

        // Treasury net stETH change: +(amt - 1) [redeem] - amt [metaBridge.transferFrom] = -1 wei.
        assertEq(prefundBefore - stEth.balanceOf(address(treasury)), 1, "prefund covers 1 wei");
        // metaBridge sees the rounding loss on its receive side: amt - 1.
        assertEq(stEth.balanceOf(address(metaBridge)) - metaBridgeBefore, amt - 1, "metaBridge receives amt - 1 stETH");
    }

    function test_revert_bridge_BridgeSourceNotConsumed() public {
        // metaBridge returns success without pulling source tokens; treasury catches the no-op.
        uint256 amt = 1 ether;
        delegationManager.setPull(IERC20(address(tokenA)), amt, pullFrom);
        _allowBridge(DEST_CHAIN, address(tokenB));
        metaBridge.setNoOp(true);

        bytes memory tail = _bridgeTail(DEST_CHAIN, address(tokenA), address(tokenB), amt, 0);
        bytes memory apiData = _bridgeApi(address(tokenA), amt, tail);
        TreasuryManager.SignatureData memory sig = _sign(apiData, destWalletAddress);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(TreasuryManager.BridgeSourceNotConsumed.selector, amt, 0));
        treasury.bridge(sig, _dummyDelegations());
    }

    /////////////////////// stETH share-rounding tolerance ///////////////////////

    function test_transfer_stETH_exact_noPrefundDraw() public {
        // No share-rounding loss; prefund balance must remain untouched.
        uint256 amt = 5 ether;
        delegationManager.setPull(IERC20(address(stEth)), amt, pullFrom);

        uint256 prefundBefore = stEth.balanceOf(address(treasury));
        uint256 destBefore = stEth.balanceOf(destWalletAddress);

        vm.prank(caller);
        treasury.transfer(_dummyDelegations(), IERC20(address(stEth)), amt, destWalletAddress);

        assertEq(stEth.balanceOf(destWalletAddress) - destBefore, amt, "dest receives full amount");
        assertEq(stEth.balanceOf(address(treasury)), prefundBefore, "prefund untouched");
    }

    function test_transfer_stETH_shortBy1_drawsFromPrefund() public {
        uint256 amt = 5 ether;
        delegationManager.setPull(IERC20(address(stEth)), amt, pullFrom);
        stEth.setShortBy(1);

        uint256 prefundBefore = stEth.balanceOf(address(treasury));
        uint256 destBefore = stEth.balanceOf(destWalletAddress);

        vm.expectEmit(false, false, false, true, address(treasury));
        emit TreasuryManager.StEthShortfallCovered(1);
        vm.prank(caller);
        treasury.transfer(_dummyDelegations(), IERC20(address(stEth)), amt, destWalletAddress);

        // The downstream `_sendTokens` debits treasury by full `amt`. Treasury net change after both hops:
        // +(amt - 1) [pull] - amt [send] = -1 wei. Prefund covers exactly the redemption shortfall.
        assertEq(stEth.balanceOf(destWalletAddress) - destBefore, amt - 1, "dest receives amt - 1 (mock send-hop loses 1)");
        assertEq(prefundBefore - stEth.balanceOf(address(treasury)), 1, "prefund covers the 1-wei redemption shortfall");
    }

    function test_transfer_stETH_shortBy10_drawsFromPrefund() public {
        // Tolerance is 10 wei; shortfall at the boundary still passes and draws 10 wei from prefund.
        uint256 amt = 5 ether;
        delegationManager.setPull(IERC20(address(stEth)), amt, pullFrom);
        stEth.setShortBy(10);

        uint256 prefundBefore = stEth.balanceOf(address(treasury));

        vm.prank(caller);
        treasury.transfer(_dummyDelegations(), IERC20(address(stEth)), amt, destWalletAddress);

        assertEq(prefundBefore - stEth.balanceOf(address(treasury)), 10, "prefund covers 10-wei redemption shortfall");
    }

    function test_revert_transfer_stETH_shortBy11_exceedsTolerance() public {
        uint256 amt = 5 ether;
        delegationManager.setPull(IERC20(address(stEth)), amt, pullFrom);
        stEth.setShortBy(11);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(TreasuryManager.UnexpectedTokenFromAmount.selector, amt, amt - 11));
        treasury.transfer(_dummyDelegations(), IERC20(address(stEth)), amt, destWalletAddress);
    }

    function test_revert_transfer_stETH_overCredit() public {
        // Even on stETH (where shortfalls within tolerance are accepted), an over-credit must still revert.
        // Exercises the `_obtained >= _amount` short-circuit in `_isWithinStEthTolerance`.
        uint256 amt = 5 ether;
        delegationManager.setPull(IERC20(address(stEth)), amt, pullFrom);
        delegationManager.setPullExtra(1);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(TreasuryManager.UnexpectedTokenFromAmount.selector, amt, amt + 1));
        treasury.transfer(_dummyDelegations(), IERC20(address(stEth)), amt, destWalletAddress);
    }

    function test_revert_transfer_stETH_insufficientPrefund() public {
        // Drain the treasury's stETH prefund first via withdraw; shortfall then has nothing to draw from.
        vm.prank(owner);
        treasury.withdraw(IERC20(address(stEth)), STETH_PREFUND, owner);
        assertEq(stEth.balanceOf(address(treasury)), 0);

        uint256 amt = 5 ether;
        delegationManager.setPull(IERC20(address(stEth)), amt, pullFrom);
        stEth.setShortBy(2);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(TreasuryManager.InsufficientStEthPrefund.selector, 2, 0));
        treasury.transfer(_dummyDelegations(), IERC20(address(stEth)), amt, destWalletAddress);
    }

    function test_transfer_stETH_toleranceDisabledWhenStEthZero() public {
        // Non-mainnet deployment with stEth=address(0) must NOT apply tolerance even if the token used happens
        // to be the same contract address (it's not configured as the canonical stEth).
        TreasuryManager nonMainnet =
            new TreasuryManager(owner, apiSigner, delegationManager, metaSwap, metaBridge, IERC20(address(weth)), address(0));
        vm.startPrank(owner);
        nonMainnet.updateAllowedCallers(_singleAddr(caller), _singleBool(true));
        nonMainnet.updateAllowedDestWallets(_singleAddr(destWalletAddress), _singleBool(true));
        stEth.mint(address(nonMainnet), STETH_PREFUND);
        vm.stopPrank();

        uint256 amt = 5 ether;
        delegationManager.setPull(IERC20(address(stEth)), amt, pullFrom);
        stEth.setShortBy(1);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(TreasuryManager.UnexpectedTokenFromAmount.selector, amt, amt - 1));
        nonMainnet.transfer(_dummyDelegations(), IERC20(address(stEth)), amt, destWalletAddress);
    }

    function test_multichain_normalFlowsUnaffectedByZeroStEth() public {
        // Smoke test: deploy on a non-Lido chain (stEth = address(0)) and confirm the standard transfer + swap +
        // bridge flows for a normal ERC-20 still work. Proves the stEth feature is fully orthogonal to everything
        // else; nothing about the multichain config gates non-stETH flows.
        TreasuryManager nonMainnet =
            new TreasuryManager(owner, apiSigner, delegationManager, metaSwap, metaBridge, IERC20(address(weth)), address(0));
        vm.startPrank(owner);
        nonMainnet.updateAllowedCallers(_singleAddr(caller), _singleBool(true));
        nonMainnet.updateAllowedDestWallets(_singleAddr(destWalletAddress), _singleBool(true));
        nonMainnet.updateAllowedTokensTo(_singleTok(tokenB), _singleBool(true));
        nonMainnet.setPairLimits(_pairLimits(tokenA, tokenB, true));
        uint256[] memory chains = new uint256[](1);
        chains[0] = DEST_CHAIN;
        nonMainnet.updateDestinationChains(chains, _singleBool(true));
        nonMainnet.updateAllowedBridgeDestinations(DEST_CHAIN, _singleAddr(destWalletAddress), _singleBool(true));
        nonMainnet.updateAllowedBridgeTokensTo(DEST_CHAIN, _singleAddr(address(tokenB)), _singleBool(true));
        vm.stopPrank();

        // Phase 1: transfer
        uint256 amt = 1 ether;
        delegationManager.setPull(IERC20(address(tokenA)), amt, pullFrom);
        uint256 destBefore = tokenA.balanceOf(destWalletAddress);
        vm.prank(caller);
        nonMainnet.transfer(_dummyDelegations(), IERC20(address(tokenA)), amt, destWalletAddress);
        assertEq(tokenA.balanceOf(destWalletAddress) - destBefore, amt, "transfer ok on non-mainnet config");

        // Phase 2: swap
        delegationManager.setPull(IERC20(address(tokenA)), amt, pullFrom);
        bytes memory swapApiData = _swapApi(tokenA, tokenB, amt, amt, true);
        TreasuryManager.SignatureData memory swapSig = _sign(swapApiData, destWalletAddress);
        uint256 destBeforeB = tokenB.balanceOf(destWalletAddress);
        vm.prank(caller);
        nonMainnet.swap(swapSig, _dummyDelegations());
        assertEq(tokenB.balanceOf(destWalletAddress) - destBeforeB, amt, "swap ok on non-mainnet config");

        // Phase 3: bridge
        delegationManager.setPull(IERC20(address(tokenA)), amt, pullFrom);
        bytes memory tail = _bridgeTail(DEST_CHAIN, address(tokenA), address(tokenB), amt, 0);
        bytes memory bridgeApiData = _bridgeApi(address(tokenA), amt, tail);
        TreasuryManager.SignatureData memory bridgeSig = _sign(bridgeApiData, destWalletAddress);
        uint256 metaBridgeBefore = tokenA.balanceOf(address(metaBridge));
        vm.prank(caller);
        nonMainnet.bridge(bridgeSig, _dummyDelegations());
        assertEq(tokenA.balanceOf(address(metaBridge)) - metaBridgeBefore, amt, "bridge ok on non-mainnet config");
    }

    /////////////////////// setPairLimits ///////////////////////

    function test_setPairLimits_emitsAndStores() public {
        vm.prank(owner);
        vm.expectEmit(true, true, false, true, address(treasury));
        emit TreasuryManager.PairLimitSet(IERC20(address(tokenA)), IERC20(address(tokenB)), uint120(1e18), uint120(2e18), true);
        TreasuryManager.PairLimitInput[] memory pin = new TreasuryManager.PairLimitInput[](1);
        pin[0] = TreasuryManager.PairLimitInput({
            tokenFrom: IERC20(address(tokenA)),
            tokenTo: IERC20(address(tokenB)),
            limit: TreasuryManager.PairLimit({ maxSlippage: uint120(1e18), maxPriceImpact: uint120(2e18), enabled: true })
        });
        treasury.setPairLimits(pin);

        TreasuryManager.PairLimit memory got = treasury.getPairLimit(IERC20(address(tokenA)), IERC20(address(tokenB)));
        assertEq(uint256(got.maxSlippage), 1e18);
        assertEq(uint256(got.maxPriceImpact), 2e18);
        assertTrue(got.enabled);
    }

    function test_setPairLimits_canonicalizesWeth() public {
        // Set with WETH on the input side; getPairLimit with address(0) should resolve to the same entry.
        vm.prank(owner);
        TreasuryManager.PairLimitInput[] memory pin = new TreasuryManager.PairLimitInput[](1);
        pin[0] = TreasuryManager.PairLimitInput({
            tokenFrom: IERC20(address(weth)),
            tokenTo: IERC20(address(tokenB)),
            limit: TreasuryManager.PairLimit({ maxSlippage: uint120(5e18), maxPriceImpact: uint120(6e18), enabled: true })
        });
        treasury.setPairLimits(pin);

        TreasuryManager.PairLimit memory viaNative = treasury.getPairLimit(IERC20(address(0)), IERC20(address(tokenB)));
        assertEq(uint256(viaNative.maxSlippage), 5e18);
        assertEq(uint256(viaNative.maxPriceImpact), 6e18);
        assertTrue(viaNative.enabled);
    }

    function test_revert_setPairLimits_InvalidIdenticalTokens() public {
        vm.prank(owner);
        TreasuryManager.PairLimitInput[] memory pin = new TreasuryManager.PairLimitInput[](1);
        pin[0] = TreasuryManager.PairLimitInput({
            tokenFrom: IERC20(address(tokenA)),
            tokenTo: IERC20(address(tokenA)),
            limit: TreasuryManager.PairLimit({ maxSlippage: 0, maxPriceImpact: 0, enabled: true })
        });
        vm.expectRevert(TreasuryManager.InvalidIdenticalTokens.selector);
        treasury.setPairLimits(pin);
    }

    function test_revert_setPairLimits_InvalidPercent_slippage() public {
        vm.prank(owner);
        TreasuryManager.PairLimitInput[] memory pin = new TreasuryManager.PairLimitInput[](1);
        uint120 over = uint120(100e18 + 1);
        pin[0] = TreasuryManager.PairLimitInput({
            tokenFrom: IERC20(address(tokenA)),
            tokenTo: IERC20(address(tokenB)),
            limit: TreasuryManager.PairLimit({ maxSlippage: over, maxPriceImpact: 0, enabled: true })
        });
        vm.expectRevert(abi.encodeWithSelector(TreasuryManager.InvalidPercent.selector, uint256(over)));
        treasury.setPairLimits(pin);
    }

    function test_revert_setPairLimits_InvalidPercent_priceImpact() public {
        vm.prank(owner);
        TreasuryManager.PairLimitInput[] memory pin = new TreasuryManager.PairLimitInput[](1);
        uint120 over = uint120(100e18 + 1);
        pin[0] = TreasuryManager.PairLimitInput({
            tokenFrom: IERC20(address(tokenA)),
            tokenTo: IERC20(address(tokenB)),
            limit: TreasuryManager.PairLimit({ maxSlippage: 0, maxPriceImpact: over, enabled: true })
        });
        vm.expectRevert(abi.encodeWithSelector(TreasuryManager.InvalidPercent.selector, uint256(over)));
        treasury.setPairLimits(pin);
    }

    function test_revert_setPairLimits_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        treasury.setPairLimits(new TreasuryManager.PairLimitInput[](0));
    }

    /////////////////////// getPairLimit ///////////////////////

    function test_getPairLimit_unsetReturnsZeroAndCanonicalizesWeth() public {
        // Two things in one read: WETH on the input side canonicalizes to address(0) (so the lookup hits the
        // (address(0), tokenA) pair which was never configured), and an unset pair returns the zeroed struct.
        TreasuryManager.PairLimit memory got = treasury.getPairLimit(IERC20(address(weth)), IERC20(address(tokenA)));
        assertEq(uint256(got.maxSlippage), 0);
        assertEq(uint256(got.maxPriceImpact), 0);
        assertFalse(got.enabled);
    }

    /////////////////////// allowlist updaters ///////////////////////

    function test_updateAllowedCallers_noOpDoesNotEmit() public {
        // First call sets caller=true (already true from setUp), should be no-op.
        vm.recordLogs();
        vm.prank(owner);
        treasury.updateAllowedCallers(_singleAddr(caller), _singleBool(true));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0);
    }

    function test_updateAllowedCallers_emits() public {
        address newCaller = makeAddr("newCaller");
        vm.prank(owner);
        vm.expectEmit(true, false, false, true, address(treasury));
        emit TreasuryManager.ChangedCallerStatus(newCaller, true);
        treasury.updateAllowedCallers(_singleAddr(newCaller), _singleBool(true));
        assertTrue(treasury.isCallerAllowed(newCaller));
    }

    function test_revert_updateAllowedCallers_InputLengthsMismatch() public {
        vm.prank(owner);
        vm.expectRevert(TreasuryManager.InputLengthsMismatch.selector);
        treasury.updateAllowedCallers(_singleAddr(caller), new bool[](2));
    }

    function test_revert_updateAllowedCallers_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        treasury.updateAllowedCallers(_singleAddr(caller), _singleBool(true));
    }

    function test_updateAllowedDestWallets_emits() public {
        address newDest = makeAddr("newDest");
        vm.prank(owner);
        vm.expectEmit(true, false, false, true, address(treasury));
        emit TreasuryManager.ChangedDestWalletStatus(newDest, true);
        treasury.updateAllowedDestWallets(_singleAddr(newDest), _singleBool(true));
        assertTrue(treasury.isDestWalletAllowed(newDest));
    }

    function test_revert_updateAllowedDestWallets_InputLengthsMismatch() public {
        vm.prank(owner);
        vm.expectRevert(TreasuryManager.InputLengthsMismatch.selector);
        treasury.updateAllowedDestWallets(_singleAddr(destWalletAddress), new bool[](0));
    }

    function test_updateAllowedTokensTo_canonicalizesWeth() public {
        // Set via WETH; canonical key is address(0); should be readable as native. Emitted key is native, not WETH.
        vm.prank(owner);
        vm.expectEmit(true, true, false, false, address(treasury));
        emit TreasuryManager.ChangedTokenToStatus(IERC20(address(0)), true);
        treasury.updateAllowedTokensTo(_singleTok(IERC20(address(weth))), _singleBool(true));
        assertTrue(treasury.isTokenToAllowed(IERC20(address(0))));
    }

    function test_revert_updateAllowedTokensTo_InputLengthsMismatch() public {
        vm.prank(owner);
        vm.expectRevert(TreasuryManager.InputLengthsMismatch.selector);
        treasury.updateAllowedTokensTo(_singleTok(tokenB), new bool[](0));
    }

    function test_updateAllowedBridgeDestinations_emits() public {
        vm.prank(owner);
        vm.expectEmit(true, true, false, true, address(treasury));
        emit TreasuryManager.ChangedBridgeDestinationStatus(DEST_CHAIN, destWalletAddress, true);
        treasury.updateAllowedBridgeDestinations(DEST_CHAIN, _singleAddr(destWalletAddress), _singleBool(true));
        assertTrue(treasury.allowedBridgeDestination(DEST_CHAIN, destWalletAddress));
    }

    function test_revert_updateAllowedBridgeDestinations_InputLengthsMismatch() public {
        vm.prank(owner);
        vm.expectRevert(TreasuryManager.InputLengthsMismatch.selector);
        treasury.updateAllowedBridgeDestinations(DEST_CHAIN, _singleAddr(destWalletAddress), new bool[](0));
    }

    function test_updateAllowedBridgeTokensTo_emits() public {
        vm.prank(owner);
        vm.expectEmit(true, true, false, true, address(treasury));
        emit TreasuryManager.ChangedBridgeTokenToStatus(DEST_CHAIN, address(tokenB), true);
        treasury.updateAllowedBridgeTokensTo(DEST_CHAIN, _singleAddr(address(tokenB)), _singleBool(true));
        assertTrue(treasury.isBridgeTokenToAllowed(DEST_CHAIN, address(tokenB)));
    }

    function test_revert_updateAllowedBridgeTokensTo_InputLengthsMismatch() public {
        vm.prank(owner);
        vm.expectRevert(TreasuryManager.InputLengthsMismatch.selector);
        treasury.updateAllowedBridgeTokensTo(DEST_CHAIN, _singleAddr(address(tokenB)), new bool[](0));
    }

    function test_updateDestinationChains_emits() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true, address(treasury));
        emit TreasuryManager.ChangedDestinationChainStatus(DEST_CHAIN, true);
        uint256[] memory chains = new uint256[](1);
        chains[0] = DEST_CHAIN;
        treasury.updateDestinationChains(chains, _singleBool(true));
        assertTrue(treasury.isDestinationChainAllowed(DEST_CHAIN));
    }

    function test_revert_updateDestinationChains_InputLengthsMismatch() public {
        vm.prank(owner);
        vm.expectRevert(TreasuryManager.InputLengthsMismatch.selector);
        uint256[] memory chains = new uint256[](1);
        chains[0] = DEST_CHAIN;
        treasury.updateDestinationChains(chains, new bool[](0));
    }

    /////////////////////// withdraw ///////////////////////

    function test_withdraw_erc20() public {
        vm.prank(owner);
        tokenA.mint(address(treasury), 5 ether);
        uint256 balBefore = tokenA.balanceOf(stranger);
        vm.prank(owner);
        treasury.withdraw(IERC20(address(tokenA)), 5 ether, stranger);
        assertEq(tokenA.balanceOf(stranger) - balBefore, 5 ether);
    }

    function test_withdraw_native() public {
        vm.deal(address(treasury), 2 ether);
        uint256 balBefore = stranger.balance;
        vm.prank(owner);
        treasury.withdraw(IERC20(address(0)), 2 ether, stranger);
        assertEq(stranger.balance - balBefore, 2 ether);
    }

    function test_revert_withdraw_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        treasury.withdraw(IERC20(address(tokenA)), 1, stranger);
    }

    /////////////////////// helpers ///////////////////////

    function _allowBridge(uint256 chainId, address destToken) internal {
        uint256[] memory chains = new uint256[](1);
        chains[0] = chainId;
        vm.startPrank(owner);
        treasury.updateDestinationChains(chains, _singleBool(true));
        treasury.updateAllowedBridgeDestinations(chainId, _singleAddr(destWalletAddress), _singleBool(true));
        treasury.updateAllowedBridgeTokensTo(chainId, _singleAddr(destToken), _singleBool(true));
        vm.stopPrank();
    }

    function _swapApi(
        IERC20 tFrom,
        IERC20 tTo,
        uint256 outerAmount,
        uint256 innerAmount,
        bool feeTo
    )
        internal
        pure
        returns (bytes memory)
    {
        bytes memory swapData = abi.encode(tFrom, tTo, innerAmount, innerAmount, hex"", uint256(0), address(0), feeTo);
        return abi.encodeWithSelector(IMetaSwap.swap.selector, "agg", tFrom, outerAmount, swapData);
    }

    function _bridgeTail(
        uint256 chainId,
        address tokenFrom,
        address tokenTo,
        uint256 innerAmount,
        uint256 fee
    )
        internal
        pure
        returns (bytes memory)
    {
        // Tail layout (after the prepended `address(0)` destWalletAddress placeholder):
        // (aggregator, spender, destinationChainId, tokenFrom, tokenTo, amountFrom, aggregatorCalldata, fee, feeWallet)
        return abi.encode(address(0xA1), address(0xA2), chainId, tokenFrom, tokenTo, innerAmount, bytes(""), fee, address(0));
    }

    function _bridgeApi(address tokenFromOuter, uint256 outerAmount, bytes memory tail) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IMetaBridge.bridge.selector, "relay", tokenFromOuter, outerAmount, tail);
    }

    function _sign(bytes memory apiData, address destWalletAddress_) internal view returns (TreasuryManager.SignatureData memory) {
        return _signWith(
            apiData, destWalletAddress_, block.timestamp + 1 days, int120(int256(SLIPPAGE)), int120(int256(PRICE_IMPACT)), signerPk
        );
    }

    function _signWith(
        bytes memory apiData,
        address destWalletAddress_,
        uint256 expiration,
        int120 slippage,
        int120 priceImpact,
        uint256 signerKey
    )
        internal
        pure
        returns (TreasuryManager.SignatureData memory)
    {
        bytes32 messageHash = keccak256(abi.encode(apiData, expiration, slippage, priceImpact, destWalletAddress_));
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, ethSignedMessageHash);
        return TreasuryManager.SignatureData({
            apiData: apiData,
            expiration: expiration,
            slippage: slippage,
            priceImpact: priceImpact,
            destWalletAddress: destWalletAddress_,
            signature: abi.encodePacked(r, s, v)
        });
    }

    function _dummyDelegations() internal pure returns (Delegation[] memory d) {
        d = new Delegation[](1);
        d[0] = Delegation({
            delegate: address(0), delegator: address(0), authority: bytes32(0), caveats: new Caveat[](0), salt: 0, signature: ""
        });
    }

    function _singleAddr(address a) internal pure returns (address[] memory o) {
        o = new address[](1);
        o[0] = a;
    }

    function _singleBool(bool b) internal pure returns (bool[] memory o) {
        o = new bool[](1);
        o[0] = b;
    }

    function _singleTok(IERC20 t) internal pure returns (IERC20[] memory o) {
        o = new IERC20[](1);
        o[0] = t;
    }

    function _pairLimits(IERC20 a, IERC20 b, bool enabled) internal pure returns (TreasuryManager.PairLimitInput[] memory pin) {
        pin = new TreasuryManager.PairLimitInput[](1);
        pin[0] = TreasuryManager.PairLimitInput({
            tokenFrom: a,
            tokenTo: b,
            limit: TreasuryManager.PairLimit({ maxSlippage: uint120(100e18), maxPriceImpact: uint120(100e18), enabled: enabled })
        });
    }
}
