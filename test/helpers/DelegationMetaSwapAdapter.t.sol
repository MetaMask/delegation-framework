// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import { BasicERC20 } from "../utils/BasicERC20.t.sol";
import { BaseTest } from "../utils/BaseTest.t.sol";
import { DelegationMetaSwapAdapter } from "../../src/helpers/DelegationMetaSwapAdapter.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";
import { Implementation, SignatureType, TestUser } from "../utils/Types.t.sol";
import { Delegation, Caveat } from "../../src/utils/Types.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";
import { IMetaSwap } from "../../src/helpers/interfaces/IMetaSwap.sol";
import { AllowedTargetsEnforcer } from "../../src/enforcers/AllowedTargetsEnforcer.sol";
import { AllowedCalldataEnforcer } from "../../src/enforcers/AllowedCalldataEnforcer.sol";
import { AllowedMethodsEnforcer } from "../../src/enforcers/AllowedMethodsEnforcer.sol";
import { ValueLteEnforcer } from "../../src/enforcers/ValueLteEnforcer.sol";
import { RedeemerEnforcer } from "../../src/enforcers/RedeemerEnforcer.sol";
import { ArgsEqualityCheckEnforcer } from "../../src/enforcers/ArgsEqualityCheckEnforcer.sol";
import { BytesLib } from "@bytes-utils/BytesLib.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { DelegationManager } from "../../src/DelegationManager.sol";
import { HybridDeleGator } from "../../src/HybridDeleGator.sol";
import { EntryPoint } from "@account-abstraction/core/EntryPoint.sol";
import { CALLTYPE_SINGLE, CALLTYPE_BATCH, EXECTYPE_DEFAULT, EXECTYPE_TRY } from "../../src/utils/Constants.sol";

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
    TestUser public subVault;
    AllowedCalldataEnforcer public allowedCalldataEnforcer;
    AllowedTargetsEnforcer public allowedTargetsEnforcer;
    AllowedMethodsEnforcer public allowedMethodsEnforcer;
    ValueLteEnforcer public valueLteEnforcer;
    ArgsEqualityCheckEnforcer public argsEqualityCheckEnforcer;

    RedeemerEnforcer public redeemerEnforcer;
    bytes public swapDataTokenAtoTokenB;

    string public constant WHITELIST_ENFORCED = "Token-Whitelist-Enforced";
    string public constant WHITELIST_NOT_ENFORCED = "Token-Whitelist-Not-Enforced";
    bytes public argsEqualityEnforcerTerms = abi.encode(WHITELIST_ENFORCED);

    uint256 public swapSignerPrivateKey;
    address public swapApiSignerAddress;

    //////////////////////// Constructor & Setup ////////////////////////

    constructor() {
        IMPLEMENTATION = Implementation.Hybrid;
        SIGNATURE_TYPE = SignatureType.RawP256;
    }

    function setUp() public virtual override {
        // Common setup for both mock and fork tests
        super.setUp();
        allowedCalldataEnforcer = new AllowedCalldataEnforcer();
        allowedTargetsEnforcer = new AllowedTargetsEnforcer();
        allowedMethodsEnforcer = new AllowedMethodsEnforcer();
        valueLteEnforcer = new ValueLteEnforcer();
        redeemerEnforcer = new RedeemerEnforcer();
        argsEqualityCheckEnforcer = new ArgsEqualityCheckEnforcer();

        (swapApiSignerAddress, swapSignerPrivateKey) = makeAddrAndKey("SWAP_API");
    }

    //////////////////////// Internal / Private Helpers ////////////////////////

    /**
     * @dev Generates a valid signature for _apiData with a given _expiration.
     */
    function _getValidSignature(bytes memory _apiData, uint256 _expiration) internal returns (bytes memory) {
        bytes32 messageHash = keccak256(abi.encode(_apiData, _expiration));
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(swapSignerPrivateKey, ethSignedMessageHash);
        return abi.encodePacked(r, s, v);
    }

    /**
     * @dev Builds and returns a SignatureData struct from the given apiData.
     */
    function _buildSigData(bytes memory apiData) internal returns (DelegationMetaSwapAdapter.SignatureData memory) {
        uint256 expiration = block.timestamp + 1000;
        bytes memory signature = _getValidSignature(apiData, expiration);
        return DelegationMetaSwapAdapter.SignatureData({ apiData: apiData, expiration: expiration, signature: signature });
    }

    /**
     * @dev Internal helper to decode aggregator data from `apiData`.
     *      Typically used in fork-based tests.
     * @param _apiData Bytes that includes aggregatorId, tokenFrom, amountFrom, and the aggregator swap data.
     */
    function _decodeApiData(bytes memory _apiData)
        internal
        pure
        returns (string memory aggregatorId_, IERC20 tokenFrom_, uint256 amountFrom_, bytes memory swapData_)
    {
        // Excluding the function selector
        bytes memory parameterTerms_ = BytesLib.slice(_apiData, 4, _apiData.length - 4);
        (aggregatorId_, tokenFrom_, amountFrom_, swapData_) = abi.decode(parameterTerms_, (string, IERC20, uint256, bytes));
    }

    /**
     * @dev Decodes the "swap data" for aggregator usage into tokens and amounts.
     */
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

    /**
     * @dev Encodes api data for local mocking.
     */
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

    /**
     * @dev Encodes swap data for local mocking. The aggregator would decode these fields (token addresses, amounts, etc.).
     */
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

    function _getCaveatsVaultDelegationNativeToken() private view returns (Caveat[] memory) {
        Caveat[] memory caveats_ = new Caveat[](3);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(argsEqualityCheckEnforcer), terms: argsEqualityEnforcerTerms });

        caveats_[1] = Caveat({ args: hex"", enforcer: address(valueLteEnforcer), terms: abi.encode(uint256(10 ether)) });

        caveats_[2] = Caveat({
            args: hex"",
            enforcer: address(redeemerEnforcer),
            terms: abi.encodePacked(address(delegationMetaSwapAdapter))
        });
        return caveats_;
    }

    function _getCaveatsVaultDelegationErc20() private view returns (Caveat[] memory) {
        Caveat[] memory caveats_ = new Caveat[](5);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(argsEqualityCheckEnforcer), terms: argsEqualityEnforcerTerms });

        caveats_[1] = Caveat({ args: hex"", enforcer: address(allowedTargetsEnforcer), terms: abi.encodePacked(address(tokenA)) });

        caveats_[2] =
            Caveat({ args: hex"", enforcer: address(allowedMethodsEnforcer), terms: abi.encodePacked(IERC20.transfer.selector) });

        uint256 paramStart_ = abi.encodeWithSelector(IERC20.transfer.selector).length;
        address paramValue_ = address(delegationMetaSwapAdapter);
        // The param start and and param value are packed together, but the param value is not packed.
        bytes memory inputTerms_ = abi.encodePacked(paramStart_, bytes32(uint256(uint160(paramValue_))));
        caveats_[3] = Caveat({ args: hex"", enforcer: address(allowedCalldataEnforcer), terms: inputTerms_ });

        caveats_[4] = Caveat({
            args: hex"",
            enforcer: address(redeemerEnforcer),
            terms: abi.encodePacked(address(delegationMetaSwapAdapter))
        });
        return caveats_;
    }

    /**
     * @dev Builds a Delegation struct representing `vault` delegating to `subVault`.
     */
    function _getVaultDelegation() internal view returns (Delegation memory) {
        Caveat[] memory caveats_ =
            address(tokenA) == address(0) ? _getCaveatsVaultDelegationNativeToken() : _getCaveatsVaultDelegationErc20();

        Delegation memory vaultDelegation_ = Delegation({
            delegate: address(subVault.deleGator),
            delegator: address(vault.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        return signDelegation(vault, vaultDelegation_);
    }

    /**
     * @dev Builds a Delegation struct representing `subVault` delegating to `delegationMetaSwapAdapter` with certain restrictions.
     * @param _parentDelegationHash The hash of the parent delegation.
     */
    function _getSubVaultDelegation(bytes32 _parentDelegationHash) internal view returns (Delegation memory) {
        Caveat[] memory caveats_ = new Caveat[](1);

        if (address(tokenA) == address(0)) {
            // Using native token as tokenFrom
            bytes memory inputTerms_ = abi.encodePacked(address(delegationMetaSwapAdapter));
            caveats_[0] = Caveat({ args: hex"", enforcer: address(allowedTargetsEnforcer), terms: inputTerms_ });
        } else {
            // Using ERC20 as tokenFrom
            // Restricts the amount of tokens per call
            uint256 paramStart_ = abi.encodeWithSelector(IERC20.transfer.selector, address(0)).length;
            uint256 paramValue_ = amountFrom;
            bytes memory inputTerms_ = abi.encodePacked(paramStart_, paramValue_);
            caveats_[0] = Caveat({ args: hex"", enforcer: address(allowedCalldataEnforcer), terms: inputTerms_ });
        }

        Delegation memory subVaultDelegation_ = Delegation({
            delegate: address(delegationMetaSwapAdapter),
            delegator: address(subVault.deleGator),
            authority: _parentDelegationHash,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        return signDelegation(subVault, subVaultDelegation_);
    }

    /**
     * @dev Edits the allowed tokens for DelegationMetaSwapAdapter, whitelisting tokenA and tokenB.
     */
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

    /**
     * @dev Whitelists an aggregator ID string so DelegationMetaSwapAdapter can use it.
     * @param _aggregatorId The aggregator ID string
     */
    function _whiteListAggregatorId(string memory _aggregatorId) internal {
        string[] memory aggregatorIds_ = new string[](1);
        aggregatorIds_[0] = _aggregatorId;
        bool[] memory statuses_ = new bool[](1);
        statuses_[0] = true;

        vm.prank(owner);
        delegationMetaSwapAdapter.updateAllowedAggregatorIds(aggregatorIds_, statuses_);
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
        adapter =
            new DelegationMetaSwapAdapterSignatureTest(address(this), swapApiSigner, address(0x123), address(0x456), address(0x789));
    }

    ////////////////////////////// Signature validation tests //////////////////////////////

    /**
     * @notice Verifies that a valid signature is accepted.
     */
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

    /**
     * @notice Verifies that an expired signature is rejected.
     */
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

    /**
     * @notice Verifies that an invalid signature is rejected.
     */
    function test_validateSignature_invalidSigner() public {
        bytes memory apiData = hex"1234";
        uint256 expiration = block.timestamp + 1 hours;
        bytes32 messageHash = keccak256(abi.encode(apiData, expiration));
        // Use a different private key to generate an invalid signature
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_swapSignerPrivateKey + 1, messageHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        DelegationMetaSwapAdapter.SignatureData memory sigData =
            DelegationMetaSwapAdapter.SignatureData({ apiData: apiData, expiration: expiration, signature: signature });

        vm.expectRevert(DelegationMetaSwapAdapter.InvalidApiSignature.selector);
        adapter.exposedValidateSignature(sigData);
    }

    /**
     * @notice Verifies that an empty signature is rejected.
     */
    function test_validateSignature_emptySignature() public {
        bytes memory apiData = hex"1234";
        uint256 expiration = block.timestamp + 1 hours;
        bytes memory emptySignature = "";

        DelegationMetaSwapAdapter.SignatureData memory sigData =
            DelegationMetaSwapAdapter.SignatureData({ apiData: apiData, expiration: expiration, signature: emptySignature });

        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, 0));
        adapter.exposedValidateSignature(sigData);
    }

    /**
     * @notice Verifies that a hardcoded valid signature works
     */
    function test_validateSignature_hardcodedSignature() public {
        // Taken from the swaps api
        address swapApiSigner_ = 0x533FbF047Ed13C20e263e2576e41c747206d1348;

        vm.prank(address(this));
        adapter.setSwapApiSigner(swapApiSigner_);

        bytes memory apiData_ =
            hex"5f5755290000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000470de4df82000000000000000000000000000000000000000000000000000000000000000000c0000000000000000000000000000000000000000000000000000000000000001c616972737761704c696768743446656544796e616d696346697865640000000000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000196652ed3350000000000000000000000000000000000000000000000000000000068098586000000000000000000000000111bb8c3542f2b92fb41b8d913c01d37884311110000000000000000000000006b175474e89094c44da98b954eedeac495271d0f000000000000000000000000000000000000000000000001eb87e2999f2f8380000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000466ebb82ac1000000000000000000000000000000000000000000000000000000000000000001c427cdd17278850f9344bb9b4940a6ce83afbb34b58410cdcdf1ff8b27ea8b7eb338693a44fa8d73a0878779e2f6b41c6af69f42510d98f1bfd19d7675e1b3a9d00000000000000000000000000000000000000000000000000009f295cd5f000000000000000000000000000f326e4de8f66a0bdc0970b79e0924e33c79f19150000000000000000000000000000000000000000000000000000000000000000007f";
        uint256 expiration_ = 1745454591251;

        // This signature was generated with the test private key for the above data and expiration
        bytes memory signature =
            hex"fccc4800a4a9d9aa6a8cf933ca759f3974d8eed02e47b12a739601ef1e83617a08c7597d0dd875f955511248da6cf4cfb92be67c0d7241104c061a3c4d45f3b51b";

        DelegationMetaSwapAdapter.SignatureData memory sigData_ =
            DelegationMetaSwapAdapter.SignatureData({ apiData: apiData_, expiration: expiration_, signature: signature });

        // Should not revert since signature is valid
        adapter.exposedValidateSignature(sigData_);
    }

    ////////////////////////////// Swap tests //////////////////////////////

    /**
     * @notice Verifies that the contract reverts when the zero address is used as an input.
     */
    function test_revert_invalidZeroAddressInConstructor() public {
        address owner_ = address(1);
        address swapApiSigner_ = address(1);
        IDelegationManager delegationManager_ = IDelegationManager(address(1));
        IMetaSwap metaSwap_ = IMetaSwap(address(1));
        address argsEqualityCheckEnforcer_ = address(1);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new DelegationMetaSwapAdapter(address(0), swapApiSigner_, delegationManager_, metaSwap_, argsEqualityCheckEnforcer_);

        vm.expectRevert(DelegationMetaSwapAdapter.InvalidZeroAddress.selector);
        new DelegationMetaSwapAdapter(owner_, address(0), delegationManager_, metaSwap_, argsEqualityCheckEnforcer_);

        vm.expectRevert(DelegationMetaSwapAdapter.InvalidZeroAddress.selector);
        new DelegationMetaSwapAdapter(owner_, swapApiSigner_, IDelegationManager(address(0)), metaSwap_, argsEqualityCheckEnforcer_);

        vm.expectRevert(DelegationMetaSwapAdapter.InvalidZeroAddress.selector);
        new DelegationMetaSwapAdapter(owner_, swapApiSigner_, delegationManager_, IMetaSwap(address(0)), argsEqualityCheckEnforcer_);

        vm.expectRevert(DelegationMetaSwapAdapter.InvalidZeroAddress.selector);
        new DelegationMetaSwapAdapter(owner_, swapApiSigner_, delegationManager_, metaSwap_, address(0));
    }

    /**
     * @notice Verifies that tokens can be swapped by delegations in a purely local environment (using a MetaSwapMock).
     */
    function test_canSwapByDelegationsMockErc20TokenFrom() public {
        _setUpMockContracts();

        Delegation[] memory delegations_ = new Delegation[](2);

        Delegation memory vaultDelegation_ = _getVaultDelegation();
        Delegation memory subVaultDelegation_ = _getSubVaultDelegation(EncoderLib._getDelegationHash(vaultDelegation_));
        delegations_[1] = vaultDelegation_;
        delegations_[0] = subVaultDelegation_;

        uint256 vaultTokenABalanceBefore_ = tokenA.balanceOf(address(vault.deleGator));
        uint256 vaultTokenBBalanceBefore_ = tokenB.balanceOf(address(vault.deleGator));

        bytes memory swapData_ = _encodeSwapData(IERC20(tokenA), IERC20(tokenB), amountFrom, amountTo, hex"", 0, address(0), false);
        bytes memory apiData_ = _encodeApiData(aggregatorId, IERC20(tokenA), amountFrom, swapData_);
        DelegationMetaSwapAdapter.SignatureData memory sigData_ = _buildSigData(apiData_);

        vm.prank(address(subVault.deleGator));
        delegationMetaSwapAdapter.swapByDelegation(sigData_, delegations_, true);

        uint256 vaultTokenAUsed_ = vaultTokenABalanceBefore_ - tokenA.balanceOf(address(vault.deleGator));
        uint256 vaultTokenBObtained_ = tokenB.balanceOf(address(vault.deleGator)) - vaultTokenBBalanceBefore_;
        assertEq(vaultTokenAUsed_, amountFrom, "Vault should spend the specified amount of tokenA");
        assertEq(vaultTokenBObtained_, amountTo, "Vault should receive the correct amount of tokenB");
    }

    /**
     * @notice Verifies that native token (ETH) can be used as the tokenFrom in a delegation-based swap.
     * In this test, tokenA is set to ETH (address(0)) while tokenB remains an ERC20.
     */
    function test_canSwapByDelegationsMockNativeTokenFrom() public {
        // Set up contracts: use native token for tokenA (tokenFrom), ERC20 for tokenB.
        _setUpMockContractsEth(true, false);

        // Build the delegation chain as in the ERC20 test.
        Delegation[] memory delegations_ = new Delegation[](2);

        Delegation memory vaultDelegation_ = _getVaultDelegation();
        Delegation memory subVaultDelegation_ = _getSubVaultDelegation(EncoderLib._getDelegationHash(vaultDelegation_));
        delegations_[1] = vaultDelegation_;
        delegations_[0] = subVaultDelegation_;

        // Record vault's ETH and tokenB balances before swap.
        uint256 vaultEthBalanceBefore = address(vault.deleGator).balance;
        uint256 vaultTokenBBalanceBefore = tokenB.balanceOf(address(vault.deleGator));

        // Prepare the swapData – note that tokenA is ETH (address(0))
        bytes memory swapData_ = _encodeSwapData(IERC20(tokenA), IERC20(tokenB), amountFrom, amountTo, hex"", 0, address(0), true);
        bytes memory apiData_ = _encodeApiData(aggregatorId, IERC20(tokenA), amountFrom, swapData_);
        DelegationMetaSwapAdapter.SignatureData memory sigData_ = _buildSigData(apiData_);

        vm.prank(address(subVault.deleGator));
        delegationMetaSwapAdapter.swapByDelegation(sigData_, delegations_, true);

        // Calculate the change in balances.
        uint256 vaultEthUsed = vaultEthBalanceBefore - address(vault.deleGator).balance;
        uint256 vaultTokenBObtained = tokenB.balanceOf(address(vault.deleGator)) - vaultTokenBBalanceBefore;
        assertEq(vaultEthUsed, amountFrom, "Vault should spend the specified amount of ETH");
        assertEq(vaultTokenBObtained, amountTo, "Vault should receive the correct amount of tokenB");
    }

    /**
     * @notice Verifies that native token (ETH) can be used as the tokenTo in a delegation-based swap.
     * In this test, tokenB is set to ETH (address(0)) while tokenA remains an ERC20.
     */
    function test_canSwapByDelegationsMockNativeTo() public {
        // Set up contracts: use ERC20 for tokenA and native token for tokenB.
        _setUpMockContractsEth(false, true);

        // Build the delegation chain.
        Delegation[] memory delegations_ = new Delegation[](2);

        Delegation memory vaultDelegation_ = _getVaultDelegation();
        Delegation memory subVaultDelegation_ = _getSubVaultDelegation(EncoderLib._getDelegationHash(vaultDelegation_));
        delegations_[1] = vaultDelegation_;
        delegations_[0] = subVaultDelegation_;

        // Record vault's tokenA balance and ETH balance before swap.
        uint256 vaultTokenABalanceBefore = tokenA.balanceOf(address(vault.deleGator));
        uint256 vaultEthBalanceBefore = address(vault.deleGator).balance;

        // Prepare the swapData – tokenTo is now ETH (address(0)). Note that _feeTo is false.
        bytes memory swapData_ = _encodeSwapData(IERC20(tokenA), IERC20(tokenB), amountFrom, amountTo, hex"", 0, address(0), false);
        bytes memory apiData_ = _encodeApiData(aggregatorId, IERC20(tokenA), amountFrom, swapData_);
        DelegationMetaSwapAdapter.SignatureData memory sigData_ = _buildSigData(apiData_);

        vm.prank(address(subVault.deleGator));
        delegationMetaSwapAdapter.swapByDelegation(sigData_, delegations_, true);

        // Calculate the change in balances.
        uint256 vaultTokenAUsed = vaultTokenABalanceBefore - tokenA.balanceOf(address(vault.deleGator));
        uint256 vaultEthObtained = address(vault.deleGator).balance - vaultEthBalanceBefore;
        assertEq(vaultTokenAUsed, amountFrom, "Vault should spend the specified amount of tokenA");
        assertEq(vaultEthObtained, amountTo, "Vault should receive the correct amount of ETH");
    }

    // When _useTokenWhitelist is false, token whitelist checks are skipped.
    // In this test, we first mark tokenA and tokenB as NOT allowed (so they would fail if checked)
    // but the swap should succeed when _useTokenWhitelist is false.
    function test_canSwapByDelegationsMock_withNoTokenWhitelist() public {
        _setUpMockContracts();
        // Update allowed tokens: disable both tokens.
        IERC20[] memory tokens_ = new IERC20[](2);
        tokens_[0] = IERC20(tokenA);
        tokens_[1] = IERC20(tokenB);
        bool[] memory statuses_ = new bool[](2);
        statuses_[0] = false;
        statuses_[1] = false;
        vm.prank(owner);
        delegationMetaSwapAdapter.updateAllowedTokens(tokens_, statuses_);
        assertFalse(delegationMetaSwapAdapter.isTokenAllowed(tokenA), "TokenA should be disabled");
        assertFalse(delegationMetaSwapAdapter.isTokenAllowed(tokenB), "TokenB should be disabled");

        // Setting the args enforcer terms to skip the token whitelist
        argsEqualityEnforcerTerms = abi.encode(WHITELIST_NOT_ENFORCED);

        // Build a valid delegation chain (which includes the argsEqualityCheckEnforcer in the first caveat).
        Delegation[] memory delegations_ = new Delegation[](2);
        Delegation memory vaultDelegation_ = _getVaultDelegation();
        Delegation memory subVaultDelegation_ = _getSubVaultDelegation(EncoderLib._getDelegationHash(vaultDelegation_));
        delegations_[1] = vaultDelegation_;
        delegations_[0] = subVaultDelegation_;

        uint256 vaultTokenABalanceBefore_ = tokenA.balanceOf(address(vault.deleGator));
        uint256 vaultTokenBBalanceBefore_ = tokenB.balanceOf(address(vault.deleGator));

        bytes memory swapData_ = _encodeSwapData(IERC20(tokenA), IERC20(tokenB), amountFrom, amountTo, hex"", 0, address(0), true);
        bytes memory apiData_ = _encodeApiData(aggregatorId, IERC20(tokenA), amountFrom, swapData_);

        // Call swapByDelegation with _useTokenWhitelist set to false.
        // Since whitelist checks are skipped, the swap should proceed even though tokenA and tokenB are not allowed.
        DelegationMetaSwapAdapter.SignatureData memory sigData_ = _buildSigData(apiData_);
        vm.prank(address(subVault.deleGator));
        delegationMetaSwapAdapter.swapByDelegation(sigData_, delegations_, false);

        uint256 vaultTokenAUsed_ = vaultTokenABalanceBefore_ - tokenA.balanceOf(address(vault.deleGator));
        uint256 vaultTokenBObtained_ = tokenB.balanceOf(address(vault.deleGator)) - vaultTokenBBalanceBefore_;
        assertEq(vaultTokenAUsed_, amountFrom, "Vault should spend the specified amount of tokenA");
        assertEq(vaultTokenBObtained_, amountTo, "Vault should receive the correct amount of tokenB");
    }

    // The redeemer tries to swapByDelegation passing a flag different from what the delegator indicated
    function test_revert_swapByDelegationsMock_withNoTokenWhitelistAndIncorrectArgs() public {
        _setUpMockContracts();
        // Update allowed tokens: disable both tokens.
        IERC20[] memory tokens_ = new IERC20[](2);
        tokens_[0] = IERC20(tokenA);
        tokens_[1] = IERC20(tokenB);
        bool[] memory statuses_ = new bool[](2);
        statuses_[0] = false;
        statuses_[1] = false;
        vm.prank(owner);
        delegationMetaSwapAdapter.updateAllowedTokens(tokens_, statuses_);

        // Build a valid delegation chain (which includes the argsEqualityCheckEnforcer in the first caveat).
        // The args indicate to use the token whitelist but the function the flag is set to not use the whitelist
        // the difference between the expected and obtained args reverts
        Delegation[] memory delegations_ = new Delegation[](2);
        Delegation memory vaultDelegation_ = _getVaultDelegation();
        Delegation memory subVaultDelegation_ = _getSubVaultDelegation(EncoderLib._getDelegationHash(vaultDelegation_));
        delegations_[1] = vaultDelegation_;
        delegations_[0] = subVaultDelegation_;

        bytes memory swapData_ = _encodeSwapData(IERC20(tokenA), IERC20(tokenB), amountFrom, amountTo, hex"", 0, address(0), true);
        bytes memory apiData_ = _encodeApiData(aggregatorId, IERC20(tokenA), amountFrom, swapData_);
        DelegationMetaSwapAdapter.SignatureData memory sigData_ = _buildSigData(apiData_);

        // Call swapByDelegation with _useTokenWhitelist set to false.
        vm.prank(address(subVault.deleGator));

        vm.expectRevert("ArgsEqualityCheckEnforcer:different-args-and-terms");
        delegationMetaSwapAdapter.swapByDelegation(sigData_, delegations_, false);
    }

    /// @notice Verifies that only the current owner can initiate ownership transfer.
    function test_revert_transferOwnership_ifNotOwner() public {
        _setUpMockContracts();

        address newOwner_ = makeAddr("NewOwner");
        vm.startPrank(address(subVault.deleGator));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(subVault.deleGator)));
        delegationMetaSwapAdapter.transferOwnership(newOwner_);
        vm.stopPrank();
    }

    /// @notice Verifies that the owner can successfully transfer ownership in two steps.
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

    /// @notice Verifies that only the pending owner can accept ownership after transferOwnership.
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

    /// @notice Verifies that the contract owner can edit allowed tokens and the correct changes are applied.
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

    /// @notice Verifies that non-owners cannot call updateAllowedTokens.
    function test_revert_updateAllowedTokens_ifNotOwner() public {
        _setUpMockContracts();

        IERC20[] memory tokens_ = new IERC20[](1);
        tokens_[0] = IERC20(tokenA);

        bool[] memory statuses_ = new bool[](1);
        statuses_[0] = false;

        vm.startPrank(address(subVault.deleGator));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(subVault.deleGator)));
        delegationMetaSwapAdapter.updateAllowedTokens(tokens_, statuses_);
        vm.stopPrank();
    }

    /// @notice Verifies that updateAllowedTokens reverts if array lengths mismatch.
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

    /// @notice Verifies that the contract owner can update allowed aggregator IDs and the correct changes are applied.
    function test_canUpdateAllowedAggregatorIds() public {
        _setUpMockContracts();

        string[] memory aggregatorIds_ = new string[](2);
        aggregatorIds_[0] = "1";
        aggregatorIds_[1] = "2";

        bool[] memory statuses_ = new bool[](2);
        statuses_[0] = false;
        statuses_[1] = true;

        vm.startPrank(owner);
        delegationMetaSwapAdapter.updateAllowedAggregatorIds(aggregatorIds_, statuses_);
        vm.stopPrank();

        bytes32 aggregator1Hash_ = keccak256(abi.encode("1"));
        bytes32 aggregator2Hash_ = keccak256(abi.encode("2"));
        assertFalse(delegationMetaSwapAdapter.isAggregatorAllowed(aggregator1Hash_));
        assertTrue(delegationMetaSwapAdapter.isAggregatorAllowed(aggregator2Hash_));
    }

    /// @notice Verifies that non-owners cannot call updateAllowedAggregatorIds.
    function test_revert_updateAllowedAggregatorIds_ifNotOwner() public {
        _setUpMockContracts();

        string[] memory aggregatorIds_ = new string[](1);
        aggregatorIds_[0] = "randomId";
        bool[] memory statuses_ = new bool[](1);
        statuses_[0] = true;

        vm.startPrank(address(subVault.deleGator));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(subVault.deleGator)));
        delegationMetaSwapAdapter.updateAllowedAggregatorIds(aggregatorIds_, statuses_);
        vm.stopPrank();
    }

    /// @notice Verifies that updateAllowedAggregatorIds reverts if array lengths mismatch.
    function test_revert_updateAllowedAggregatorIds_arrayLengthMismatch() public {
        _setUpMockContracts();

        string[] memory aggregatorIds_ = new string[](2);
        aggregatorIds_[0] = "A1";
        aggregatorIds_[1] = "A2";

        bool[] memory statuses_ = new bool[](1);
        statuses_[0] = true;

        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(DelegationMetaSwapAdapter.InputLengthsMismatch.selector));
        delegationMetaSwapAdapter.updateAllowedAggregatorIds(aggregatorIds_, statuses_);
        vm.stopPrank();
    }

    /// @notice Ensures that calling `swapTokens` externally reverts with `NotSelf()`.
    function test_revert_swapTokens_ifNotSelf() public {
        _setUpMockContracts();
        vm.startPrank(address(subVault.deleGator));
        vm.expectRevert(DelegationMetaSwapAdapter.NotSelf.selector);
        delegationMetaSwapAdapter.swapTokens("test-aggregator-id", tokenA, tokenB, address(vault.deleGator), 1 ether, 0, hex"");
        vm.stopPrank();
    }

    // @notice Tests the onlyDelegationManager modifier in executeFromExecutor
    function test_revert_executeFromExecutor_ifNotDelegationManager() public {
        _setUpMockContracts();
        vm.startPrank(address(subVault.deleGator));
        vm.expectRevert(DelegationMetaSwapAdapter.NotDelegationManager.selector);
        delegationMetaSwapAdapter.executeFromExecutor(singleDefaultMode, hex"");
        vm.stopPrank();
    }

    // Test that swapByDelegation reverts when the delegations array is empty.
    function test_revert_swapByDelegation_emptyDelegations() public {
        _setUpMockContracts();
        bytes memory apiData_ = _encodeApiData(aggregatorId, IERC20(tokenA), amountFrom, swapDataTokenAtoTokenB);
        Delegation[] memory emptyDelegations_ = new Delegation[](0);
        DelegationMetaSwapAdapter.SignatureData memory sigData_ = _buildSigData(apiData_);

        vm.prank(address(subVault.deleGator));
        vm.expectRevert(DelegationMetaSwapAdapter.InvalidEmptyDelegations.selector);
        delegationMetaSwapAdapter.swapByDelegation(sigData_, emptyDelegations_, true);
    }

    // Test that swapByDelegation reverts when called from a non-leaf delegator
    function test_revert_swapByDelegation_nonLeafDelegator() public {
        _setUpMockContracts();
        bytes memory apiData_ = _encodeApiData(aggregatorId, IERC20(tokenA), amountFrom, swapDataTokenAtoTokenB);
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(argsEqualityCheckEnforcer), terms: argsEqualityEnforcerTerms });

        Delegation memory delegation_ = Delegation({
            delegate: address(delegationMetaSwapAdapter),
            delegator: address(vault.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        delegation_ = signDelegation(vault, delegation_);
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;
        DelegationMetaSwapAdapter.SignatureData memory sigData_ = _buildSigData(apiData_);

        // Using invalid caller, must be the vault not subVault
        vm.prank(address(subVault.deleGator));
        vm.expectRevert(DelegationMetaSwapAdapter.NotLeafDelegator.selector);
        delegationMetaSwapAdapter.swapByDelegation(sigData_, delegations_, true);
    }

    // Test that swapByDelegation reverts if tokenFrom equals tokenTo.
    function test_revert_swapByDelegation_identicalTokens() public {
        _setUpMockContracts();
        // Create swapData with identical tokens.
        bytes memory swapDataIdentical_ =
            _encodeSwapData(IERC20(tokenA), IERC20(tokenA), amountFrom, amountTo, hex"", 0, address(0), true);
        bytes memory apiData_ = _encodeApiData(aggregatorId, IERC20(tokenA), amountFrom, swapDataIdentical_);
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _getVaultDelegation();
        DelegationMetaSwapAdapter.SignatureData memory sigData_ = _buildSigData(apiData_);

        vm.prank(address(subVault.deleGator));
        vm.expectRevert(DelegationMetaSwapAdapter.InvalidIdenticalTokens.selector);
        delegationMetaSwapAdapter.swapByDelegation(sigData_, delegations_, true);
    }

    // Test that swapByDelegation reverts if tokenFrom is not allowed.
    function test_revert_swapByDelegation_tokenFromNotAllowed() public {
        _setUpMockContracts();
        // Remove tokenA from allowed tokens.
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

        vm.prank(address(subVault.deleGator));
        vm.expectRevert(abi.encodeWithSelector(DelegationMetaSwapAdapter.TokenFromIsNotAllowed.selector, tokenA));
        delegationMetaSwapAdapter.swapByDelegation(sigData_, delegations_, true);
    }

    // Test that swapByDelegation reverts if tokenTo is not allowed.
    function test_revert_swapByDelegation_tokenToNotAllowed() public {
        _setUpMockContracts();
        // Remove tokenB from allowed tokens.
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

        vm.prank(address(subVault.deleGator));
        vm.expectRevert(abi.encodeWithSelector(DelegationMetaSwapAdapter.TokenToIsNotAllowed.selector, tokenB));
        delegationMetaSwapAdapter.swapByDelegation(sigData_, delegations_, true);
    }

    // Test that swapByDelegation reverts if the aggregator ID is not allowed.
    function test_revert_swapByDelegation_aggregatorIdNotAllowed() public {
        _setUpMockContracts();
        // Remove aggregatorId from the allowed list.
        string[] memory aggregatorIds_ = new string[](1);
        aggregatorIds_[0] = aggregatorId;
        bool[] memory statuses = new bool[](1);
        statuses[0] = false;
        vm.prank(owner);
        delegationMetaSwapAdapter.updateAllowedAggregatorIds(aggregatorIds_, statuses);

        bytes memory apiData_ = _encodeApiData(aggregatorId, IERC20(tokenA), amountFrom, swapDataTokenAtoTokenB);
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _getVaultDelegation();

        DelegationMetaSwapAdapter.SignatureData memory sigData_ = _buildSigData(apiData_);

        vm.prank(address(subVault.deleGator));
        vm.expectRevert(abi.encodeWithSelector(DelegationMetaSwapAdapter.AggregatorIdIsNotAllowed.selector, aggregatorId));
        delegationMetaSwapAdapter.swapByDelegation(sigData_, delegations_, true);
    }

    // Test that swapTokens reverts when insufficient tokens are received.
    function test_revert_swapTokens_insufficientTokens() public {
        _setUpMockContracts();
        // Without sending any token, _getSelfBalance(tokenA) - 0 will be 0.
        vm.prank(address(delegationMetaSwapAdapter));
        vm.expectRevert(DelegationMetaSwapAdapter.InsufficientTokens.selector);
        delegationMetaSwapAdapter.swapTokens(
            aggregatorId, tokenA, tokenB, address(vault.deleGator), amountFrom, 0, swapDataTokenAtoTokenB
        );
    }

    // Test the extra tokens branch in swapTokens (sending the surplus to the recipient).
    function test_swapTokens_extraTokenFromSent() public {
        _setUpMockContracts();
        uint256 extra_ = 0.5 ether;
        // Mint extra tokenA directly to the adapter.
        vm.prank(owner);
        tokenA.mint(address(delegationMetaSwapAdapter), amountFrom + extra_);
        address recipient_ = address(0x1234);

        uint256 recipientTokenABalanceBefore = tokenA.balanceOf(recipient_);
        uint256 recipientTokenBBalanceBefore = tokenB.balanceOf(recipient_);

        // Call swapTokens directly from the contract itself.
        vm.prank(address(delegationMetaSwapAdapter));
        delegationMetaSwapAdapter.swapTokens(aggregatorId, tokenA, tokenB, recipient_, amountFrom, 0, swapDataTokenAtoTokenB);

        uint256 recipientTokenABalanceAfter = tokenA.balanceOf(recipient_);
        uint256 recipientTokenBBalanceAfter = tokenB.balanceOf(recipient_);

        assertEq(recipientTokenABalanceAfter - recipientTokenABalanceBefore, extra_, "Recipient should receive the extra tokenA");
        assertEq(
            recipientTokenBBalanceAfter - recipientTokenBBalanceBefore,
            amountFrom,
            "Recipient should receive tokenB swapped for amountFrom"
        );
    }

    // When the last delegation is missing the argsEqualityCheckEnforcer,
    // swapByDelegation should revert with MissingArgsEqualityCheckEnforcer.
    function test_revert_swapByDelegation_missingArgsEqualityCheckEnforcer() public {
        _setUpMockContracts();
        bytes memory apiData_ = _encodeApiData(aggregatorId, IERC20(tokenA), amountFrom, swapDataTokenAtoTokenB);

        // Create a vault delegation and remove its caveats (so that the check fails)
        Delegation memory badVaultDelegation_ = _getVaultDelegation();
        // Remove caveats so that its length is zero
        delete badVaultDelegation_.caveats;

        // Build the delegation chain with the modified vault delegation.
        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[1] = badVaultDelegation_; // last (root) delegation
        delegations_[0] = _getSubVaultDelegation(EncoderLib._getDelegationHash(badVaultDelegation_));

        DelegationMetaSwapAdapter.SignatureData memory sigData_ = _buildSigData(apiData_);

        vm.prank(address(subVault.deleGator));
        vm.expectRevert(DelegationMetaSwapAdapter.MissingArgsEqualityCheckEnforcer.selector);
        // Call the new version with _useTokenWhitelist (value here is irrelevant)
        delegationMetaSwapAdapter.swapByDelegation(sigData_, delegations_, true);
    }

    // Test the withdraw function for an ERC20 token.
    function test_withdraw() public {
        _setUpMockContracts();
        uint256 withdrawAmount_ = 0.8 ether;
        // Mint tokenA to the adapter.
        vm.prank(owner);
        tokenA.mint(address(delegationMetaSwapAdapter), withdrawAmount_);
        address recipient_ = address(0xABCD);
        vm.expectEmit(true, true, true, true);
        emit DelegationMetaSwapAdapter.SentTokens(tokenA, recipient_, withdrawAmount_);
        vm.prank(owner);
        delegationMetaSwapAdapter.withdraw(tokenA, withdrawAmount_, recipient_);
        assertEq(tokenA.balanceOf(recipient_), withdrawAmount_, "Recipient should receive the withdrawn tokenA");
    }

    // Test the withdraw function for native tokens.
    function test_withdraw_native() public {
        _setUpMockContracts();
        uint256 withdrawAmount_ = 1 ether;
        address recipient_ = address(0xDEAD);
        // Fund the adapter with native ETH.
        vm.deal(address(delegationMetaSwapAdapter), withdrawAmount_);
        vm.expectEmit(true, true, true, true);
        emit DelegationMetaSwapAdapter.SentTokens(IERC20(address(0)), recipient_, withdrawAmount_);
        vm.prank(owner);
        delegationMetaSwapAdapter.withdraw(IERC20(address(0)), withdrawAmount_, recipient_);
        assertEq(recipient_.balance, withdrawAmount_, "Recipient should receive the withdrawn ETH");
    }

    // Test execute from executor
    function test_executeFromExecutor() public {
        _setUpMockContracts();

        vm.startPrank(address(delegationManager));

        bytes memory encodedExecution_ = ExecutionLib.encodeSingle(address(0), 0, hex"");

        // Does not revert
        delegationMetaSwapAdapter.executeFromExecutor(singleDefaultMode, encodedExecution_);

        // Revert for anything other than single default
        vm.expectRevert(abi.encodeWithSelector(DelegationMetaSwapAdapter.UnsupportedCallType.selector, CALLTYPE_BATCH));
        delegationMetaSwapAdapter.executeFromExecutor(batchDefaultMode, encodedExecution_);
        vm.expectRevert(abi.encodeWithSelector(DelegationMetaSwapAdapter.UnsupportedExecType.selector, EXECTYPE_TRY));
        delegationMetaSwapAdapter.executeFromExecutor(singleTryMode, encodedExecution_);
        vm.expectRevert(abi.encodeWithSelector(DelegationMetaSwapAdapter.UnsupportedCallType.selector, CALLTYPE_BATCH));
        delegationMetaSwapAdapter.executeFromExecutor(batchTryMode, encodedExecution_);
    }

    // Test that updateAllowedTokens emits the ChangedTokenStatus event.
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

    // Test that updateAllowedAggregatorIds emits the ChangedAggregatorIdStatus event.
    function test_event_ChangedAggregatorIdStatus() public {
        _setUpMockContracts();
        string[] memory aggregatorIds_ = new string[](1);
        aggregatorIds_[0] = "2";
        bool[] memory statuses_ = new bool[](1);
        statuses_[0] = true;
        bytes32 aggHash_ = keccak256(abi.encode("2"));

        vm.expectEmit(true, false, false, true);
        emit DelegationMetaSwapAdapter.ChangedAggregatorIdStatus(aggHash_, "2", true);
        vm.prank(owner);
        delegationMetaSwapAdapter.updateAllowedAggregatorIds(aggregatorIds_, statuses_);
    }

    // Test that swapTokens (when called via the extra-token branch) emits two SentTokens events.
    function test_event_SentTokens_in_swapTokens() public {
        _setUpMockContracts();
        uint256 extra_ = 0.3 ether;
        address recipient_ = address(0x5678);
        // Mint extra tokenA to the adapter.
        vm.prank(owner);
        tokenA.mint(address(delegationMetaSwapAdapter), amountFrom + extra_);

        // Expect the first SentTokens event (for sending extra tokenA).
        vm.expectEmit(true, true, true, true);
        emit DelegationMetaSwapAdapter.SentTokens(tokenA, recipient_, extra_);
        // And the second SentTokens event (for sending tokenB after swap).
        vm.expectEmit(true, true, true, true);
        emit DelegationMetaSwapAdapter.SentTokens(tokenB, recipient_, amountFrom);

        vm.prank(address(delegationMetaSwapAdapter));
        delegationMetaSwapAdapter.swapTokens(aggregatorId, tokenA, tokenB, recipient_, amountFrom, 0, swapDataTokenAtoTokenB);
    }

    // Test that onlyOwner functions revert if called by a non-owner.
    function test_revert_withdraw_ifNotOwner() public {
        _setUpMockContracts();
        vm.prank(address(subVault.deleGator));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(subVault.deleGator)));
        delegationMetaSwapAdapter.withdraw(tokenA, 1 ether, address(vault.deleGator));
    }

    // Test that updateAllowedTokens reverts with InputLengthsMismatch.
    function test_revert_updateAllowedTokens_arrayLengthMismatch_New() public {
        _setUpMockContracts();
        IERC20[] memory tokens_ = new IERC20[](2);
        tokens_[0] = IERC20(tokenA);
        tokens_[1] = IERC20(tokenB);
        bool[] memory statuses_ = new bool[](1); // intentionally mismatched length
        statuses_[0] = true;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(DelegationMetaSwapAdapter.InputLengthsMismatch.selector));
        delegationMetaSwapAdapter.updateAllowedTokens(tokens_, statuses_);
    }

    // Test that updateAllowedAggregatorIds reverts with InputLengthsMismatch.
    function test_revert_updateAllowedAggregatorIds_arrayLengthMismatch_New() public {
        _setUpMockContracts();
        string[] memory aggregatorIds_ = new string[](2);
        aggregatorIds_[0] = "X";
        aggregatorIds_[1] = "Y";
        bool[] memory statuses_ = new bool[](1); // intentionally mismatched
        statuses_[0] = true;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(DelegationMetaSwapAdapter.InputLengthsMismatch.selector));
        delegationMetaSwapAdapter.updateAllowedAggregatorIds(aggregatorIds_, statuses_);
    }

    // Test that a native token transfer failure reverts with FailedNativeTokenTransfer.
    function test_revert_withdraw_failedNativeTokenTransfer() public {
        _setUpMockContracts();
        // Using a massive amount
        uint256 withdrawAmount_ = type(uint256).max;
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(DelegationMetaSwapAdapter.FailedNativeTokenTransfer.selector, address(delegationMetaSwapAdapter))
        );
        delegationMetaSwapAdapter.withdraw(IERC20(address(0)), withdrawAmount_, address(delegationMetaSwapAdapter));
    }

    function test_revert_swapByDelegation_invalidSwapFunctionSelector() public {
        _setUpMockContracts();

        // Create an invalid apiData with the WRONG 4-byte function selector.
        // The correct one is IMetaSwap.swap.selector.
        bytes4 invalidSelector_ = 0xDEADBEEF;

        // The rest of the data can mimic the correct structure:
        bytes memory invalidApiData_ = abi.encodePacked(
            invalidSelector_, // WRONG!
            abi.encode(
                "aggregatorId",
                IERC20(tokenA), // tokenFrom
                uint256(1 ether),
                hex""
            )
        );

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _getVaultDelegation();

        DelegationMetaSwapAdapter.SignatureData memory sigData_ = _buildSigData(invalidApiData_);

        // Call swapByDelegation from the subVault's perspective
        vm.prank(address(subVault.deleGator));
        vm.expectRevert(DelegationMetaSwapAdapter.InvalidSwapFunctionSelector.selector);
        delegationMetaSwapAdapter.swapByDelegation(sigData_, delegations_, true);
    }

    function test_revert_swapByDelegation_tokenFromMismatch() public {
        _setUpMockContracts();

        // Changing the token from, it must be tokenA but using ETH
        bytes memory validApiData_ = _encodeApiData(aggregatorId, IERC20(address(0)), amountFrom, swapDataTokenAtoTokenB);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _getVaultDelegation();
        DelegationMetaSwapAdapter.SignatureData memory sigData_ = _buildSigData(validApiData_);

        vm.prank(address(subVault.deleGator));
        vm.expectRevert(DelegationMetaSwapAdapter.TokenFromMismatch.selector);
        delegationMetaSwapAdapter.swapByDelegation(sigData_, delegations_, true);
    }

    function test_revert_swapByDelegation_amountFromMismatch() public {
        _setUpMockContracts();

        // Top-level param: 1 ether
        uint256 topLevelAmountFrom = 1 ether;

        // aggregator-level amounts that won't add up to 1.0 if feeTo = false
        uint256 aggregatorAmountFrom_ = 0.9 ether;
        uint256 aggregatorFee_ = 0.05 ether;
        bool feeTo_ = false; // ensures sum must match top-level exactly

        bytes memory invalidSwapData_ = abi.encode(
            tokenA,
            tokenB,
            aggregatorAmountFrom_,
            uint256(1 ether),
            hex"",
            aggregatorFee_,
            address(0),
            feeTo_ // false => sum(0.9 + 0.05 = 0.95) mismatch
        );

        bytes memory apiData_ = abi.encodeWithSelector(
            IMetaSwap.swap.selector,
            aggregatorId,
            tokenA,
            topLevelAmountFrom, // 1 ether
            invalidSwapData_
        );

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _getVaultDelegation();

        DelegationMetaSwapAdapter.SignatureData memory sigData_ = _buildSigData(apiData_);

        vm.prank(address(subVault.deleGator));
        vm.expectRevert(DelegationMetaSwapAdapter.AmountFromMismatch.selector);
        delegationMetaSwapAdapter.swapByDelegation(sigData_, delegations_, true);
    }

    // Test that the constructor emits the constructor events and assigns their values
    function test_event_constructor_events() public {
        // Use dummy addresses for testing.
        address dummySwapApiSignerAddress_ = address(0x999);
        address dummyDelegationManager_ = address(0x123);
        address dummyMetaSwap_ = address(0x456);
        address dummyArgsEqualityCheckEnforcer_ = address(0x456);

        // Expect the events to be emitted during construction.
        vm.expectEmit(true, true, false, true);
        emit DelegationMetaSwapAdapter.SwapApiSignerUpdated(dummySwapApiSignerAddress_);
        vm.expectEmit(true, true, false, true);
        emit DelegationMetaSwapAdapter.SetDelegationManager(IDelegationManager(dummyDelegationManager_));
        vm.expectEmit(true, true, false, true);
        emit DelegationMetaSwapAdapter.SetMetaSwap(IMetaSwap(dummyMetaSwap_));
        vm.expectEmit(true, true, false, true);
        emit DelegationMetaSwapAdapter.SetArgsEqualityCheckEnforcer(dummyArgsEqualityCheckEnforcer_);
        // Deploy a new instance to capture the events.
        DelegationMetaSwapAdapter adapter_ = new DelegationMetaSwapAdapter(
            owner,
            dummySwapApiSignerAddress_,
            IDelegationManager(dummyDelegationManager_),
            IMetaSwap(dummyMetaSwap_),
            dummyArgsEqualityCheckEnforcer_
        );
        assertEq(adapter_.owner(), owner, "Constructor did not set owner correctly");
        assertEq(
            address(adapter_.delegationManager()), dummyDelegationManager_, "Constructor did not set delegationManager correctly"
        );
        assertEq(address(adapter_.swapApiSigner()), dummySwapApiSignerAddress_, "Constructor did not set swapApiSigner correctly");
        assertEq(address(adapter_.metaSwap()), dummyMetaSwap_, "Constructor did not set metaSwap correctly");
        assertEq(
            adapter_.argsEqualityCheckEnforcer(),
            dummyArgsEqualityCheckEnforcer_,
            "Constructor did not set ArgsEqualityCheckEnforcer correctly"
        );
    }

    // Test that allowance increases when it is zero.
    function test_swapTokens_increasesAllowanceIfNeeded() public {
        _setUpMockContracts();
        // Start with zero allowance for tokenA.
        vm.prank(address(delegationMetaSwapAdapter));
        tokenA.approve(address(metaSwapMock), 0);
        // Mint tokenA to the adapter.
        vm.prank(owner);
        tokenA.mint(address(delegationMetaSwapAdapter), amountFrom);
        // Call swapTokens directly (simulate an internal call by using vm.prank(address(delegationMetaSwapAdapter))).
        vm.prank(address(delegationMetaSwapAdapter));
        delegationMetaSwapAdapter.swapTokens(
            aggregatorId, tokenA, tokenB, address(vault.deleGator), amountFrom, 0, swapDataTokenAtoTokenB
        );
        uint256 allowanceAfter_ = tokenA.allowance(address(delegationMetaSwapAdapter), address(metaSwapMock));
        assertEq(allowanceAfter_, type(uint256).max, "Allowance should be increased to max");
    }

    /// @notice Tests that the owner can update the swap API signer via setSwapApiSigner and that the event is emitted.
    function test_setSwapApiSigner_updatesStateAndEmitsEvent() public {
        _setUpMockContracts();
        address newSigner_ = makeAddr("NewSwapSigner");
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit DelegationMetaSwapAdapter.SwapApiSignerUpdated(newSigner_);
        delegationMetaSwapAdapter.setSwapApiSigner(newSigner_);
        assertEq(delegationMetaSwapAdapter.swapApiSigner(), newSigner_, "Swap API signer was not updated");
    }

    /// @notice Tests that the owner cannot set the swap API signer to the zero address.
    function test_revert_setSwapApiSigner_ifZeroAddress() public {
        _setUpMockContracts();
        vm.prank(owner);
        vm.expectRevert(DelegationMetaSwapAdapter.InvalidZeroAddress.selector);
        delegationMetaSwapAdapter.setSwapApiSigner(address(0));
    }

    /// @notice Tests that a non-owner calling setSwapApiSigner reverts.
    function test_revert_setSwapApiSigner_ifNotOwner() public {
        _setUpMockContracts();
        address newSigner_ = makeAddr("NewSwapSigner");
        vm.prank(address(subVault.deleGator));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(subVault.deleGator)));
        delegationMetaSwapAdapter.setSwapApiSigner(newSigner_);
    }

    /// @notice Tests that swapByDelegation reverts with SignatureExpired when the signature expiration has passed.
    function test_revert_swapByDelegation_signatureExpired() public {
        _setUpMockContracts();
        bytes memory swapData_ = _encodeSwapData(IERC20(tokenA), IERC20(tokenB), amountFrom, amountTo, hex"", 0, address(0), true);
        bytes memory apiData_ = _encodeApiData(aggregatorId, IERC20(tokenA), amountFrom, swapData_);
        // Set expiration in the past.
        uint256 expiredTime = block.timestamp - 1;
        bytes memory signature = _getValidSignature(apiData_, expiredTime);
        DelegationMetaSwapAdapter.SignatureData memory sigData_ =
            DelegationMetaSwapAdapter.SignatureData({ apiData: apiData_, expiration: expiredTime, signature: signature });

        Delegation[] memory delegations_ = new Delegation[](2);
        Delegation memory vaultDelegation_ = _getVaultDelegation();
        Delegation memory subVaultDelegation_ = _getSubVaultDelegation(EncoderLib._getDelegationHash(vaultDelegation_));
        delegations_[1] = vaultDelegation_;
        delegations_[0] = subVaultDelegation_;

        vm.prank(address(subVault.deleGator));
        vm.expectRevert(DelegationMetaSwapAdapter.SignatureExpired.selector);
        delegationMetaSwapAdapter.swapByDelegation(sigData_, delegations_, true);
    }

    /// @notice Tests that swapByDelegation reverts with SignatureExpired when the signature expiration is equal to current
    /// timestamp.
    function test_revert_swapByDelegation_signatureExpired_equal() public {
        _setUpMockContracts();
        bytes memory swapData_ = _encodeSwapData(IERC20(tokenA), IERC20(tokenB), amountFrom, amountTo, hex"", 0, address(0), true);
        bytes memory apiData_ = _encodeApiData(aggregatorId, IERC20(tokenA), amountFrom, swapData_);
        // Set expiration in the current time.
        uint256 expiredTime = block.timestamp;
        bytes memory signature = _getValidSignature(apiData_, expiredTime);
        DelegationMetaSwapAdapter.SignatureData memory sigData_ =
            DelegationMetaSwapAdapter.SignatureData({ apiData: apiData_, expiration: expiredTime, signature: signature });

        Delegation[] memory delegations_ = new Delegation[](2);
        Delegation memory vaultDelegation_ = _getVaultDelegation();
        Delegation memory subVaultDelegation_ = _getSubVaultDelegation(EncoderLib._getDelegationHash(vaultDelegation_));
        delegations_[1] = vaultDelegation_;
        delegations_[0] = subVaultDelegation_;

        vm.prank(address(subVault.deleGator));
        vm.expectRevert(DelegationMetaSwapAdapter.SignatureExpired.selector);
        delegationMetaSwapAdapter.swapByDelegation(sigData_, delegations_, true);
    }

    /// @notice Tests that swapByDelegation reverts with InvalidApiSignature when the signature is invalid.
    function test_revert_swapByDelegation_invalidApiSignature() public {
        _setUpMockContracts();
        bytes memory swapData_ = _encodeSwapData(IERC20(tokenA), IERC20(tokenB), amountFrom, amountTo, hex"", 0, address(0), true);
        bytes memory apiData_ = _encodeApiData(aggregatorId, IERC20(tokenA), amountFrom, swapData_);

        // Changing the signer private key so the signer is different
        swapSignerPrivateKey = 11111;
        DelegationMetaSwapAdapter.SignatureData memory sigData_ = _buildSigData(apiData_);

        Delegation[] memory delegations_ = new Delegation[](2);
        Delegation memory vaultDelegation_ = _getVaultDelegation();
        Delegation memory subVaultDelegation_ = _getSubVaultDelegation(EncoderLib._getDelegationHash(vaultDelegation_));
        delegations_[1] = vaultDelegation_;
        delegations_[0] = subVaultDelegation_;

        vm.prank(address(subVault.deleGator));
        vm.expectRevert(DelegationMetaSwapAdapter.InvalidApiSignature.selector);
        delegationMetaSwapAdapter.swapByDelegation(sigData_, delegations_, true);
    }

    /**
     * @dev Deploys and configures a MetaSwapMock that can be used to test the delegationMetaSwapAdapter contract
     */
    function _setUpMockContracts() internal {
        _setUpMockContractsEth(false, false);
    }

    /**
     * @dev Deploys and configures a MetaSwapMock that can be used to test the delegationMetaSwapAdapter contract
     * @dev Allows to specify the use of eth for the tokenFrom or tokenTo
     */
    function _setUpMockContractsEth(bool _useEthFrom, bool _useEthTo) internal {
        vault = users.alice;
        subVault = users.bob;

        tokenA = _useEthFrom ? BasicERC20(address(0)) : new BasicERC20(owner, "TokenA", "TokenA", 0);
        tokenB = _useEthTo ? BasicERC20(address(0)) : new BasicERC20(owner, "TokenB", "TokenB", 0);
        vm.label(address(tokenA), "TokenA");
        vm.label(address(tokenB), "TokenB");

        metaSwapMock = IMetaSwap(address(new MetaSwapMock(IERC20(tokenA), IERC20(tokenB))));

        delegationMetaSwapAdapter = new DelegationMetaSwapAdapter(
            owner,
            swapApiSignerAddress,
            IDelegationManager(address(delegationManager)),
            metaSwapMock,
            address(argsEqualityCheckEnforcer)
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

        _whiteListAggregatorId(aggregatorId);

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
        // *** Create the fork before any other setup runs ***
        // Note: These tests use linea mainnet and a specific block number
        // If you desire to change this fork configuration do not forget to update the API_DATA values

        vm.createSelectFork(vm.envString("LINEA_RPC_URL"), 16_100_581);

        super.setUp();
    }

    /**
     * @notice Demonstrates a fork-based test on the Linea chain
     * This test ensures the DelegationMetaSwapAdapter contract can perform an
     * ERC20 token to ERC20 token swap by delegation on mainnet-fork conditions.
     */
    function test_canSwapByDelegationsInForkErc20ToErc20() public {
        (,, IERC20 tokenFrom_, IERC20 tokenTo_,,) = _setUpForkContracts(API_DATA_ERC20_TO_ERC20);

        Delegation[] memory delegations_ = new Delegation[](2);

        Delegation memory vaultDelegation_ = _getVaultDelegation();
        Delegation memory subVaultDelegation_ = _getSubVaultDelegation(EncoderLib._getDelegationHash(vaultDelegation_));
        delegations_[1] = vaultDelegation_;
        delegations_[0] = subVaultDelegation_;

        uint256 vaultTokenFromBalanceBefore_ = tokenFrom_.balanceOf(address(vault.deleGator));
        uint256 vaultTokenToBalanceBefore_ = tokenTo_.balanceOf(address(vault.deleGator));

        DelegationMetaSwapAdapter.SignatureData memory sigData_ = _buildSigData(API_DATA_ERC20_TO_ERC20);

        vm.prank(address(subVault.deleGator));
        delegationMetaSwapAdapter.swapByDelegation(sigData_, delegations_, true);

        uint256 vaultTokenFromUsed_ = vaultTokenFromBalanceBefore_ - tokenFrom_.balanceOf(address(vault.deleGator));
        uint256 vaultTokenToObtained_ = tokenTo_.balanceOf(address(vault.deleGator)) - vaultTokenToBalanceBefore_;
        assertEq(vaultTokenFromUsed_, amountFrom, "Vault should spend the specified amount of tokenFrom");
        assertGe(vaultTokenToObtained_, amountTo, "Vault should receive the correct amount of tokenTo");
    }

    /**
     * @notice Demonstrates a fork-based test on the Linea chain
     * This test ensures the DelegationMetaSwapAdapter contract can perform an
     * Native Token to ERC20 token swap by delegation on mainnet-fork conditions.
     */
    function test_canSwapByDelegationsInForkNativeTokenToErc20() public {
        (,,, IERC20 tokenTo_,,) = _setUpForkContracts(API_DATA_NATIVE_TO_ERC20);

        Delegation[] memory delegations_ = new Delegation[](2);

        Delegation memory vaultDelegation_ = _getVaultDelegation();
        Delegation memory subVaultDelegation_ = _getSubVaultDelegation(EncoderLib._getDelegationHash(vaultDelegation_));
        delegations_[1] = vaultDelegation_;
        delegations_[0] = subVaultDelegation_;

        // Record vault's ETH and tokenB balances before swap.
        uint256 vaultEthBalanceBefore = address(vault.deleGator).balance;
        uint256 vaultTokenBBalanceBefore = tokenTo_.balanceOf(address(vault.deleGator));
        DelegationMetaSwapAdapter.SignatureData memory sigData_ = _buildSigData(API_DATA_NATIVE_TO_ERC20);

        vm.prank(address(subVault.deleGator));
        delegationMetaSwapAdapter.swapByDelegation(sigData_, delegations_, true);

        // Calculate the change in balances.
        uint256 vaultEthUsed = vaultEthBalanceBefore - address(vault.deleGator).balance;
        uint256 vaultTokenBObtained = tokenB.balanceOf(address(vault.deleGator)) - vaultTokenBBalanceBefore;
        assertEq(vaultEthUsed, amountFrom, "Vault should spend the specified amount of ETH");
        assertGe(vaultTokenBObtained, amountTo, "Vault should receive the correct amount of tokenB");
    }

    /**
     * @notice Demonstrates a fork-based test on the Linea chain
     * This test ensures the DelegationMetaSwapAdapter contract can perform an
     * ERC20 token to Native Token swap by delegation on mainnet-fork conditions.
     */
    function test_canSwapByDelegationsInForkErc20ToNativeToken() public {
        (,, IERC20 tokenFrom_,,,) = _setUpForkContracts(API_DATA_ERC20_TO_NATIVE);

        Delegation[] memory delegations_ = new Delegation[](2);

        Delegation memory vaultDelegation_ = _getVaultDelegation();
        Delegation memory subVaultDelegation_ = _getSubVaultDelegation(EncoderLib._getDelegationHash(vaultDelegation_));
        delegations_[1] = vaultDelegation_;
        delegations_[0] = subVaultDelegation_;

        uint256 vaultTokenFromBalanceBefore_ = tokenFrom_.balanceOf(address(vault.deleGator));
        uint256 vaultTokenToBalanceBefore_ = address(vault.deleGator).balance;
        DelegationMetaSwapAdapter.SignatureData memory sigData_ = _buildSigData(API_DATA_ERC20_TO_NATIVE);

        vm.prank(address(subVault.deleGator));
        delegationMetaSwapAdapter.swapByDelegation(sigData_, delegations_, true);

        uint256 vaultTokenFromUsed_ = vaultTokenFromBalanceBefore_ - tokenFrom_.balanceOf(address(vault.deleGator));
        uint256 vaultTokenToObtained_ = address(vault.deleGator).balance - vaultTokenToBalanceBefore_;
        assertEq(vaultTokenFromUsed_, amountFrom, "Vault should spend the specified amount of token from");
        assertGe(vaultTokenToObtained_, amountTo, "Vault should receive the correct amount of tokenTo");
    }

    /**
     * @dev Overrides and configures the fork contracts that can be used to test the delegationMetaSwapAdapter contract
     */
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
        // Overriding values
        entryPoint = ENTRY_POINT_FORK;
        delegationMetaSwapAdapter = new DelegationMetaSwapAdapter(
            owner, swapApiSignerAddress, DELEGATION_MANAGER_FORK, META_SWAP_FORK, address(argsEqualityCheckEnforcer)
        );
        delegationManager = DelegationManager(address(DELEGATION_MANAGER_FORK));
        hybridDeleGatorImpl = HYBRID_DELEGATOR_IMPL_FORK;

        users = _createUsers();
        vault = users.alice;
        subVault = users.bob;

        (aggregatorId_, tokenFrom_, amountFrom_, swapData_) = _decodeApiData(_apiData);

        _whiteListAggregatorId(aggregatorId_);

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

    /**
     * @notice Initializes the mock with two tokens to swap between.
     */
    constructor(IERC20 _tokenA, IERC20 _tokenB) {
        tokenA = _tokenA;
        tokenB = _tokenB;
    }

    /**
     * @notice Swaps from `tokenFrom` to the other token at a 1:1 ratio, purely for testing.
     * @dev Pulls `_amount` from the caller, then sends the alternate token back to the caller.
     */
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
        address _metaSwap,
        address _argsEqualityCheckEnforcer
    )
        DelegationMetaSwapAdapter(
            _owner,
            _swapApiSigner,
            IDelegationManager(_delegationManager),
            IMetaSwap(_metaSwap),
            _argsEqualityCheckEnforcer
        )
    { }

    function exposedValidateSignature(SignatureData memory _signatureData) public view {
        _validateSignature(_signatureData);
    }
}
