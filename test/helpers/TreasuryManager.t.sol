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
import { IWstETH } from "../../src/helpers/interfaces/IWstETH.sol";
import { Caveat, Delegation, ModeCode } from "../../src/utils/Types.sol";

contract MockDelegationManager is IDelegationManager {
    using SafeERC20 for IERC20;

    IERC20 public pullToken;
    uint256 public pullAmount;
    address public pullFrom;
    /// @dev Force the redeem step to short the recipient by `pullShortBy` (used to test UnexpectedTokenFromAmount).
    uint256 public pullShortBy;

    function setPull(IERC20 t, uint256 a, address f) external {
        pullToken = t;
        pullAmount = a;
        pullFrom = f;
        pullShortBy = 0;
    }

    function setPullShortBy(uint256 s) external {
        pullShortBy = s;
    }

    function redeemDelegations(bytes[] calldata, ModeCode[] calldata, bytes[] calldata) external override {
        uint256 actual = pullAmount - pullShortBy;
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
        return super.transfer(to, amount - shortBy);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        // Pull the full declared amount from `from` so allowance / balance accounting matches Lido behavior, but only
        // credit `to` with `amount - shortBy` to mimic the share-rounding loss on the receiving side.
        super.transferFrom(from, address(this), shortBy);
        return super.transferFrom(from, to, amount - shortBy);
    }
}

/// @dev Minimal wstETH mock: `wrap(amount)` pulls `amount` stETH from msg.sender and mints the same amount of wstETH.
contract MockWstEth is BasicERC20, IWstETH {
    address public immutable underlying;

    constructor(address _owner, address _stEth) BasicERC20(_owner, "wstETH", "wstETH", 0) {
        underlying = _stEth;
    }

    function wrap(uint256 _stETHAmount) external override returns (uint256) {
        IERC20(underlying).transferFrom(msg.sender, address(this), _stETHAmount);
        _mint(msg.sender, _stETHAmount);
        return _stETHAmount;
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
    MockWstEth internal wstEth;
    TreasuryManager internal treasury;

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
        wstEth = new MockWstEth(owner, address(stEth));
        metaSwap = new MockMetaSwap(tokenB);
        metaBridge = new MockMetaBridge();

        tokenB.mint(address(metaSwap), type(uint128).max);

        treasury = new TreasuryManager(
            owner, apiSigner, delegationManager, metaSwap, metaBridge, IERC20(address(weth)), address(stEth), address(wstEth)
        );

        treasury.updateAllowedCallers(_singleAddr(caller), _singleBool(true));
        treasury.updateAllowedDestWallets(_singleAddr(destWalletAddress), _singleBool(true));
        treasury.updateAllowedTokensTo(_singleTok(tokenB), _singleBool(true));
        treasury.setPairLimits(_pairLimits(tokenA, tokenB, true));
        tokenA.mint(pullFrom, 1_000 ether);
        stEth.mint(pullFrom, 1_000 ether);
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
        assertEq(treasury.wstEth(), address(wstEth));
        assertEq(treasury.apiSigner(), apiSigner);
        assertEq(treasury.owner(), owner);
        assertEq(uint256(treasury.MAX_PERCENT()), 100e18);
    }

    function test_revert_constructor_zeroDelegationManager() public {
        vm.expectRevert(TreasuryManager.InvalidZeroAddress.selector);
        new TreasuryManager(
            owner,
            apiSigner,
            IDelegationManager(address(0)),
            metaSwap,
            metaBridge,
            IERC20(address(weth)),
            address(stEth),
            address(wstEth)
        );
    }

    function test_revert_constructor_zeroMetaSwap() public {
        vm.expectRevert(TreasuryManager.InvalidZeroAddress.selector);
        new TreasuryManager(
            owner,
            apiSigner,
            delegationManager,
            IMetaSwap(address(0)),
            metaBridge,
            IERC20(address(weth)),
            address(stEth),
            address(wstEth)
        );
    }

    function test_revert_constructor_zeroMetaBridge() public {
        vm.expectRevert(TreasuryManager.InvalidZeroAddress.selector);
        new TreasuryManager(
            owner,
            apiSigner,
            delegationManager,
            metaSwap,
            IMetaBridge(address(0)),
            IERC20(address(weth)),
            address(stEth),
            address(wstEth)
        );
    }

    function test_revert_constructor_zeroWeth() public {
        vm.expectRevert(TreasuryManager.InvalidZeroAddress.selector);
        new TreasuryManager(
            owner, apiSigner, delegationManager, metaSwap, metaBridge, IERC20(address(0)), address(stEth), address(wstEth)
        );
    }

    function test_revert_constructor_zeroApiSigner() public {
        vm.expectRevert(TreasuryManager.InvalidZeroAddress.selector);
        new TreasuryManager(
            owner, address(0), delegationManager, metaSwap, metaBridge, IERC20(address(weth)), address(stEth), address(wstEth)
        );
    }

    function test_constructor_acceptsZeroStEthAndWstEth() public {
        // Multichain: deploy on a chain without Lido by passing zero for both stETH addresses.
        TreasuryManager nonMainnet = new TreasuryManager(
            owner, apiSigner, delegationManager, metaSwap, metaBridge, IERC20(address(weth)), address(0), address(0)
        );
        assertEq(nonMainnet.stEth(), address(0));
        assertEq(nonMainnet.wstEth(), address(0));
    }

    /////////////////////// setApiSigner ///////////////////////

    function test_setApiSigner_rotates() public {
        address newSigner = makeAddr("newSigner");
        vm.prank(owner);
        vm.expectEmit(true, false, false, true, address(treasury));
        emit TreasuryManager.ApiSignerUpdated(newSigner);
        treasury.setApiSigner(newSigner);
        assertEq(treasury.apiSigner(), newSigner);
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
        vm.prank(caller);
        treasury.transfer(_dummyDelegations(), IERC20(address(tokenA)), amt, destWalletAddress);
        assertEq(tokenA.balanceOf(destWalletAddress) - balBefore, amt);
    }

    function test_transfer_native() public {
        uint256 amt = 1 ether;
        delegationManager.setPull(IERC20(address(0)), amt, address(0));
        vm.deal(address(delegationManager), amt);

        uint256 balBefore = destWalletAddress.balance;
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
        vm.prank(caller);
        treasury.swap(sig, _dummyDelegations());
        assertEq(tokenB.balanceOf(destWalletAddress) - rBefore, amt);
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

    /////////////////////// wrapStEth ///////////////////////

    function test_wrapStEth_happy() public {
        uint256 amt = 5 ether;
        delegationManager.setPull(IERC20(address(stEth)), amt, pullFrom);

        vm.expectEmit(true, false, false, true, address(treasury));
        emit TreasuryManager.StEthWrapped(destWalletAddress, amt, amt);

        vm.prank(caller);
        treasury.wrapStEth(_dummyDelegations(), amt, destWalletAddress);

        assertEq(wstEth.balanceOf(destWalletAddress), amt, "dest wallet should receive wstETH");
    }

    function test_wrapStEth_toleranceShortBy1Succeeds() public {
        uint256 amt = 5 ether;
        delegationManager.setPull(IERC20(address(stEth)), amt, pullFrom);
        stEth.setShortBy(1);

        vm.prank(caller);
        treasury.wrapStEth(_dummyDelegations(), amt, destWalletAddress);

        // We pulled `amt - 1` of stETH and that's what got wrapped & sent.
        assertEq(wstEth.balanceOf(destWalletAddress), amt - 1, "dest wallet should receive amt - 1 wstETH");
    }

    function test_wrapStEth_toleranceShortBy2Succeeds() public {
        uint256 amt = 5 ether;
        delegationManager.setPull(IERC20(address(stEth)), amt, pullFrom);
        stEth.setShortBy(2);

        vm.prank(caller);
        treasury.wrapStEth(_dummyDelegations(), amt, destWalletAddress);

        assertEq(wstEth.balanceOf(destWalletAddress), amt - 2, "dest wallet should receive amt - 2 wstETH");
    }

    function test_revert_wrapStEth_toleranceExceededShortBy3() public {
        uint256 amt = 5 ether;
        delegationManager.setPull(IERC20(address(stEth)), amt, pullFrom);
        stEth.setShortBy(3);

        // Lower-bound passed to `_redeemTransfer` is `amt - 2`; the revert reports that as the expected.
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(TreasuryManager.UnexpectedTokenFromAmount.selector, amt - 2, amt - 3));
        treasury.wrapStEth(_dummyDelegations(), amt, destWalletAddress);
    }

    function test_revert_wrapStEth_WrappingNotSupported() public {
        // Simulate a non-mainnet deployment where stEth / wstEth are zero.
        TreasuryManager nonMainnet = new TreasuryManager(
            owner, apiSigner, delegationManager, metaSwap, metaBridge, IERC20(address(weth)), address(0), address(0)
        );
        vm.startPrank(owner);
        nonMainnet.updateAllowedCallers(_singleAddr(caller), _singleBool(true));
        nonMainnet.updateAllowedDestWallets(_singleAddr(destWalletAddress), _singleBool(true));
        vm.stopPrank();

        vm.prank(caller);
        vm.expectRevert(TreasuryManager.WrappingNotSupported.selector);
        nonMainnet.wrapStEth(_dummyDelegations(), 1 ether, destWalletAddress);
    }

    function test_revert_wrapStEth_DestinationWalletNotAllowed() public {
        address other = makeAddr("notAllowedDest");
        vm.prank(caller);
        vm.expectRevert(TreasuryManager.DestinationWalletNotAllowed.selector);
        treasury.wrapStEth(_dummyDelegations(), 1 ether, other);
    }

    function test_revert_wrapStEth_CallerNotAllowed() public {
        vm.prank(stranger);
        vm.expectRevert(TreasuryManager.CallerNotAllowed.selector);
        treasury.wrapStEth(_dummyDelegations(), 1 ether, destWalletAddress);
    }

    function test_revert_wrapStEth_InvalidEmptyDelegations() public {
        vm.prank(caller);
        vm.expectRevert(TreasuryManager.InvalidEmptyDelegations.selector);
        treasury.wrapStEth(new Delegation[](0), 1 ether, destWalletAddress);
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

    function test_getPairLimit_returnsZeroIfUnset() public {
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
        // Set via WETH; canonical key is address(0); should be readable as native.
        vm.prank(owner);
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
