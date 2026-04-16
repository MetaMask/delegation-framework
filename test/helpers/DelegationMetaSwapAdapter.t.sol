// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import { BasicERC20 } from "../utils/BasicERC20.t.sol";
import { BaseTest } from "../utils/BaseTest.t.sol";
import { DelegationMetaSwapAdapter } from "../../src/helpers/DelegationMetaSwapAdapter.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";
import { Implementation, SignatureType, TestUser } from "../utils/Types.t.sol";
import { Delegation, Caveat } from "../../src/utils/Types.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";
import { IMetaSwap } from "../../src/helpers/interfaces/IMetaSwap.sol";
import { ERC20PeriodTransferEnforcer } from "../../src/enforcers/ERC20PeriodTransferEnforcer.sol";
import { NativeTokenPeriodTransferEnforcer } from "../../src/enforcers/NativeTokenPeriodTransferEnforcer.sol";
import { RedeemerEnforcer } from "../../src/enforcers/RedeemerEnforcer.sol";
import { BytesLib } from "@bytes-utils/BytesLib.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { DelegationManager } from "../../src/DelegationManager.sol";
import { HybridDeleGator } from "../../src/HybridDeleGator.sol";
import { EntryPoint } from "@account-abstraction/core/EntryPoint.sol";

import "forge-std/Test.sol";

/**
 * @title DelegationMetaSwapAdapterBaseTest
 * @notice All common state, shared helper functions and common setup are in this
 *          abstract contract.
 */
abstract contract DelegationMetaSwapAdapterBaseTest is BaseTest {
    using MessageHashUtils for bytes32;

    ////////////////////////////// State & Constants //////////////////////////////

    DelegationMetaSwapAdapter public delegationMetaSwapAdapter;
    address public owner = makeAddr("DelegationMetaSwapAdapter Owner");
    IMetaSwap public metaSwapMock;
    BasicERC20 public tokenA;
    BasicERC20 public tokenB;
    uint256 public amountFrom = 1 ether;
    uint256 public amountTo = 1 ether;
    string public aggregatorId = "1";
    TestUser public vault;
    ERC20PeriodTransferEnforcer public erc20PeriodTransferEnforcer;
    NativeTokenPeriodTransferEnforcer public nativeTokenPeriodTransferEnforcer;
    RedeemerEnforcer public redeemerEnforcer;
    bytes public swapDataTokenAtoTokenB;

    uint256 public periodAmount = 10 ether;
    uint256 public periodDuration = 1 days;
    uint256 public startDate;

    uint256 public swapSignerPrivateKey;
    address public swapApiSignerAddress;

    //////////////////////// Constructor & Setup ////////////////////////

    constructor() {
        IMPLEMENTATION = Implementation.Hybrid;
        SIGNATURE_TYPE = SignatureType.RawP256;
    }

    function setUp() public virtual override {
        super.setUp();
        erc20PeriodTransferEnforcer = new ERC20PeriodTransferEnforcer();
        nativeTokenPeriodTransferEnforcer = new NativeTokenPeriodTransferEnforcer();
        redeemerEnforcer = new RedeemerEnforcer();

        startDate = block.timestamp;

        (swapApiSignerAddress, swapSignerPrivateKey) = makeAddrAndKey("SWAP_API");
    }

    //////////////////////// Internal / Private Helpers ////////////////////////

    function _getValidSignature(bytes memory _apiData, uint256 _expiration) internal returns (bytes memory) {
        bytes32 messageHash = keccak256(abi.encode(_apiData, _expiration));
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(swapSignerPrivateKey, ethSignedMessageHash);
        return abi.encodePacked(r, s, v);
    }

    function _buildSigData(bytes memory apiData) internal returns (DelegationMetaSwapAdapter.SignatureData memory) {
        uint256 expiration = block.timestamp + 1000;
        bytes memory signature = _getValidSignature(apiData, expiration);
        return DelegationMetaSwapAdapter.SignatureData({ apiData: apiData, expiration: expiration, signature: signature });
    }

    function _decodeApiData(bytes memory _apiData)
        internal
        pure
        returns (string memory aggregatorId_, IERC20 tokenFrom_, uint256 amountFrom_, bytes memory swapData_)
    {
        bytes memory parameterTerms_ = BytesLib.slice(_apiData, 4, _apiData.length - 4);
        (aggregatorId_, tokenFrom_, amountFrom_, swapData_) = abi.decode(parameterTerms_, (string, IERC20, uint256, bytes));
    }

    function _decodeApiSwapData(bytes memory _swapData)
        internal
        pure
        returns (IERC20 tokenFrom_, IERC20 tokenTo_, uint256 amountFrom_, uint256 amountTo_)
    {
        (, tokenFrom_, tokenTo_, amountFrom_, amountTo_,,,,) = abi.decode(
            abi.encodePacked(abi.encode(address(0)), _swapData),
            (address, IERC20, IERC20, uint256, uint256, bytes, uint256, address, bool)
        );
    }

    function _encodeApiData(
        string memory _aggregatorId,
        IERC20 _tokenFrom,
        uint256 _amountFrom,
        bytes memory _swapData
    )
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSelector(IMetaSwap.swap.selector, _aggregatorId, _tokenFrom, _amountFrom, _swapData);
    }

    function _encodeSwapData(
        IERC20 _tokenFrom,
        IERC20 _tokenTo,
        uint256 _amountFrom,
        uint256 _amountTo,
        bytes memory _data,
        uint256 _fee,
        address _feeWallet,
        bool _feeTo
    )
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(_tokenFrom, _tokenTo, _amountFrom, _amountTo, _data, _fee, _feeWallet, _feeTo);
    }

    function _getCaveatsErc20() private view returns (Caveat[] memory) {
        Caveat[] memory caveats_ = new Caveat[](2);

        // ERC20PeriodTransferEnforcer: token, periodAmount, periodDuration, startDate
        bytes memory periodTerms_ =
            abi.encodePacked(bytes20(address(tokenA)), bytes32(periodAmount), bytes32(periodDuration), bytes32(startDate));
        caveats_[0] = Caveat({ args: hex"", enforcer: address(erc20PeriodTransferEnforcer), terms: periodTerms_ });

        caveats_[1] = Caveat({
            args: hex"", enforcer: address(redeemerEnforcer), terms: abi.encodePacked(address(delegationMetaSwapAdapter))
        });
        return caveats_;
    }

    function _getCaveatsNativeToken() private view returns (Caveat[] memory) {
        Caveat[] memory caveats_ = new Caveat[](2);

        // NativeTokenPeriodTransferEnforcer: periodAmount, periodDuration, startDate
        bytes memory periodTerms_ = abi.encodePacked(bytes32(periodAmount), bytes32(periodDuration), bytes32(startDate));
        caveats_[0] = Caveat({ args: hex"", enforcer: address(nativeTokenPeriodTransferEnforcer), terms: periodTerms_ });

        caveats_[1] = Caveat({
            args: hex"", enforcer: address(redeemerEnforcer), terms: abi.encodePacked(address(delegationMetaSwapAdapter))
        });
        return caveats_;
    }

    /**
     * @dev Builds a single delegation from vault directly to delegationMetaSwapAdapter.
     */
    function _getVaultDelegation() internal view returns (Delegation memory) {
        Caveat[] memory caveats_ = address(tokenA) == address(0) ? _getCaveatsNativeToken() : _getCaveatsErc20();

        Delegation memory vaultDelegation_ = Delegation({
            delegate: address(delegationMetaSwapAdapter),
            delegator: address(vault.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        return signDelegation(vault, vaultDelegation_);
    }

    function _updateAllowedTokens() internal {
        IERC20[] memory allowedTokens_ = new IERC20[](3);
        allowedTokens_[0] = IERC20(tokenA);
        allowedTokens_[1] = IERC20(tokenB);
        allowedTokens_[2] = IERC20(address(0));
        bool[] memory statuses_ = new bool[](3);
        statuses_[0] = true;
        statuses_[1] = true;
        statuses_[2] = true;

        vm.prank(owner);
        delegationMetaSwapAdapter.updateAllowedTokens(allowedTokens_, statuses_);
    }

    function _whiteListCaller(address _caller) internal {
        address[] memory callers_ = new address[](1);
        callers_[0] = _caller;
        bool[] memory statuses_ = new bool[](1);
        statuses_[0] = true;

        vm.prank(owner);
        delegationMetaSwapAdapter.updateAllowedCallers(callers_, statuses_);
    }
}

/**
 * @title DelegationMetaSwapAdapterMockTest
 * @notice These tests run in a purely local environment. No fork is created.
 */
contract DelegationMetaSwapAdapterMockTest is DelegationMetaSwapAdapterBaseTest {
    DelegationMetaSwapAdapterSignatureTest public adapter;
    address public swapApiSigner;
    uint256 private _swapSignerPrivateKey = 12345;

    function setUp() public override {
        super.setUp();
        swapApiSigner = vm.addr(_swapSignerPrivateKey);
        adapter = new DelegationMetaSwapAdapterSignatureTest(address(this), swapApiSigner, address(0x123), address(0x456));
    }

    ////////////////////////////// Signature validation tests //////////////////////////////

    function test_validateSignature_valid() public view {
        bytes memory apiData_ = hex"1234";
        uint256 expiration_ = block.timestamp + 1 hours;
        bytes32 messageHash_ = keccak256(abi.encode(apiData_, expiration_));
        bytes32 ethSignedMessageHash_ = MessageHashUtils.toEthSignedMessageHash(messageHash_);
        (uint8 v_, bytes32 r_, bytes32 s_) = vm.sign(_swapSignerPrivateKey, ethSignedMessageHash_);
        bytes memory signature_ = abi.encodePacked(r_, s_, v_);

        DelegationMetaSwapAdapter.SignatureData memory sigData_ =
            DelegationMetaSwapAdapter.SignatureData({ apiData: apiData_, expiration: expiration_, signature: signature_ });

        adapter.exposedValidateSignature(sigData_);
    }

    function test_validateSignature_expired() public {
        bytes memory apiData_ = hex"1234";
        uint256 expiration_ = block.timestamp - 1;
        bytes32 messageHash_ = keccak256(abi.encode(apiData_, expiration_));
        bytes32 ethSignedMessageHash_ = MessageHashUtils.toEthSignedMessageHash(messageHash_);
        (uint8 v_, bytes32 r_, bytes32 s_) = vm.sign(_swapSignerPrivateKey, ethSignedMessageHash_);
        bytes memory signature_ = abi.encodePacked(r_, s_, v_);

        DelegationMetaSwapAdapter.SignatureData memory sigData_ =
            DelegationMetaSwapAdapter.SignatureData({ apiData: apiData_, expiration: expiration_, signature: signature_ });

        vm.expectRevert(DelegationMetaSwapAdapter.SignatureExpired.selector);
        adapter.exposedValidateSignature(sigData_);
    }

    function test_validateSignature_invalidSigner() public {
        bytes memory apiData = hex"1234";
        uint256 expiration = block.timestamp + 1 hours;
        bytes32 messageHash = keccak256(abi.encode(apiData, expiration));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_swapSignerPrivateKey + 1, messageHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        DelegationMetaSwapAdapter.SignatureData memory sigData =
            DelegationMetaSwapAdapter.SignatureData({ apiData: apiData, expiration: expiration, signature: signature });

        vm.expectRevert(DelegationMetaSwapAdapter.InvalidApiSignature.selector);
        adapter.exposedValidateSignature(sigData);
    }

    function test_validateSignature_emptySignature() public {
        bytes memory apiData = hex"1234";
        uint256 expiration = block.timestamp + 1 hours;
        bytes memory emptySignature = "";

        DelegationMetaSwapAdapter.SignatureData memory sigData =
            DelegationMetaSwapAdapter.SignatureData({ apiData: apiData, expiration: expiration, signature: emptySignature });

        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, 0));
        adapter.exposedValidateSignature(sigData);
    }

    function test_validateSignature_hardcodedSignature() public {
        address swapApiSigner_ = 0x533FbF047Ed13C20e263e2576e41c747206d1348;

        vm.prank(address(this));
        adapter.setSwapApiSigner(swapApiSigner_);

        bytes memory apiData_ =
            hex"5f5755290000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000470de4df82000000000000000000000000000000000000000000000000000000000000000000c0000000000000000000000000000000000000000000000000000000000000001c616972737761704c696768743446656544796e616d696346697865640000000000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000196652ed3350000000000000000000000000000000000000000000000000000000068098586000000000000000000000000111bb8c3542f2b92fb41b8d913c01d37884311110000000000000000000000006b175474e89094c44da98b954eedeac495271d0f000000000000000000000000000000000000000000000001eb87e2999f2f8380000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000466ebb82ac1000000000000000000000000000000000000000000000000000000000000000001c427cdd17278850f9344bb9b4940a6ce83afbb34b58410cdcdf1ff8b27ea8b7eb338693a44fa8d73a0878779e2f6b41c6af69f42510d98f1bfd19d7675e1b3a9d00000000000000000000000000000000000000000000000000009f295cd5f000000000000000000000000000f326e4de8f66a0bdc0970b79e0924e33c79f19150000000000000000000000000000000000000000000000000000000000000000007f";
        uint256 expiration_ = 1745454591251;

        bytes memory signature =
            hex"fccc4800a4a9d9aa6a8cf933ca759f3974d8eed02e47b12a739601ef1e83617a08c7597d0dd875f955511248da6cf4cfb92be67c0d7241104c061a3c4d45f3b51b";

        DelegationMetaSwapAdapter.SignatureData memory sigData_ =
            DelegationMetaSwapAdapter.SignatureData({ apiData: apiData_, expiration: expiration_, signature: signature });

        adapter.exposedValidateSignature(sigData_);
    }

    ////////////////////////////// Swap tests //////////////////////////////

    function test_revert_invalidZeroAddressInConstructor() public {
        address owner_ = address(1);
        address swapApiSigner_ = address(1);
        IDelegationManager delegationManager_ = IDelegationManager(address(1));
        IMetaSwap metaSwap_ = IMetaSwap(address(1));

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new DelegationMetaSwapAdapter(address(0), swapApiSigner_, delegationManager_, metaSwap_);

        vm.expectRevert(DelegationMetaSwapAdapter.InvalidZeroAddress.selector);
        new DelegationMetaSwapAdapter(owner_, address(0), delegationManager_, metaSwap_);

        vm.expectRevert(DelegationMetaSwapAdapter.InvalidZeroAddress.selector);
        new DelegationMetaSwapAdapter(owner_, swapApiSigner_, IDelegationManager(address(0)), metaSwap_);

        vm.expectRevert(DelegationMetaSwapAdapter.InvalidZeroAddress.selector);
        new DelegationMetaSwapAdapter(owner_, swapApiSigner_, delegationManager_, IMetaSwap(address(0)));
    }

    function test_canSwapByDelegationsMockErc20TokenFrom() public {
        _setUpMockContracts();

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _getVaultDelegation();

        uint256 vaultTokenABalanceBefore_ = tokenA.balanceOf(address(vault.deleGator));
        uint256 vaultTokenBBalanceBefore_ = tokenB.balanceOf(address(vault.deleGator));

        bytes memory swapData_ = _encodeSwapData(IERC20(tokenA), IERC20(tokenB), amountFrom, amountTo, hex"", 0, address(0), false);
        bytes memory apiData_ = _encodeApiData(aggregatorId, IERC20(tokenA), amountFrom, swapData_);
        DelegationMetaSwapAdapter.SignatureData memory sigData_ = _buildSigData(apiData_);

        delegationMetaSwapAdapter.swapByDelegation(sigData_, delegations_);

        uint256 vaultTokenAUsed_ = vaultTokenABalanceBefore_ - tokenA.balanceOf(address(vault.deleGator));
        uint256 vaultTokenBObtained_ = tokenB.balanceOf(address(vault.deleGator)) - vaultTokenBBalanceBefore_;
        assertEq(vaultTokenAUsed_, amountFrom, "Vault should spend the specified amount of tokenA");
        assertEq(vaultTokenBObtained_, amountTo, "Vault should receive the correct amount of tokenB");
    }

    function test_canSwapByDelegationsMockNativeTokenFrom() public {
        _setUpMockContractsEth(true, false);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _getVaultDelegation();

        uint256 vaultEthBalanceBefore = address(vault.deleGator).balance;
        uint256 vaultTokenBBalanceBefore = tokenB.balanceOf(address(vault.deleGator));

        bytes memory swapData_ = _encodeSwapData(IERC20(tokenA), IERC20(tokenB), amountFrom, amountTo, hex"", 0, address(0), true);
        bytes memory apiData_ = _encodeApiData(aggregatorId, IERC20(tokenA), amountFrom, swapData_);
        DelegationMetaSwapAdapter.SignatureData memory sigData_ = _buildSigData(apiData_);

        delegationMetaSwapAdapter.swapByDelegation(sigData_, delegations_);

        uint256 vaultEthUsed = vaultEthBalanceBefore - address(vault.deleGator).balance;
        uint256 vaultTokenBObtained = tokenB.balanceOf(address(vault.deleGator)) - vaultTokenBBalanceBefore;
        assertEq(vaultEthUsed, amountFrom, "Vault should spend the specified amount of ETH");
        assertEq(vaultTokenBObtained, amountTo, "Vault should receive the correct amount of tokenB");
    }

    function test_canSwapByDelegationsMockNativeTo() public {
        _setUpMockContractsEth(false, true);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _getVaultDelegation();

        uint256 vaultTokenABalanceBefore = tokenA.balanceOf(address(vault.deleGator));
        uint256 vaultEthBalanceBefore = address(vault.deleGator).balance;

        bytes memory swapData_ = _encodeSwapData(IERC20(tokenA), IERC20(tokenB), amountFrom, amountTo, hex"", 0, address(0), false);
        bytes memory apiData_ = _encodeApiData(aggregatorId, IERC20(tokenA), amountFrom, swapData_);
        DelegationMetaSwapAdapter.SignatureData memory sigData_ = _buildSigData(apiData_);

        delegationMetaSwapAdapter.swapByDelegation(sigData_, delegations_);

        uint256 vaultTokenAUsed = vaultTokenABalanceBefore - tokenA.balanceOf(address(vault.deleGator));
        uint256 vaultEthObtained = address(vault.deleGator).balance - vaultEthBalanceBefore;
        assertEq(vaultTokenAUsed, amountFrom, "Vault should spend the specified amount of tokenA");
        assertEq(vaultEthObtained, amountTo, "Vault should receive the correct amount of ETH");
    }

    /// @notice Verifies that the period enforcer refills after a period elapses.
    function test_canSwapMultipleTimesWithPeriodRefill() public {
        _setUpMockContracts();

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _getVaultDelegation();

        bytes memory swapData_ = _encodeSwapData(IERC20(tokenA), IERC20(tokenB), amountFrom, amountTo, hex"", 0, address(0), false);
        bytes memory apiData_ = _encodeApiData(aggregatorId, IERC20(tokenA), amountFrom, swapData_);

        // First swap
        DelegationMetaSwapAdapter.SignatureData memory sigData1_ = _buildSigData(apiData_);
        delegationMetaSwapAdapter.swapByDelegation(sigData1_, delegations_);

        // Second swap in same period should also work (periodAmount = 10 ether, amountFrom = 1 ether)
        DelegationMetaSwapAdapter.SignatureData memory sigData2_ = _buildSigData(apiData_);
        delegationMetaSwapAdapter.swapByDelegation(sigData2_, delegations_);

        // Warp to next period
        vm.warp(block.timestamp + periodDuration);

        // Should work again after period refill
        DelegationMetaSwapAdapter.SignatureData memory sigData3_ = _buildSigData(apiData_);
        delegationMetaSwapAdapter.swapByDelegation(sigData3_, delegations_);
    }

    /// @notice Tests that swapByDelegation reverts when called by a non-whitelisted caller.
    function test_revert_swapByDelegation_callerNotAllowed() public {
        _setUpMockContracts();

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _getVaultDelegation();

        bytes memory swapData_ = _encodeSwapData(IERC20(tokenA), IERC20(tokenB), amountFrom, amountTo, hex"", 0, address(0), false);
        bytes memory apiData_ = _encodeApiData(aggregatorId, IERC20(tokenA), amountFrom, swapData_);
        DelegationMetaSwapAdapter.SignatureData memory sigData_ = _buildSigData(apiData_);

        address randomCaller = makeAddr("RandomCaller");
        vm.prank(randomCaller);
        vm.expectRevert(DelegationMetaSwapAdapter.CallerNotAllowed.selector);
        delegationMetaSwapAdapter.swapByDelegation(sigData_, delegations_);
    }

    /// @notice Tests that a whitelisted caller can successfully call swapByDelegation.
    function test_whitelistedCallerCanSwap() public {
        _setUpMockContracts();

        address allowedCaller = makeAddr("AllowedCaller");
        _whiteListCaller(allowedCaller);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _getVaultDelegation();

        uint256 vaultTokenBBalanceBefore_ = tokenB.balanceOf(address(vault.deleGator));

        bytes memory swapData_ = _encodeSwapData(IERC20(tokenA), IERC20(tokenB), amountFrom, amountTo, hex"", 0, address(0), false);
        bytes memory apiData_ = _encodeApiData(aggregatorId, IERC20(tokenA), amountFrom, swapData_);
        DelegationMetaSwapAdapter.SignatureData memory sigData_ = _buildSigData(apiData_);

        vm.prank(allowedCaller);
        delegationMetaSwapAdapter.swapByDelegation(sigData_, delegations_);

        uint256 vaultTokenBObtained_ = tokenB.balanceOf(address(vault.deleGator)) - vaultTokenBBalanceBefore_;
        assertEq(vaultTokenBObtained_, amountTo, "Vault should receive the correct amount of tokenB");
    }

    /// @notice Verifies that only the current owner can initiate ownership transfer.
    function test_revert_transferOwnership_ifNotOwner() public {
        _setUpMockContracts();

        address nonOwner_ = makeAddr("NonOwner");
        vm.startPrank(nonOwner_);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner_));
        delegationMetaSwapAdapter.transferOwnership(makeAddr("NewOwner"));
        vm.stopPrank();
    }

    function test_canTransferAndAcceptOwnership() public {
        _setUpMockContracts();

        address newOwner_ = makeAddr("NewOwner");

        vm.startPrank(owner);
        delegationMetaSwapAdapter.transferOwnership(newOwner_);
        assertEq(delegationMetaSwapAdapter.owner(), owner);
        vm.stopPrank();

        vm.startPrank(newOwner_);
        delegationMetaSwapAdapter.acceptOwnership();
        assertEq(delegationMetaSwapAdapter.owner(), newOwner_);
        vm.stopPrank();
    }

    function test_revert_acceptOwnership_ifNotPendingOwner() public {
        _setUpMockContracts();

        address newOwner = makeAddr("NewOwner");
        vm.startPrank(owner);
        delegationMetaSwapAdapter.transferOwnership(newOwner);
        vm.stopPrank();

        address attacker = makeAddr("Attacker");
        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(attacker)));
        delegationMetaSwapAdapter.acceptOwnership();
        vm.stopPrank();
    }

    function test_canUpdateAllowedTokens() public {
        _setUpMockContracts();
        BasicERC20 tokenC_ = new BasicERC20(owner, "TokenC", "TKC", 0);

        IERC20[] memory tokens_ = new IERC20[](2);
        tokens_[0] = IERC20(tokenA);
        tokens_[1] = IERC20(tokenC_);

        bool[] memory statuses_ = new bool[](2);
        statuses_[0] = false;
        statuses_[1] = true;

        vm.startPrank(owner);
        delegationMetaSwapAdapter.updateAllowedTokens(tokens_, statuses_);
        vm.stopPrank();

        assertFalse(delegationMetaSwapAdapter.isTokenAllowed(tokenA));
        assertTrue(delegationMetaSwapAdapter.isTokenAllowed(tokenC_));
    }

    function test_revert_updateAllowedTokens_ifNotOwner() public {
        _setUpMockContracts();

        IERC20[] memory tokens_ = new IERC20[](1);
        tokens_[0] = IERC20(tokenA);

        bool[] memory statuses_ = new bool[](1);
        statuses_[0] = false;

        address nonOwner_ = makeAddr("NonOwner");
        vm.startPrank(nonOwner_);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner_));
        delegationMetaSwapAdapter.updateAllowedTokens(tokens_, statuses_);
        vm.stopPrank();
    }

    function test_revert_updateAllowedTokens_arrayLengthMismatch() public {
        _setUpMockContracts();

        IERC20[] memory tokens_ = new IERC20[](2);
        tokens_[0] = IERC20(tokenA);
        tokens_[1] = IERC20(tokenB);

        bool[] memory statuses_ = new bool[](1);
        statuses_[0] = false;

        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(DelegationMetaSwapAdapter.InputLengthsMismatch.selector));
        delegationMetaSwapAdapter.updateAllowedTokens(tokens_, statuses_);
        vm.stopPrank();
    }

    function test_canUpdateAllowedCallers() public {
        _setUpMockContracts();

        address caller1_ = makeAddr("Caller1");
        address caller2_ = makeAddr("Caller2");

        address[] memory callers_ = new address[](2);
        callers_[0] = caller1_;
        callers_[1] = caller2_;
        bool[] memory statuses_ = new bool[](2);
        statuses_[0] = true;
        statuses_[1] = true;

        vm.prank(owner);
        delegationMetaSwapAdapter.updateAllowedCallers(callers_, statuses_);

        assertTrue(delegationMetaSwapAdapter.isCallerAllowed(caller1_));
        assertTrue(delegationMetaSwapAdapter.isCallerAllowed(caller2_));

        // Remove caller1
        callers_ = new address[](1);
        callers_[0] = caller1_;
        statuses_ = new bool[](1);
        statuses_[0] = false;

        vm.prank(owner);
        delegationMetaSwapAdapter.updateAllowedCallers(callers_, statuses_);

        assertFalse(delegationMetaSwapAdapter.isCallerAllowed(caller1_));
        assertTrue(delegationMetaSwapAdapter.isCallerAllowed(caller2_));
    }

    function test_revert_updateAllowedCallers_ifNotOwner() public {
        _setUpMockContracts();

        address[] memory callers_ = new address[](1);
        callers_[0] = makeAddr("Caller");
        bool[] memory statuses_ = new bool[](1);
        statuses_[0] = true;

        address nonOwner_ = makeAddr("NonOwner");
        vm.prank(nonOwner_);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner_));
        delegationMetaSwapAdapter.updateAllowedCallers(callers_, statuses_);
    }

    function test_revert_updateAllowedCallers_arrayLengthMismatch() public {
        _setUpMockContracts();

        address[] memory callers_ = new address[](2);
        callers_[0] = makeAddr("C1");
        callers_[1] = makeAddr("C2");
        bool[] memory statuses_ = new bool[](1);
        statuses_[0] = true;

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(DelegationMetaSwapAdapter.InputLengthsMismatch.selector));
        delegationMetaSwapAdapter.updateAllowedCallers(callers_, statuses_);
    }

    function test_event_ChangedCallerStatus() public {
        _setUpMockContracts();

        address caller_ = makeAddr("Caller");
        address[] memory callers_ = new address[](1);
        callers_[0] = caller_;
        bool[] memory statuses_ = new bool[](1);
        statuses_[0] = true;

        vm.expectEmit(true, false, false, true);
        emit DelegationMetaSwapAdapter.ChangedCallerStatus(caller_, true);
        vm.prank(owner);
        delegationMetaSwapAdapter.updateAllowedCallers(callers_, statuses_);
    }

    function test_revert_swapByDelegation_emptyDelegations() public {
        _setUpMockContracts();
        bytes memory apiData_ = _encodeApiData(aggregatorId, IERC20(tokenA), amountFrom, swapDataTokenAtoTokenB);
        Delegation[] memory emptyDelegations_ = new Delegation[](0);
        DelegationMetaSwapAdapter.SignatureData memory sigData_ = _buildSigData(apiData_);

        vm.expectRevert(DelegationMetaSwapAdapter.InvalidEmptyDelegations.selector);
        delegationMetaSwapAdapter.swapByDelegation(sigData_, emptyDelegations_);
    }

    function test_revert_swapByDelegation_identicalTokens() public {
        _setUpMockContracts();
        bytes memory swapDataIdentical_ =
            _encodeSwapData(IERC20(tokenA), IERC20(tokenA), amountFrom, amountTo, hex"", 0, address(0), true);
        bytes memory apiData_ = _encodeApiData(aggregatorId, IERC20(tokenA), amountFrom, swapDataIdentical_);
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _getVaultDelegation();
        DelegationMetaSwapAdapter.SignatureData memory sigData_ = _buildSigData(apiData_);

        vm.expectRevert(DelegationMetaSwapAdapter.InvalidIdenticalTokens.selector);
        delegationMetaSwapAdapter.swapByDelegation(sigData_, delegations_);
    }

    function test_revert_swapByDelegation_tokenFromNotAllowed() public {
        _setUpMockContracts();
        IERC20[] memory tokens_ = new IERC20[](1);
        tokens_[0] = IERC20(tokenA);
        bool[] memory statuses_ = new bool[](1);
        statuses_[0] = false;
        vm.prank(owner);
        delegationMetaSwapAdapter.updateAllowedTokens(tokens_, statuses_);

        bytes memory apiData_ = _encodeApiData(aggregatorId, IERC20(tokenA), amountFrom, swapDataTokenAtoTokenB);
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _getVaultDelegation();

        DelegationMetaSwapAdapter.SignatureData memory sigData_ = _buildSigData(apiData_);

        vm.expectRevert(abi.encodeWithSelector(DelegationMetaSwapAdapter.TokenFromIsNotAllowed.selector, tokenA));
        delegationMetaSwapAdapter.swapByDelegation(sigData_, delegations_);
    }

    function test_revert_swapByDelegation_tokenToNotAllowed() public {
        _setUpMockContracts();
        IERC20[] memory tokens_ = new IERC20[](1);
        tokens_[0] = IERC20(tokenB);
        bool[] memory statuses_ = new bool[](1);
        statuses_[0] = false;
        vm.prank(owner);
        delegationMetaSwapAdapter.updateAllowedTokens(tokens_, statuses_);

        bytes memory apiData_ = _encodeApiData(aggregatorId, IERC20(tokenA), amountFrom, swapDataTokenAtoTokenB);
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _getVaultDelegation();

        DelegationMetaSwapAdapter.SignatureData memory sigData_ = _buildSigData(apiData_);

        vm.expectRevert(abi.encodeWithSelector(DelegationMetaSwapAdapter.TokenToIsNotAllowed.selector, tokenB));
        delegationMetaSwapAdapter.swapByDelegation(sigData_, delegations_);
    }

    function test_withdraw() public {
        _setUpMockContracts();
        uint256 withdrawAmount_ = 0.8 ether;
        vm.prank(owner);
        tokenA.mint(address(delegationMetaSwapAdapter), withdrawAmount_);
        address recipient_ = address(0xABCD);
        vm.expectEmit(true, true, true, true);
        emit DelegationMetaSwapAdapter.SentTokens(tokenA, recipient_, withdrawAmount_);
        vm.prank(owner);
        delegationMetaSwapAdapter.withdraw(tokenA, withdrawAmount_, recipient_);
        assertEq(tokenA.balanceOf(recipient_), withdrawAmount_, "Recipient should receive the withdrawn tokenA");
    }

    function test_withdraw_native() public {
        _setUpMockContracts();
        uint256 withdrawAmount_ = 1 ether;
        address recipient_ = address(0xDEAD);
        vm.deal(address(delegationMetaSwapAdapter), withdrawAmount_);
        vm.expectEmit(true, true, true, true);
        emit DelegationMetaSwapAdapter.SentTokens(IERC20(address(0)), recipient_, withdrawAmount_);
        vm.prank(owner);
        delegationMetaSwapAdapter.withdraw(IERC20(address(0)), withdrawAmount_, recipient_);
        assertEq(recipient_.balance, withdrawAmount_, "Recipient should receive the withdrawn ETH");
    }

    function test_event_ChangedTokenStatus() public {
        _setUpMockContracts();
        BasicERC20 tokenC_ = new BasicERC20(owner, "TokenC", "TKC", 0);

        IERC20[] memory tokens_ = new IERC20[](2);
        tokens_[0] = IERC20(tokenA);
        tokens_[1] = IERC20(tokenC_);
        bool[] memory statuses_ = new bool[](2);
        statuses_[0] = false;
        statuses_[1] = true;

        vm.expectEmit(false, false, false, true);
        emit DelegationMetaSwapAdapter.ChangedTokenStatus(tokenA, false);
        vm.expectEmit(false, false, false, true);
        emit DelegationMetaSwapAdapter.ChangedTokenStatus(tokenC_, true);
        vm.prank(owner);
        delegationMetaSwapAdapter.updateAllowedTokens(tokens_, statuses_);
    }

    function test_revert_withdraw_ifNotOwner() public {
        _setUpMockContracts();
        address nonOwner_ = makeAddr("NonOwner");
        vm.prank(nonOwner_);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner_));
        delegationMetaSwapAdapter.withdraw(tokenA, 1 ether, address(vault.deleGator));
    }

    function test_revert_withdraw_failedNativeTokenTransfer() public {
        _setUpMockContracts();
        uint256 withdrawAmount_ = type(uint256).max;
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(DelegationMetaSwapAdapter.FailedNativeTokenTransfer.selector, address(delegationMetaSwapAdapter))
        );
        delegationMetaSwapAdapter.withdraw(IERC20(address(0)), withdrawAmount_, address(delegationMetaSwapAdapter));
    }

    function test_revert_swapByDelegation_invalidSwapFunctionSelector() public {
        _setUpMockContracts();

        bytes4 invalidSelector_ = 0xDEADBEEF;

        bytes memory invalidApiData_ =
            abi.encodePacked(invalidSelector_, abi.encode("aggregatorId", IERC20(tokenA), uint256(1 ether), hex""));

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _getVaultDelegation();

        DelegationMetaSwapAdapter.SignatureData memory sigData_ = _buildSigData(invalidApiData_);

        vm.expectRevert(DelegationMetaSwapAdapter.InvalidSwapFunctionSelector.selector);
        delegationMetaSwapAdapter.swapByDelegation(sigData_, delegations_);
    }

    function test_revert_swapByDelegation_tokenFromMismatch() public {
        _setUpMockContracts();

        bytes memory validApiData_ = _encodeApiData(aggregatorId, IERC20(address(0)), amountFrom, swapDataTokenAtoTokenB);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _getVaultDelegation();
        DelegationMetaSwapAdapter.SignatureData memory sigData_ = _buildSigData(validApiData_);

        vm.expectRevert(DelegationMetaSwapAdapter.TokenFromMismatch.selector);
        delegationMetaSwapAdapter.swapByDelegation(sigData_, delegations_);
    }

    function test_revert_swapByDelegation_amountFromMismatch() public {
        _setUpMockContracts();

        uint256 topLevelAmountFrom = 1 ether;
        uint256 aggregatorAmountFrom_ = 0.9 ether;
        uint256 aggregatorFee_ = 0.05 ether;
        bool feeTo_ = false;

        bytes memory invalidSwapData_ =
            abi.encode(tokenA, tokenB, aggregatorAmountFrom_, uint256(1 ether), hex"", aggregatorFee_, address(0), feeTo_);

        bytes memory apiData_ =
            abi.encodeWithSelector(IMetaSwap.swap.selector, aggregatorId, tokenA, topLevelAmountFrom, invalidSwapData_);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _getVaultDelegation();

        DelegationMetaSwapAdapter.SignatureData memory sigData_ = _buildSigData(apiData_);

        vm.expectRevert(DelegationMetaSwapAdapter.AmountFromMismatch.selector);
        delegationMetaSwapAdapter.swapByDelegation(sigData_, delegations_);
    }

    function test_event_constructor_events() public {
        address dummySwapApiSignerAddress_ = address(0x999);
        address dummyDelegationManager_ = address(0x123);
        address dummyMetaSwap_ = address(0x456);

        vm.expectEmit(true, true, false, true);
        emit DelegationMetaSwapAdapter.SwapApiSignerUpdated(dummySwapApiSignerAddress_);
        vm.expectEmit(true, true, false, true);
        emit DelegationMetaSwapAdapter.SetDelegationManager(IDelegationManager(dummyDelegationManager_));
        vm.expectEmit(true, true, false, true);
        emit DelegationMetaSwapAdapter.SetMetaSwap(IMetaSwap(dummyMetaSwap_));
        DelegationMetaSwapAdapter adapter_ = new DelegationMetaSwapAdapter(
            owner, dummySwapApiSignerAddress_, IDelegationManager(dummyDelegationManager_), IMetaSwap(dummyMetaSwap_)
        );
        assertEq(adapter_.owner(), owner, "Constructor did not set owner correctly");
        assertEq(
            address(adapter_.delegationManager()), dummyDelegationManager_, "Constructor did not set delegationManager correctly"
        );
        assertEq(address(adapter_.swapApiSigner()), dummySwapApiSignerAddress_, "Constructor did not set swapApiSigner correctly");
        assertEq(address(adapter_.metaSwap()), dummyMetaSwap_, "Constructor did not set metaSwap correctly");
    }

    /// @notice Tests that allowance is set to max after a swap (forceApprove coverage via full flow).
    function test_swapByDelegation_setsAllowanceToMax() public {
        _setUpMockContracts();

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _getVaultDelegation();

        bytes memory swapData_ = _encodeSwapData(IERC20(tokenA), IERC20(tokenB), amountFrom, amountTo, hex"", 0, address(0), false);
        bytes memory apiData_ = _encodeApiData(aggregatorId, IERC20(tokenA), amountFrom, swapData_);
        DelegationMetaSwapAdapter.SignatureData memory sigData_ = _buildSigData(apiData_);

        delegationMetaSwapAdapter.swapByDelegation(sigData_, delegations_);

        uint256 allowanceAfter_ = tokenA.allowance(address(delegationMetaSwapAdapter), address(metaSwapMock));
        assertEq(allowanceAfter_, type(uint256).max, "Allowance should be set to max after swap");
    }

    function test_setSwapApiSigner_updatesStateAndEmitsEvent() public {
        _setUpMockContracts();
        address newSigner_ = makeAddr("NewSwapSigner");
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit DelegationMetaSwapAdapter.SwapApiSignerUpdated(newSigner_);
        delegationMetaSwapAdapter.setSwapApiSigner(newSigner_);
        assertEq(delegationMetaSwapAdapter.swapApiSigner(), newSigner_, "Swap API signer was not updated");
    }

    function test_revert_setSwapApiSigner_ifZeroAddress() public {
        _setUpMockContracts();
        vm.prank(owner);
        vm.expectRevert(DelegationMetaSwapAdapter.InvalidZeroAddress.selector);
        delegationMetaSwapAdapter.setSwapApiSigner(address(0));
    }

    function test_revert_setSwapApiSigner_ifNotOwner() public {
        _setUpMockContracts();
        address newSigner_ = makeAddr("NewSwapSigner");
        address nonOwner_ = makeAddr("NonOwner");
        vm.prank(nonOwner_);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner_));
        delegationMetaSwapAdapter.setSwapApiSigner(newSigner_);
    }

    function test_revert_swapByDelegation_signatureExpired() public {
        _setUpMockContracts();
        bytes memory swapData_ = _encodeSwapData(IERC20(tokenA), IERC20(tokenB), amountFrom, amountTo, hex"", 0, address(0), true);
        bytes memory apiData_ = _encodeApiData(aggregatorId, IERC20(tokenA), amountFrom, swapData_);
        uint256 expiredTime = block.timestamp - 1;
        bytes memory signature = _getValidSignature(apiData_, expiredTime);
        DelegationMetaSwapAdapter.SignatureData memory sigData_ =
            DelegationMetaSwapAdapter.SignatureData({ apiData: apiData_, expiration: expiredTime, signature: signature });

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _getVaultDelegation();

        vm.expectRevert(DelegationMetaSwapAdapter.SignatureExpired.selector);
        delegationMetaSwapAdapter.swapByDelegation(sigData_, delegations_);
    }

    function test_revert_swapByDelegation_signatureExpired_equal() public {
        _setUpMockContracts();
        bytes memory swapData_ = _encodeSwapData(IERC20(tokenA), IERC20(tokenB), amountFrom, amountTo, hex"", 0, address(0), true);
        bytes memory apiData_ = _encodeApiData(aggregatorId, IERC20(tokenA), amountFrom, swapData_);
        uint256 expiredTime = block.timestamp;
        bytes memory signature = _getValidSignature(apiData_, expiredTime);
        DelegationMetaSwapAdapter.SignatureData memory sigData_ =
            DelegationMetaSwapAdapter.SignatureData({ apiData: apiData_, expiration: expiredTime, signature: signature });

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _getVaultDelegation();

        vm.expectRevert(DelegationMetaSwapAdapter.SignatureExpired.selector);
        delegationMetaSwapAdapter.swapByDelegation(sigData_, delegations_);
    }

    function test_revert_swapByDelegation_invalidApiSignature() public {
        _setUpMockContracts();
        bytes memory swapData_ = _encodeSwapData(IERC20(tokenA), IERC20(tokenB), amountFrom, amountTo, hex"", 0, address(0), true);
        bytes memory apiData_ = _encodeApiData(aggregatorId, IERC20(tokenA), amountFrom, swapData_);

        swapSignerPrivateKey = 11111;
        DelegationMetaSwapAdapter.SignatureData memory sigData_ = _buildSigData(apiData_);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _getVaultDelegation();

        vm.expectRevert(DelegationMetaSwapAdapter.InvalidApiSignature.selector);
        delegationMetaSwapAdapter.swapByDelegation(sigData_, delegations_);
    }

    function _setUpMockContracts() internal {
        _setUpMockContractsEth(false, false);
    }

    function _setUpMockContractsEth(bool _useEthFrom, bool _useEthTo) internal {
        vault = users.alice;

        tokenA = _useEthFrom ? BasicERC20(address(0)) : new BasicERC20(owner, "TokenA", "TokenA", 0);
        tokenB = _useEthTo ? BasicERC20(address(0)) : new BasicERC20(owner, "TokenB", "TokenB", 0);
        vm.label(address(tokenA), "TokenA");
        vm.label(address(tokenB), "TokenB");

        metaSwapMock = IMetaSwap(address(new MetaSwapMock(IERC20(tokenA), IERC20(tokenB))));

        delegationMetaSwapAdapter = new DelegationMetaSwapAdapter(
            owner, swapApiSignerAddress, IDelegationManager(address(delegationManager)), metaSwapMock
        );

        vm.startPrank(owner);

        if (!_useEthFrom) {
            tokenA.mint(address(vault.deleGator), 100 ether);
            tokenA.mint(address(metaSwapMock), 1000 ether);
        }
        if (!_useEthTo) {
            tokenB.mint(address(vault.deleGator), 100 ether);
            tokenB.mint(address(metaSwapMock), 1000 ether);
        }

        vm.stopPrank();

        vm.deal(address(metaSwapMock), 1000 ether);

        _updateAllowedTokens();

        _whiteListCaller(address(this));

        swapDataTokenAtoTokenB =
            abi.encode(IERC20(address(tokenA)), IERC20(address(tokenB)), 1 ether, 1 ether, hex"", uint256(0), address(0), true);
    }
}

/**
 * @title DelegationMetaSwapAdapterForkTest
 * @notice These tests run on a fork. Note that the fork creation is performed
 *  as the very first step in setUp.
 */
contract DelegationMetaSwapAdapterForkTest is DelegationMetaSwapAdapterBaseTest {
    ////////////////////////
    // MetaSwap + Linea mainnet fork section
    ////////////////////////
    uint256 mainnetFork;
    IDelegationManager constant DELEGATION_MANAGER_FORK = IDelegationManager(0x739309deED0Ae184E66a427ACa432aE1D91d022e);
    HybridDeleGator constant HYBRID_DELEGATOR_IMPL_FORK = HybridDeleGator(payable(0xf4E57F579ad8169D0d4Da7AedF71AC3f83e8D2b4));
    EntryPoint constant ENTRY_POINT_FORK = EntryPoint(payable(0x0000000071727De22E5E9d8BAf0edAc6f37da032));
    IMetaSwap constant META_SWAP_FORK = IMetaSwap(0x9dDA6Ef3D919c9bC8885D5560999A3640431e8e6);
    bytes public constant API_DATA_ERC20_TO_ERC20 =
        hex"5f5755290000000000000000000000000000000000000000000000000000000000000080000000000000000000000000176211869ca2b568f2a7d4ee941e073a821ee1ff000000000000000000000000000000000000000000000000000000003b9aca0000000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000000136f70656e4f6365616e46656544796e616d6963000000000000000000000000000000000000000000000000000000000000000000000000000000000000001c80000000000000000000000000176211869ca2b568f2a7d4ee941e073a821ee1ff000000000000000000000000a219439258ca9da29e9cc4ce5596924745e12b93000000000000000000000000000000000000000000000000000000003b9aca000000000000000000000000000000000000000000000000000000000039ece309000000000000000000000000000000000000000000000000000000000000012000000000000000000000000000000000000000000000000000000000008591cb0000000000000000000000001f3c3f0243d06a0353abcb066be9140747aeb8c900000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000001b4490411a32000000000000000000000000dec876911cbe9428265af0d12132c52ee8642a99000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000001c0000000000000000000000000176211869ca2b568f2a7d4ee941e073a821ee1ff000000000000000000000000a219439258ca9da29e9cc4ce5596924745e12b93000000000000000000000000dec876911cbe9428265af0d12132c52ee8642a990000000000000000000000000a2854fbbd9b3ef66f17d47284e7f899b9509330000000000000000000000000000000000000000000000000000000003b9aca00000000000000000000000000000000000000000000000000000000003a6fc8f3000000000000000000000000000000000000000000000000000000003ba116320000000000000000000000000000000000000000000000000000000000000002000000000000000000000000ef53a4bd0e16ccc9116770a41c4bd3ad1147bd4f00000000000000000000000000000000000000000000000000000000000001400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000140000000000000000000000000000000000000000000000000000000000000030000000000000000000000000000000000000000000000000000000000000004c0000000000000000000000000000000000000000000000000000000000000072000000000000000000000000000000000000000000000000000000000000008400000000000000000000000000000000000000000000000000000000000000b400000000000000000000000000000000000000000000000000000000000000e40000000000000000000000000000000000000000000000000000000000000114000000000000000000000000000000000000000000000000000000000000015e0000000000000000000000000000000000000000000000000000000000000170000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000104e5b07cdb0000000000000000000000003cb104f044db23d6513f2a6100a1997fa5e3f58700000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000023c34600000000000000000000000000dec876911cbe9428265af0d12132c52ee8642a9900000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000002e176211869ca2b568f2a7d4ee941e073a821ee1ff000000e5d7c2a44ffddf6b295a15c148167daaaf5cf34f0000170000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000104576188040000000000000000000000005615a7b1619980f7d6b5e7f69f3dc093dfe0c95c00000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000017d78400000000000000000000000000dec876911cbe9428265af0d12132c52ee8642a9900000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000003f45e5f26451cdb01b0fa1f8582e0aad9a6f27c218176211869ca2b568f2a7d4ee941e073a821ee1ff0001f4e5d7c2a44ffddf6b295a15c148167daaaf5cf34f0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000001a49f865422000000000000000000000000e5d7c2a44ffddf6b295a15c148167daaaf5cf34f00000000000000000000000000000008000000000000000000000000000000190000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000004400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000064d1660f99000000000000000000000000e5d7c2a44ffddf6b295a15c148167daaaf5cf34f000000000000000000000000101c6e1e717f13fb351c0b51ffaa8839034f474d000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008d58ee2d23f7920ea32e534aad8d6753c88bc01a000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000006493316212000000000000000000000000e5d7c2a44ffddf6b295a15c148167daaaf5cf34f0000000000000000000000003aab2285ddcddad8edf438c1bab47e1a9d05a9b4000000000000000000000000dec876911cbe9428265af0d12132c52ee8642a9900000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000002449f865422000000000000000000000000e5d7c2a44ffddf6b295a15c148167daaaf5cf34f0000000000000000000000000000000e000000000000000000000000000000110000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000004400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000104e5b07cdb0000000000000000000000008e80016b025c89a6a270b399f5ebfb734be58ada00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000dec876911cbe9428265af0d12132c52ee8642a9900000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000002ee5d7c2a44ffddf6b295a15c148167daaaf5cf34f0000003aab2285ddcddad8edf438c1bab47e1a9d05a9b40000170000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000002449f865422000000000000000000000000e5d7c2a44ffddf6b295a15c148167daaaf5cf34f00000000000000000000000000000002000000000000000000000000000000030000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000004400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000104e5b07cdb000000000000000000000000f11bb479dc3daffe63989b6b95f6c119225dac2800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000dec876911cbe9428265af0d12132c52ee8642a9900000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000002ee5d7c2a44ffddf6b295a15c148167daaaf5cf34f0000fa3aab2285ddcddad8edf438c1bab47e1a9d05a9b400001e0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000002449f865422000000000000000000000000e5d7c2a44ffddf6b295a15c148167daaaf5cf34f00000000000000000000000000000001000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000004400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000104e5b07cdb000000000000000000000000a22206521a460aa6b21a089c3b48ffd0c79d5fd500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000dec876911cbe9428265af0d12132c52ee8642a9900000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000002ee5d7c2a44ffddf6b295a15c148167daaaf5cf34f0001f43aab2285ddcddad8edf438c1bab47e1a9d05a9b40000220000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000003e451a743160000000000000000000000003aab2285ddcddad8edf438c1bab47e1a9d05a9b400000000000000000000000000000001000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000038000000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000064d1660f990000000000000000000000003aab2285ddcddad8edf438c1bab47e1a9d05a9b4000000000000000000000000ed9e3f98bbed560e66b89aac922e29d4596a9642000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000ed9e3f98bbed560e66b89aac922e29d4596a964200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000c47dc203820000000000000000000000003aab2285ddcddad8edf438c1bab47e1a9d05a9b4000000000000000000000000a219439258ca9da29e9cc4ce5596924745e12b9300000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000dec876911cbe9428265af0d12132c52ee8642a99000000000000000000000000922164bbbd36acf9e854acbbf32facc949fcaeef0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000044000000000000000000000000000000000000000000000000000000000000004400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000648a6a1e85000000000000000000000000a219439258ca9da29e9cc4ce5596924745e12b93000000000000000000000000922164bbbd36acf9e854acbbf32facc949fcaeef000000000000000000000000000000000000000000000000000000003ba1163200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000001a49f865422000000000000000000000000a219439258ca9da29e9cc4ce5596924745e12b9300000000000000000000000000000001000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000004400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000064d1660f99000000000000000000000000a219439258ca9da29e9cc4ce5596924745e12b930000000000000000000000000a2854fbbd9b3ef66f17d47284e7f899b950933000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000046";

    bytes public constant API_DATA_NATIVE_TO_ERC20 =
        hex"5f575529000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000de0b6b3a764000000000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000000136b796265725377617046656544796e616d69630000000000000000000000000000000000000000000000000000000000000000000000000000000000000012600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a219439258ca9da29e9cc4ce5596924745e12b930000000000000000000000000000000000000000000000000dc1a09f859b2000000000000000000000000000000000000000000000000000000000009d7ae8560000000000000000000000000000000000000000000000000000000000000120000000000000000000000000000000000000000000000000001f161421c8e0000000000000000000000000001f3c3f0243d06a0353abcb066be9140747aeb8c900000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001124e21fd0e900000000000000000000000000000000000000000000000000000000000000200000000000000000000000000f4a1d7fdf4890be35e71f3e0bbc4a0ec377eca3000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000000000ca00000000000000000000000000000000000000000000000000000000000000ea00000000000000000000000000000000000000000000000000000000000000be0000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000c0000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee000000000000000000000000a219439258ca9da29e9cc4ce5596924745e12b930000000000000000000000000a2854fbbd9b3ef66f17d47284e7f899b95093300000000000000000000000000000000000000000000000000000000067b8a3780000000000000000000000000000000000000000000000000000000000000b800000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000640000000000000000000000000000000000000000000000000000000000000092000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000004063407a490000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000f4a1d7fdf4890be35e71f3e0bbc4a0ec377eca30000000000000000000000001947b87d35e9f1cd53cede1ad6f7be44c12212b8000000000000000000000000e5d7c2a44ffddf6b295a15c148167daaaf5cf34f000000000000000000000000a219439258ca9da29e9cc4ce5596924745e12b9300000000000000000000000000000000000000000000000000b014d4c6ae2800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000002e0000000000000000000000000000000000000000000000000000000000000004063407a490000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000f4a1d7fdf4890be35e71f3e0bbc4a0ec377eca3000000000000000000000000a22206521a460aa6b21a089c3b48ffd0c79d5fd5000000000000000000000000e5d7c2a44ffddf6b295a15c148167daaaf5cf34f0000000000000000000000003aab2285ddcddad8edf438c1bab47e1a9d05a9b400000000000000000000000000000000000000000000000002103e7e540a780000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000004048d318020000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000f4a1d7fdf4890be35e71f3e0bbc4a0ec377eca30000000000000000000000001d6cbd5ab95fcc04edde14abfa8d363adf4ead000000000000000000000000003aab2285ddcddad8edf438c1bab47e1a9d05a9b4000000000000000000000000176211869ca2b568f2a7d4ee941e073a821ee1ff0000000000000000000000000000000000000000000000000000000000065d7700000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004063407a490000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000f4a1d7fdf4890be35e71f3e0bbc4a0ec377eca30000000000000000000000005856edf9212bdcec74301ec78afc573b62d6a283000000000000000000000000176211869ca2b568f2a7d4ee941e073a821ee1ff000000000000000000000000a219439258ca9da29e9cc4ce5596924745e12b9300000000000000000000000000000000000000000000000000000000181b821c00000000000000000000000000000000000000000000000000000001000276a40000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000180000000000000000000000000000000000000000000000000000000000000004063407a490000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000f4a1d7fdf4890be35e71f3e0bbc4a0ec377eca3000000000000000000000000586733678b9ac9da43dd7cb83bbb41d23677dfc3000000000000000000000000e5d7c2a44ffddf6b295a15c148167daaaf5cf34f000000000000000000000000176211869ca2b568f2a7d4ee941e073a821ee1ff00000000000000000000000000000000000000000000000000b014d4c6ae280000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000004063407a490000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000f4a1d7fdf4890be35e71f3e0bbc4a0ec377eca3000000000000000000000000142ec7a60d2b339287c79969b1f3bfb1d81af27f000000000000000000000000176211869ca2b568f2a7d4ee941e073a821ee1ff000000000000000000000000a219439258ca9da29e9cc4ce5596924745e12b93000000000000000000000000000000000000000000000000000000000808a2b400000000000000000000000000000000000000000000000000000001000276a4000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000004048d318020000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000f4a1d7fdf4890be35e71f3e0bbc4a0ec377eca30000000000000000000000008611456f845293edd3f5788277f00f7c05ccc291000000000000000000000000e5d7c2a44ffddf6b295a15c148167daaaf5cf34f000000000000000000000000a219439258ca9da29e9cc4ce5596924745e12b930000000000000000000000000000000000000000000000000a513877a434580000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000a87000000000000000000000000a0b1a92a000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee000000000000000000000000a219439258ca9da29e9cc4ce5596924745e12b930000000000000000000000000000000000000000000000000000000000000160000000000000000000000000000000000000000000000000000000000000018000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000001c00000000000000000000000000a2854fbbd9b3ef66f17d47284e7f899b95093300000000000000000000000000000000000000000000000000dc1a09f859b2000000000000000000000000000000000000000000000000000000000009d7ae856000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001e00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002297b22536f75726365223a226d6574616d61736b222c22416d6f756e74496e555344223a22323730362e37323232353435353439313735222c22416d6f756e744f7574555344223a22323730362e36373337303135323137313633222c22526566657272616c223a22222c22466c616773223a302c22416d6f756e744f7574223a2232363935393937373337222c2254696d657374616d70223a313734303135323532302c22496e74656772697479496e666f223a7b224b65794944223a2231222c225369676e6174757265223a225a304e6b4170457455546b6f5a59586b4930396e3950616473515a6d50586b4c5433556e7a4b6b504d2b4e626a795957735454614b613358586e6e67686371422b57306d3353484b55776468446d51546a4a63375646554862417736316f4953384e73537952715037304c347645545a4b5566535567336f507663524449396b442f45325637565865626f413968385a3142385a70703148436a6c517a364a77434970617770723839746f642f486c79447245416f446a53716c65306c50684e36557767355758674755364e54624f7142794d69673870466f4a4f5a756662314738737a3841374878672b646a397455452f615343667738443847577744785778694942687858515645556568544e6c52737932447a3635576e39325a4b78646766536c4b7634314469675659494d4a68374662456c7a5750425a383639764b2b5255796f426153583130666e5a6d6e4743414a48413d3d227d7d00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000ff";

    bytes public constant API_DATA_ERC20_TO_NATIVE =
        hex"5f5755290000000000000000000000000000000000000000000000000000000000000080000000000000000000000000a219439258ca9da29e9cc4ce5596924745e12b93000000000000000000000000000000000000000000000000000000003b9aca0000000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000000136f70656e4f6365616e46656544796e616d6963000000000000000000000000000000000000000000000000000000000000000000000000000000000000001140000000000000000000000000a219439258ca9da29e9cc4ce5596924745e12b930000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003b9aca0000000000000000000000000000000000000000000000000004f388ae029a1c8d0000000000000000000000000000000000000000000000000000000000000120000000000000000000000000000000000000000000000000000b6acb789f1c6f0000000000000000000000001f3c3f0243d06a0353abcb066be9140747aeb8c90000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000100490411a32000000000000000000000000dec876911cbe9428265af0d12132c52ee8642a99000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000001c0000000000000000000000000a219439258ca9da29e9cc4ce5596924745e12b93000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee000000000000000000000000dec876911cbe9428265af0d12132c52ee8642a990000000000000000000000000a2854fbbd9b3ef66f17d47284e7f899b9509330000000000000000000000000000000000000000000000000000000003b9aca0000000000000000000000000000000000000000000000000004feb904c59c70bc0000000000000000000000000000000000000000000000000518d1b147081f720000000000000000000000000000000000000000000000000000000000000002000000000000000000000000ef53a4bd0e16ccc9116770a41c4bd3ad1147bd4f00000000000000000000000000000000000000000000000000000000000001400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000c00000000000000000000000000000000000000000000000000000000000000280000000000000000000000000000000000000000000000000000000000000058000000000000000000000000000000000000000000000000000000000000008800000000000000000000000000000000000000000000000000000000000000aa00000000000000000000000000000000000000000000000000000000000000bc000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000104e5b07cdb000000000000000000000000efd5ec2cc043e3bd3c840f7998cc42ee712700ba0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003b9aca00000000000000000000000000dec876911cbe9428265af0d12132c52ee8642a9900000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000002ea219439258ca9da29e9cc4ce5596924745e12b93000064176211869ca2b568f2a7d4ee941e073a821ee1ff00001e00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000002449f865422000000000000000000000000176211869ca2b568f2a7d4ee941e073a821ee1ff0000000000000000000000000000000f000000000000000000000000000000190000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000004400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000104e5b07cdb0000000000000000000000003cb104f044db23d6513f2a6100a1997fa5e3f58700000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001000000000000000000000000dec876911cbe9428265af0d12132c52ee8642a9900000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000002e176211869ca2b568f2a7d4ee941e073a821ee1ff000000e5d7c2a44ffddf6b295a15c148167daaaf5cf34f0000170000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000002449f865422000000000000000000000000176211869ca2b568f2a7d4ee941e073a821ee1ff00000000000000000000000000000001000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000004400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000104576188040000000000000000000000005615a7b1619980f7d6b5e7f69f3dc093dfe0c95c00000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001000000000000000000000000dec876911cbe9428265af0d12132c52ee8642a9900000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000003f45e5f26451cdb01b0fa1f8582e0aad9a6f27c218176211869ca2b568f2a7d4ee941e073a821ee1ff0001f4e5d7c2a44ffddf6b295a15c148167daaaf5cf34f000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000001649f865422000000000000000000000000e5d7c2a44ffddf6b295a15c148167daaaf5cf34f000000000000000000000000000000010000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000004000000000000000000000000e5d7c2a44ffddf6b295a15c148167daaaf5cf34f00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000242e1a7d4d00000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000648a6a1e85000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee000000000000000000000000922164bbbd36acf9e854acbbf32facc949fcaeef0000000000000000000000000000000000000000000000000518d1b147081f7200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000001a49f865422000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee00000000000000000000000000000001000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000004400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000064d1660f99000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee0000000000000000000000000a2854fbbd9b3ef66f17d47284e7f899b9509330000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000f5";

    function setUp() public override {
        vm.createSelectFork(vm.envString("LINEA_RPC_URL"), 16_100_581);

        super.setUp();
    }

    function test_canSwapByDelegationsInForkErc20ToErc20() public {
        (,, IERC20 tokenFrom_, IERC20 tokenTo_,,) = _setUpForkContracts(API_DATA_ERC20_TO_ERC20);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _getVaultDelegation();

        uint256 vaultTokenFromBalanceBefore_ = tokenFrom_.balanceOf(address(vault.deleGator));
        uint256 vaultTokenToBalanceBefore_ = tokenTo_.balanceOf(address(vault.deleGator));

        DelegationMetaSwapAdapter.SignatureData memory sigData_ = _buildSigData(API_DATA_ERC20_TO_ERC20);

        delegationMetaSwapAdapter.swapByDelegation(sigData_, delegations_);

        uint256 vaultTokenFromUsed_ = vaultTokenFromBalanceBefore_ - tokenFrom_.balanceOf(address(vault.deleGator));
        uint256 vaultTokenToObtained_ = tokenTo_.balanceOf(address(vault.deleGator)) - vaultTokenToBalanceBefore_;
        assertEq(vaultTokenFromUsed_, amountFrom, "Vault should spend the specified amount of tokenFrom");
        assertGe(vaultTokenToObtained_, amountTo, "Vault should receive the correct amount of tokenTo");
    }

    function test_canSwapByDelegationsInForkNativeTokenToErc20() public {
        (,,, IERC20 tokenTo_,,) = _setUpForkContracts(API_DATA_NATIVE_TO_ERC20);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _getVaultDelegation();

        uint256 vaultEthBalanceBefore = address(vault.deleGator).balance;
        uint256 vaultTokenBBalanceBefore = tokenTo_.balanceOf(address(vault.deleGator));
        DelegationMetaSwapAdapter.SignatureData memory sigData_ = _buildSigData(API_DATA_NATIVE_TO_ERC20);

        delegationMetaSwapAdapter.swapByDelegation(sigData_, delegations_);

        uint256 vaultEthUsed = vaultEthBalanceBefore - address(vault.deleGator).balance;
        uint256 vaultTokenBObtained = tokenB.balanceOf(address(vault.deleGator)) - vaultTokenBBalanceBefore;
        assertEq(vaultEthUsed, amountFrom, "Vault should spend the specified amount of ETH");
        assertGe(vaultTokenBObtained, amountTo, "Vault should receive the correct amount of tokenB");
    }

    function test_canSwapByDelegationsInForkErc20ToNativeToken() public {
        (,, IERC20 tokenFrom_,,,) = _setUpForkContracts(API_DATA_ERC20_TO_NATIVE);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _getVaultDelegation();

        uint256 vaultTokenFromBalanceBefore_ = tokenFrom_.balanceOf(address(vault.deleGator));
        uint256 vaultTokenToBalanceBefore_ = address(vault.deleGator).balance;
        DelegationMetaSwapAdapter.SignatureData memory sigData_ = _buildSigData(API_DATA_ERC20_TO_NATIVE);

        delegationMetaSwapAdapter.swapByDelegation(sigData_, delegations_);

        uint256 vaultTokenFromUsed_ = vaultTokenFromBalanceBefore_ - tokenFrom_.balanceOf(address(vault.deleGator));
        uint256 vaultTokenToObtained_ = address(vault.deleGator).balance - vaultTokenToBalanceBefore_;
        assertEq(vaultTokenFromUsed_, amountFrom, "Vault should spend the specified amount of token from");
        assertGe(vaultTokenToObtained_, amountTo, "Vault should receive the correct amount of tokenTo");
    }

    function _setUpForkContracts(bytes memory _apiData)
        private
        returns (
            string memory aggregatorId_,
            bytes memory swapData_,
            IERC20 tokenFrom_,
            IERC20 tokenTo_,
            uint256 amountFrom_,
            uint256 amountTo_
        )
    {
        entryPoint = ENTRY_POINT_FORK;
        delegationMetaSwapAdapter =
            new DelegationMetaSwapAdapter(owner, swapApiSignerAddress, DELEGATION_MANAGER_FORK, META_SWAP_FORK);
        delegationManager = DelegationManager(address(DELEGATION_MANAGER_FORK));
        hybridDeleGatorImpl = HYBRID_DELEGATOR_IMPL_FORK;

        users = _createUsers();
        vault = users.alice;

        (aggregatorId_, tokenFrom_, amountFrom_, swapData_) = _decodeApiData(_apiData);

        _whiteListCaller(address(this));

        (, tokenTo_,, amountTo_) = _decodeApiSwapData(swapData_);
        tokenA = BasicERC20(address(tokenFrom_));
        tokenB = BasicERC20(address(tokenTo_));
        amountFrom = amountFrom_;
        amountTo = amountTo_;

        _updateAllowedTokens();

        if (address(tokenFrom_) != address(0)) {
            deal(address(tokenFrom_), address(vault.deleGator), 1_000_000 ether);
        }

        return (aggregatorId_, swapData_, tokenFrom_, tokenTo_, amountFrom_, amountTo_);
    }
}

/**
 * @title MetaSwapMock
 * @notice A mock aggregator for testing. Swaps `tokenA` <-> `tokenB` at a 1:1 rate.
 */
contract MetaSwapMock {
    using SafeERC20 for IERC20;

    error InvalidValueTransfer();

    IERC20 public tokenA;
    IERC20 public tokenB;

    constructor(IERC20 _tokenA, IERC20 _tokenB) {
        tokenA = _tokenA;
        tokenB = _tokenB;
    }

    function swap(string calldata, IERC20 _tokenFrom, uint256 _amount, bytes calldata) external payable {
        require(_tokenFrom == tokenA || _tokenFrom == tokenB, "MetaSwapMock:invalid-token-from");

        if (address(_tokenFrom) != address(0)) {
            _tokenFrom.safeTransferFrom(msg.sender, address(this), _amount);
        }

        IERC20 tokenTo_ = _tokenFrom == tokenA ? tokenB : tokenA;

        if (address(tokenTo_) == address(0)) {
            (bool success_,) = msg.sender.call{ value: _amount }("");
            if (!success_) revert InvalidValueTransfer();
            require(success_, "MetaSwapMock:invalid-value-transfer");
        } else {
            tokenTo_.safeTransfer(msg.sender, _amount);
        }
    }
}

contract DelegationMetaSwapAdapterSignatureTest is DelegationMetaSwapAdapter {
    constructor(
        address _owner,
        address _swapApiSigner,
        address _delegationManager,
        address _metaSwap
    )
        DelegationMetaSwapAdapter(_owner, _swapApiSigner, IDelegationManager(_delegationManager), IMetaSwap(_metaSwap))
    { }

    function exposedValidateSignature(SignatureData memory _signatureData) public view {
        _validateSignature(_signatureData);
    }
}
