// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { EncoderLib } from "../../src/libraries/EncoderLib.sol";
import { BasicERC20 } from "../utils/BasicERC20.t.sol";
import { IComplianceVedaTeller } from "../../src/helpers/interfaces/IComplianceVedaTeller.sol";
import { IVedaTeller } from "../../src/helpers/interfaces/IVedaTeller.sol";
import { VedaAdapter } from "../../src/helpers/VedaAdapter.sol";
import { ComplianceVedaAdapter } from "../../src/helpers/ComplianceVedaAdapter.sol";
import { VaultMigrationHelper } from "../../src/helpers/VaultMigrationHelper.sol";
import { ERC20TransferAmountEnforcer } from "../../src/enforcers/ERC20TransferAmountEnforcer.sol";
import { RedeemerEnforcer } from "../../src/enforcers/RedeemerEnforcer.sol";
import { AllowedCalldataEnforcer } from "../../src/enforcers/AllowedCalldataEnforcer.sol";
import { AllowedTargetsEnforcer } from "../../src/enforcers/AllowedTargetsEnforcer.sol";
import { Delegation, Caveat } from "../../src/utils/Types.sol";
import { BaseTest } from "../utils/BaseTest.t.sol";
import { Implementation, SignatureType, TestUser } from "../utils/Types.t.sol";

interface IRolesAuthority {
    function owner() external view returns (address);
    function setUserRole(address user, uint8 role, bool enabled) external;
    function setRoleCapability(uint8 role, address target, bytes4 functionSig, bool enabled) external;
    function doesUserHaveRole(address user, uint8 role) external view returns (bool);
}

interface ITellerConfiguration {
    function owner() external view returns (address);
    function setTransferRestrictions(uint8 transferAllowedRole, uint8 allowlistedRouterRole) external;
}

interface IVedaAccountant {
    function decimals() external view returns (uint8);
    function getRateInQuoteSafe(address quote) external view returns (uint256);
}

/// forge-config: default.evm_version = "cancun"
contract VaultMigrationHelperTest is BaseTest {
    IERC20 internal constant MUSD = IERC20(0xacA92E438df0B2401fF60dA7E4337B687a2435DA);
    IERC20 internal constant BASE_VAULT = IERC20(0xb4563bcD3B7764CCBf497f515585f70B6C3EA5Ae);
    IVedaTeller internal constant BASE_TELLER = IVedaTeller(0x2D49EA58A4C70b62c8B56DE971310d9e999c8117);
    IVedaAccountant internal constant ACCOUNTANT = IVedaAccountant(0x7382c5b8B51B8C4f127B3123C1039581BAA5A06B);
    address internal constant BASE_LENS = 0xA816ECd922de94c6879AD23B9A884dB257F20947;
    address internal constant BUFFER_LENS = 0xf484d54AF87199F421967E2231Dd6dC348C7Ee6A;
    address internal constant DEPLOYED_BASE_ADAPTER = 0xaD4c09d065fDb6320FA8ADf69460CDd9d472C25A;

    IComplianceVedaTeller internal constant PREMIUM_TELLER = IComplianceVedaTeller(0xB0025a2eBc0474d4F28E975F0D3E70471246ebae);
    IERC20 internal constant PREMIUM_VAULT = IERC20(0xBFeC8c2b1ccea3931a1363E4CaC27352c1C908B7);
    IRolesAuthority internal constant PREMIUM_ROLES_AUTHORITY = IRolesAuthority(0x00f0CF4f540D1d47470f565Ecb11a75E073c2dd0);
    IRolesAuthority internal constant BASE_ROLES_AUTHORITY = IRolesAuthority(0x1eC540C9a4656a50F2D6DaaBd647753F97f082D1);

    address internal constant MUSD_WHALE = 0x6cb5094cfe45Ee97938702637478fe7146A8FA0f;
    uint8 internal constant COMPLIANCE_SIGNER_ROLE = 36;
    uint8 internal constant TRANSFER_ALLOWED_ROLE = 37;
    uint8 internal constant TEST_ROUTER_ROLE = 254;
    uint8 internal constant BASE_ADAPTER_ROLE = 90;

    uint256 internal constant INITIAL_MUSD_BALANCE = 100_000e6;
    uint256 internal constant DEPOSIT_AMOUNT = 1_000e6;
    uint256 internal constant SHARE_LOCK_SECONDS = 61;
    uint256 internal constant COMPLIANCE_SIGNER_KEY = 0xC011A11CE;

    ERC20TransferAmountEnforcer internal erc20TransferAmountEnforcer;
    RedeemerEnforcer internal redeemerEnforcer;
    AllowedCalldataEnforcer internal allowedCalldataEnforcer;
    AllowedTargetsEnforcer internal allowedTargetsEnforcer;
    VedaAdapter internal baseAdapter;
    ComplianceVedaAdapter internal premiumAdapter;
    VaultMigrationHelper internal migrationHelper;
    address internal adapterOwner;
    address internal complianceSigner;

    event MigrationToPremiumExecuted(address indexed delegator, uint256 sourceShares, uint256 destShares);
    event MigrationToBaseExecuted(address indexed delegator, uint256 sourceShares, uint256 destShares);
    event BatchMigrationToPremiumExecuted(address indexed caller, uint256 count);
    event BatchMigrationToBaseExecuted(address indexed caller, uint256 count);
    event PremiumTransferExecuted(address indexed from, address indexed to, uint256 amount);
    event BatchPremiumTransferExecuted(address indexed caller, uint256 count);
    event StuckTokensWithdrawn(IERC20 indexed token, address indexed recipient, uint256 amount);

    function setUp() public override {
        vm.createSelectFork(vm.envString("MONAD_RPC_URL"));

        IMPLEMENTATION = Implementation.Hybrid;
        SIGNATURE_TYPE = SignatureType.RawP256;
        super.setUp();

        adapterOwner = makeAddr("VaultMigrationHelper Owner");
        complianceSigner = vm.addr(COMPLIANCE_SIGNER_KEY);
        erc20TransferAmountEnforcer = new ERC20TransferAmountEnforcer();
        redeemerEnforcer = new RedeemerEnforcer();
        allowedCalldataEnforcer = new AllowedCalldataEnforcer();
        allowedTargetsEnforcer = new AllowedTargetsEnforcer();

        baseAdapter =
            new VedaAdapter(adapterOwner, address(delegationManager), address(BASE_VAULT), address(BASE_TELLER), address(MUSD));
        premiumAdapter = new ComplianceVedaAdapter(
            adapterOwner, address(delegationManager), address(PREMIUM_VAULT), address(PREMIUM_TELLER), address(MUSD)
        );
        migrationHelper = new VaultMigrationHelper(adapterOwner, address(baseAdapter), address(premiumAdapter));

        _configureBaseAdapterRole();
        _configurePremiumForkRoles();
        _fundUser(users.alice);
        _fundUser(users.carol);

        vm.label(address(MUSD), "mUSD");
        vm.label(address(BASE_VAULT), "Base mUSD Vault");
        vm.label(address(PREMIUM_VAULT), "Premium mUSD Vault");
        vm.label(address(BASE_TELLER), "Base Veda Teller");
        vm.label(address(PREMIUM_TELLER), "Premium Veda Teller");
        vm.label(address(ACCOUNTANT), "Base Accountant");
        vm.label(BASE_LENS, "Base Lens");
        vm.label(BUFFER_LENS, "Buffer Lens");
        vm.label(DEPLOYED_BASE_ADAPTER, "Deployed Base Adapter");
        vm.label(address(baseAdapter), "VedaAdapter");
        vm.label(address(premiumAdapter), "ComplianceVedaAdapter");
        vm.label(address(migrationHelper), "VaultMigrationHelper");
        vm.label(complianceSigner, "Compliance Signer");
    }

    function test_constructor_wiresAdaptersAndRevertsOnZeroAddresses() public {
        assertEq(address(migrationHelper.baseAdapter()), address(baseAdapter));
        assertEq(address(migrationHelper.premiumAdapter()), address(premiumAdapter));
        assertEq(migrationHelper.owner(), adapterOwner);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new VaultMigrationHelper(address(0), address(baseAdapter), address(premiumAdapter));

        vm.expectRevert(VaultMigrationHelper.InvalidZeroAddress.selector);
        new VaultMigrationHelper(adapterOwner, address(0), address(premiumAdapter));

        vm.expectRevert(VaultMigrationHelper.InvalidZeroAddress.selector);
        new VaultMigrationHelper(adapterOwner, address(baseAdapter), address(0));
    }

    function test_lifecycle_depositAndWithdrawBaseThenPremium() public {
        uint256 baseShares_ = _depositToBase(users.alice, DEPOSIT_AMOUNT, 0);
        assertGt(baseShares_, 0);
        assertEq(MUSD.balanceOf(address(users.alice.deleGator)), INITIAL_MUSD_BALANCE - DEPOSIT_AMOUNT);
        _assertNoAdapterDust();

        vm.warp(block.timestamp + SHARE_LOCK_SECONDS);
        uint256 assetsOut_ = _withdrawFromBase(users.alice, baseShares_, 1);
        assertEq(BASE_VAULT.balanceOf(address(users.alice.deleGator)), 0);
        assertApproxEqAbs(assetsOut_, DEPOSIT_AMOUNT, DEPOSIT_AMOUNT / 100);
        _assertNoAdapterDust();

        uint256 premiumShares_ = _depositToPremium(users.alice, assetsOut_, 2, block.timestamp + 30 minutes);
        assertGt(premiumShares_, 0);
        assertEq(MUSD.balanceOf(address(users.alice.deleGator)), INITIAL_MUSD_BALANCE - DEPOSIT_AMOUNT);
        _assertNoAdapterDust();

        uint256 musdBeforePremiumWithdraw_ = MUSD.balanceOf(address(users.alice.deleGator));
        _withdrawFromPremium(users.alice, premiumShares_, 3);
        assertEq(PREMIUM_VAULT.balanceOf(address(users.alice.deleGator)), 0);
        assertGt(MUSD.balanceOf(address(users.alice.deleGator)), musdBeforePremiumWithdraw_);
        _assertNoAdapterDust();
    }

    function test_migrateToPremium_movesSharesAndLeavesNoDust() public {
        uint256 baseShares_ = _depositToBase(users.alice, DEPOSIT_AMOUNT, 10);
        vm.warp(block.timestamp + SHARE_LOCK_SECONDS);

        uint256 quotedAssets_ = _quoteAssets(baseShares_);
        uint256 musdBefore_ = MUSD.balanceOf(address(users.alice.deleGator));
        VaultMigrationHelper.ToPremiumParams memory params_ =
            _toPremiumParams(users.alice, baseShares_, quotedAssets_, 11, quotedAssets_, 12, block.timestamp + 30 minutes);

        vm.expectEmit(true, false, false, false, address(migrationHelper));
        emit MigrationToPremiumExecuted(address(users.alice.deleGator), 0, 0);
        vm.prank(address(users.bob.deleGator));
        migrationHelper.migrateToPremiumByDelegation(params_);

        assertEq(BASE_VAULT.balanceOf(address(users.alice.deleGator)), 0);
        assertGt(PREMIUM_VAULT.balanceOf(address(users.alice.deleGator)), 0);
        assertEq(MUSD.balanceOf(address(users.alice.deleGator)), musdBefore_);
        _assertNoAdapterDust();
    }

    function test_migrateToBase_movesSharesAndLeavesNoDust() public {
        uint256 premiumShares_ = _depositToPremium(users.alice, DEPOSIT_AMOUNT, 20, block.timestamp + 30 minutes);
        uint256 quotedAssets_ = _quoteAssets(premiumShares_);
        uint256 musdBefore_ = MUSD.balanceOf(address(users.alice.deleGator));
        VaultMigrationHelper.ToBaseParams memory params_ = _toBaseParams(users.alice, premiumShares_, 21, quotedAssets_, 22);

        vm.expectEmit(true, false, false, false, address(migrationHelper));
        emit MigrationToBaseExecuted(address(users.alice.deleGator), 0, 0);
        vm.prank(address(users.bob.deleGator));
        migrationHelper.migrateToBaseByDelegation(params_);

        assertEq(PREMIUM_VAULT.balanceOf(address(users.alice.deleGator)), 0);
        assertGt(BASE_VAULT.balanceOf(address(users.alice.deleGator)), 0);
        assertEq(MUSD.balanceOf(address(users.alice.deleGator)), musdBefore_);
        _assertNoAdapterDust();
    }

    function test_migrateToPremium_isPermissionless() public {
        uint256 baseShares_ = _depositToBase(users.alice, DEPOSIT_AMOUNT, 30);
        vm.warp(block.timestamp + SHARE_LOCK_SECONDS);
        uint256 quotedAssets_ = _quoteAssets(baseShares_);

        vm.prank(address(users.carol.deleGator));
        migrationHelper.migrateToPremiumByDelegation(
            _toPremiumParams(users.alice, baseShares_, quotedAssets_, 31, quotedAssets_, 32, block.timestamp + 30 minutes)
        );

        assertEq(BASE_VAULT.balanceOf(address(users.alice.deleGator)), 0);
        assertGt(PREMIUM_VAULT.balanceOf(address(users.alice.deleGator)), 0);
        assertEq(PREMIUM_VAULT.balanceOf(address(users.carol.deleGator)), 0);
        _assertNoAdapterDust();
    }

    function test_migrateToPremium_revertsBothLegsWhenDepositFails() public {
        uint256 baseShares_ = _depositToBase(users.alice, DEPOSIT_AMOUNT, 40);
        vm.warp(block.timestamp + SHARE_LOCK_SECONDS);
        uint256 quotedAssets_ = _quoteAssets(baseShares_);
        uint256 musdBefore_ = MUSD.balanceOf(address(users.alice.deleGator));
        VaultMigrationHelper.ToPremiumParams memory params_ =
            _toPremiumParams(users.alice, baseShares_, quotedAssets_, 41, quotedAssets_, 42, block.timestamp + 30 minutes);
        params_.minimumMint = type(uint256).max;

        vm.prank(address(users.bob.deleGator));
        vm.expectRevert();
        migrationHelper.migrateToPremiumByDelegation(params_);

        assertEq(BASE_VAULT.balanceOf(address(users.alice.deleGator)), baseShares_);
        assertEq(PREMIUM_VAULT.balanceOf(address(users.alice.deleGator)), 0);
        assertEq(MUSD.balanceOf(address(users.alice.deleGator)), musdBefore_);
        _assertNoAdapterDust();
    }

    function test_migrateToBase_revertsOnDelegatorMismatch() public {
        uint256 aliceShares_ = _depositToPremium(users.alice, DEPOSIT_AMOUNT, 50, block.timestamp + 30 minutes);
        uint256 quotedAssets_ = _quoteAssets(aliceShares_);

        VaultMigrationHelper.ToBaseParams memory params_ = VaultMigrationHelper.ToBaseParams({
            withdrawalDelegations: _createDelegationChain(
                users.alice, address(premiumAdapter), address(PREMIUM_VAULT), aliceShares_, 51
            ),
            minimumAssets: 0,
            depositDelegations: _createDelegationChain(users.carol, address(baseAdapter), address(MUSD), quotedAssets_, 52),
            minimumMint: 0
        });

        vm.expectRevert(VaultMigrationHelper.DelegatorMismatch.selector);
        migrationHelper.migrateToBaseByDelegation(params_);

        assertEq(PREMIUM_VAULT.balanceOf(address(users.alice.deleGator)), aliceShares_);
        assertEq(BASE_VAULT.balanceOf(address(users.alice.deleGator)), 0);
        assertEq(BASE_VAULT.balanceOf(address(users.carol.deleGator)), 0);
    }

    function test_migrateToPremium_revertsOnShortDelegationChain() public {
        uint256 baseShares_ = _depositToBase(users.alice, DEPOSIT_AMOUNT, 60);
        vm.warp(block.timestamp + SHARE_LOCK_SECONDS);
        uint256 quotedAssets_ = _quoteAssets(baseShares_);
        VaultMigrationHelper.ToPremiumParams memory params_ =
            _toPremiumParams(users.alice, baseShares_, quotedAssets_, 61, quotedAssets_, 62, block.timestamp + 30 minutes);
        params_.withdrawalDelegations = new Delegation[](1);

        vm.expectRevert(VaultMigrationHelper.InvalidDelegationsLength.selector);
        migrationHelper.migrateToPremiumByDelegation(params_);

        assertEq(BASE_VAULT.balanceOf(address(users.alice.deleGator)), baseShares_);
        assertEq(PREMIUM_VAULT.balanceOf(address(users.alice.deleGator)), 0);
    }

    function test_migrateToPremiumBatch_movesExactAmountsForEachDelegator() public {
        uint256 aliceAmount_ = 300e6;
        uint256 carolAmount_ = 400e6;
        uint256 aliceShares_ = _depositToBase(users.alice, aliceAmount_, 70);
        uint256 carolShares_ = _depositToBase(users.carol, carolAmount_, 71);
        vm.warp(block.timestamp + SHARE_LOCK_SECONDS);

        uint256 aliceAssets_ = _quoteAssets(aliceShares_);
        uint256 carolAssets_ = _quoteAssets(carolShares_);
        VaultMigrationHelper.ToPremiumParams[] memory params_ = new VaultMigrationHelper.ToPremiumParams[](2);
        params_[0] = _toPremiumParams(users.alice, aliceShares_, aliceAssets_, 72, aliceAssets_, 73, block.timestamp + 20 minutes);
        params_[1] = _toPremiumParams(users.carol, carolShares_, carolAssets_, 74, carolAssets_, 75, block.timestamp + 21 minutes);

        vm.expectEmit(true, false, false, true, address(migrationHelper));
        emit BatchMigrationToPremiumExecuted(address(users.bob.deleGator), 2);
        vm.prank(address(users.bob.deleGator));
        migrationHelper.migrateToPremiumByDelegationBatch(params_);

        assertEq(BASE_VAULT.balanceOf(address(users.alice.deleGator)), 0);
        assertEq(BASE_VAULT.balanceOf(address(users.carol.deleGator)), 0);
        assertGt(PREMIUM_VAULT.balanceOf(address(users.alice.deleGator)), 0);
        assertGt(PREMIUM_VAULT.balanceOf(address(users.carol.deleGator)), 0);
        _assertNoAdapterDust();
    }

    function test_migrateToBaseBatch_movesExactAmountsForEachDelegator() public {
        uint256 aliceAmount_ = 250e6;
        uint256 carolAmount_ = 350e6;
        uint256 aliceShares_ = _depositToPremium(users.alice, aliceAmount_, 80, block.timestamp + 20 minutes);
        uint256 carolShares_ = _depositToPremium(users.carol, carolAmount_, 81, block.timestamp + 21 minutes);

        uint256 aliceAssets_ = _quoteAssets(aliceShares_);
        uint256 carolAssets_ = _quoteAssets(carolShares_);
        VaultMigrationHelper.ToBaseParams[] memory params_ = new VaultMigrationHelper.ToBaseParams[](2);
        params_[0] = _toBaseParams(users.alice, aliceShares_, 82, aliceAssets_, 83);
        params_[1] = _toBaseParams(users.carol, carolShares_, 84, carolAssets_, 85);

        vm.expectEmit(true, false, false, true, address(migrationHelper));
        emit BatchMigrationToBaseExecuted(address(users.bob.deleGator), 2);
        vm.prank(address(users.bob.deleGator));
        migrationHelper.migrateToBaseByDelegationBatch(params_);

        assertEq(PREMIUM_VAULT.balanceOf(address(users.alice.deleGator)), 0);
        assertEq(PREMIUM_VAULT.balanceOf(address(users.carol.deleGator)), 0);
        assertGt(BASE_VAULT.balanceOf(address(users.alice.deleGator)), 0);
        assertGt(BASE_VAULT.balanceOf(address(users.carol.deleGator)), 0);
        _assertNoAdapterDust();
    }

    function test_migrateToPremiumBatch_revertsAllWhenLaterStreamFails() public {
        uint256 aliceShares_ = _depositToBase(users.alice, 300e6, 90);
        uint256 carolShares_ = _depositToBase(users.carol, 400e6, 91);
        vm.warp(block.timestamp + SHARE_LOCK_SECONDS);

        uint256 aliceAssets_ = _quoteAssets(aliceShares_);
        uint256 carolAssets_ = _quoteAssets(carolShares_);
        VaultMigrationHelper.ToPremiumParams[] memory params_ = new VaultMigrationHelper.ToPremiumParams[](2);
        params_[0] = _toPremiumParams(users.alice, aliceShares_, aliceAssets_, 92, aliceAssets_, 93, block.timestamp + 20 minutes);
        params_[1] = _toPremiumParams(users.carol, carolShares_, carolAssets_, 94, carolAssets_, 95, block.timestamp + 21 minutes);
        params_[1].minimumMint = type(uint256).max;

        vm.prank(address(users.bob.deleGator));
        vm.expectRevert();
        migrationHelper.migrateToPremiumByDelegationBatch(params_);

        assertEq(BASE_VAULT.balanceOf(address(users.alice.deleGator)), aliceShares_);
        assertEq(BASE_VAULT.balanceOf(address(users.carol.deleGator)), carolShares_);
        assertEq(PREMIUM_VAULT.balanceOf(address(users.alice.deleGator)), 0);
        assertEq(PREMIUM_VAULT.balanceOf(address(users.carol.deleGator)), 0);
    }

    function test_emptyBatchesRevert() public {
        VaultMigrationHelper.ToPremiumParams[] memory premiumParams_ = new VaultMigrationHelper.ToPremiumParams[](0);
        VaultMigrationHelper.ToBaseParams[] memory baseParams_ = new VaultMigrationHelper.ToBaseParams[](0);

        vm.expectRevert(VaultMigrationHelper.InvalidBatchLength.selector);
        migrationHelper.migrateToPremiumByDelegationBatch(premiumParams_);

        vm.expectRevert(VaultMigrationHelper.InvalidBatchLength.selector);
        migrationHelper.migrateToBaseByDelegationBatch(baseParams_);

        VaultMigrationHelper.PremiumTransferParams[] memory transferParams_ = new VaultMigrationHelper.PremiumTransferParams[](0);
        vm.expectRevert(VaultMigrationHelper.InvalidBatchLength.selector);
        migrationHelper.premiumTransferBatch(transferParams_);
    }

    function test_migrateToPremium_revertsOnExpiredCompliance() public {
        uint256 baseShares_ = _depositToBase(users.alice, DEPOSIT_AMOUNT, 100);
        vm.warp(block.timestamp + SHARE_LOCK_SECONDS);
        uint256 quotedAssets_ = _quoteAssets(baseShares_);
        VaultMigrationHelper.ToPremiumParams memory params_ =
            _toPremiumParams(users.alice, baseShares_, quotedAssets_, 101, quotedAssets_, 102, block.timestamp - 1);

        vm.prank(address(users.bob.deleGator));
        vm.expectRevert();
        migrationHelper.migrateToPremiumByDelegation(params_);

        assertEq(BASE_VAULT.balanceOf(address(users.alice.deleGator)), baseShares_);
        assertEq(PREMIUM_VAULT.balanceOf(address(users.alice.deleGator)), 0);
    }

    function test_migrateToPremium_revertsOnWrongComplianceSigner() public {
        uint256 baseShares_ = _depositToBase(users.alice, DEPOSIT_AMOUNT, 110);
        vm.warp(block.timestamp + SHARE_LOCK_SECONDS);
        uint256 quotedAssets_ = _quoteAssets(baseShares_);
        VaultMigrationHelper.ToPremiumParams memory params_ =
            _toPremiumParams(users.alice, baseShares_, quotedAssets_, 111, quotedAssets_, 112, block.timestamp + 30 minutes);
        params_.compliance = IComplianceVedaTeller.ComplianceData({
            deadline: block.timestamp + 30 minutes,
            signature: _signCompliance(users.alice, quotedAssets_, block.timestamp + 30 minutes, 0xBAD)
        });

        vm.prank(address(users.bob.deleGator));
        vm.expectRevert();
        migrationHelper.migrateToPremiumByDelegation(params_);

        assertEq(BASE_VAULT.balanceOf(address(users.alice.deleGator)), baseShares_);
    }

    function test_migrateToPremium_revertsOnReplayedCompliance() public {
        uint256 firstShares_ = _depositToBase(users.alice, DEPOSIT_AMOUNT, 120);
        vm.warp(block.timestamp + SHARE_LOCK_SECONDS);
        uint256 firstAssets_ = _quoteAssets(firstShares_);
        uint256 deadline_ = block.timestamp + 30 minutes;
        VaultMigrationHelper.ToPremiumParams memory firstParams_ =
            _toPremiumParams(users.alice, firstShares_, firstAssets_, 121, firstAssets_, 122, deadline_);

        vm.prank(address(users.bob.deleGator));
        migrationHelper.migrateToPremiumByDelegation(firstParams_);

        uint256 secondShares_ = _depositToBase(users.alice, DEPOSIT_AMOUNT, 123);
        vm.warp(block.timestamp + SHARE_LOCK_SECONDS);
        uint256 secondAssets_ = _quoteAssets(secondShares_);
        VaultMigrationHelper.ToPremiumParams memory replayParams_ =
            _toPremiumParams(users.alice, secondShares_, secondAssets_, 124, secondAssets_, 125, deadline_ + 1 hours);
        replayParams_.compliance = firstParams_.compliance;

        vm.prank(address(users.bob.deleGator));
        vm.expectRevert();
        migrationHelper.migrateToPremiumByDelegation(replayParams_);
    }

    function test_migrateToPremium_revertsOnWithdrawSlippage() public {
        uint256 baseShares_ = _depositToBase(users.alice, DEPOSIT_AMOUNT, 130);
        vm.warp(block.timestamp + SHARE_LOCK_SECONDS);
        uint256 quotedAssets_ = _quoteAssets(baseShares_);
        VaultMigrationHelper.ToPremiumParams memory params_ =
            _toPremiumParams(users.alice, baseShares_, quotedAssets_, 131, quotedAssets_, 132, block.timestamp + 30 minutes);
        params_.minimumAssets = type(uint256).max;

        vm.prank(address(users.bob.deleGator));
        vm.expectRevert();
        migrationHelper.migrateToPremiumByDelegation(params_);

        assertEq(BASE_VAULT.balanceOf(address(users.alice.deleGator)), baseShares_);
    }

    function test_migrateToPremium_revertsOnDelegationReplay() public {
        uint256 baseShares_ = _depositToBase(users.alice, DEPOSIT_AMOUNT, 140);
        vm.warp(block.timestamp + SHARE_LOCK_SECONDS);
        uint256 quotedAssets_ = _quoteAssets(baseShares_);
        VaultMigrationHelper.ToPremiumParams memory params_ =
            _toPremiumParams(users.alice, baseShares_, quotedAssets_, 141, quotedAssets_, 142, block.timestamp + 30 minutes);

        vm.prank(address(users.bob.deleGator));
        migrationHelper.migrateToPremiumByDelegation(params_);

        vm.prank(address(users.bob.deleGator));
        vm.expectRevert();
        migrationHelper.migrateToPremiumByDelegation(params_);
    }

    function test_premiumTransfer_movesFullBalanceToRecipient() public {
        uint256 shares_ = _depositToPremium(users.alice, DEPOSIT_AMOUNT, 200, block.timestamp + 30 minutes);
        address from_ = address(users.alice.deleGator);
        address to_ = address(users.carol.deleGator);
        Delegation[] memory delegations_ = _createPremiumTransferChain(users.alice, shares_, 201, address(migrationHelper));
        IComplianceVedaTeller.ComplianceData memory compliance_ =
            _transferComplianceData(from_, to_, shares_, block.timestamp + 30 minutes, COMPLIANCE_SIGNER_KEY);

        vm.expectEmit(true, true, false, true, address(migrationHelper));
        emit PremiumTransferExecuted(from_, to_, shares_);
        vm.prank(address(users.bob.deleGator));
        migrationHelper.premiumTransfer(from_, to_, delegations_, compliance_);

        assertEq(PREMIUM_VAULT.balanceOf(from_), 0);
        assertEq(PREMIUM_VAULT.balanceOf(to_), shares_);
        _assertNoAdapterDust();
    }

    function test_premiumTransfer_isPermissionless() public {
        uint256 shares_ = _depositToPremium(users.alice, DEPOSIT_AMOUNT, 210, block.timestamp + 30 minutes);
        address from_ = address(users.alice.deleGator);
        address to_ = address(users.carol.deleGator);
        Delegation[] memory delegations_ = _createPremiumTransferChain(users.alice, shares_, 211, address(migrationHelper));
        IComplianceVedaTeller.ComplianceData memory compliance_ =
            _transferComplianceData(from_, to_, shares_, block.timestamp + 30 minutes, COMPLIANCE_SIGNER_KEY);

        vm.prank(address(users.carol.deleGator));
        migrationHelper.premiumTransfer(from_, to_, delegations_, compliance_);

        assertEq(PREMIUM_VAULT.balanceOf(from_), 0);
        assertEq(PREMIUM_VAULT.balanceOf(to_), shares_);
        _assertNoAdapterDust();
    }

    function test_premiumTransfer_revertsOnExpiredCompliance() public {
        uint256 shares_ = _depositToPremium(users.alice, DEPOSIT_AMOUNT, 220, block.timestamp + 30 minutes);
        address from_ = address(users.alice.deleGator);
        address to_ = address(users.carol.deleGator);
        Delegation[] memory delegations_ = _createPremiumTransferChain(users.alice, shares_, 221, address(migrationHelper));
        IComplianceVedaTeller.ComplianceData memory compliance_ =
            _transferComplianceData(from_, to_, shares_, block.timestamp - 1, COMPLIANCE_SIGNER_KEY);

        vm.prank(address(users.bob.deleGator));
        vm.expectRevert(VaultMigrationHelper.ComplianceCheckFailed.selector);
        migrationHelper.premiumTransfer(from_, to_, delegations_, compliance_);

        assertEq(PREMIUM_VAULT.balanceOf(from_), shares_);
    }

    function test_premiumTransfer_revertsOnWrongComplianceSigner() public {
        uint256 shares_ = _depositToPremium(users.alice, DEPOSIT_AMOUNT, 230, block.timestamp + 30 minutes);
        address from_ = address(users.alice.deleGator);
        address to_ = address(users.carol.deleGator);
        Delegation[] memory delegations_ = _createPremiumTransferChain(users.alice, shares_, 231, address(migrationHelper));
        IComplianceVedaTeller.ComplianceData memory compliance_ =
            _transferComplianceData(from_, to_, shares_, block.timestamp + 30 minutes, 0xBAD);

        vm.prank(address(users.bob.deleGator));
        vm.expectRevert(VaultMigrationHelper.ComplianceCheckFailed.selector);
        migrationHelper.premiumTransfer(from_, to_, delegations_, compliance_);
    }

    function test_premiumTransfer_revertsOnReplayedCompliance() public {
        uint256 shares_ = _depositToPremium(users.alice, DEPOSIT_AMOUNT, 240, block.timestamp + 30 minutes);
        address from_ = address(users.alice.deleGator);
        address to_ = address(users.carol.deleGator);
        uint256 deadline_ = block.timestamp + 30 minutes;
        IComplianceVedaTeller.ComplianceData memory compliance_ =
            _transferComplianceData(from_, to_, shares_, deadline_, COMPLIANCE_SIGNER_KEY);
        Delegation[] memory firstDelegations_ = _createPremiumTransferChain(users.alice, shares_, 241, address(migrationHelper));

        vm.prank(address(users.bob.deleGator));
        migrationHelper.premiumTransfer(from_, to_, firstDelegations_, compliance_);

        vm.startPrank(PREMIUM_ROLES_AUTHORITY.owner());
        PREMIUM_ROLES_AUTHORITY.setUserRole(to_, TRANSFER_ALLOWED_ROLE, true);
        vm.stopPrank();
        vm.prank(to_);
        PREMIUM_VAULT.transfer(from_, shares_);
        Delegation[] memory secondDelegations_ = _createPremiumTransferChain(users.alice, shares_, 243, address(migrationHelper));

        vm.prank(address(users.bob.deleGator));
        vm.expectRevert(VaultMigrationHelper.ComplianceCheckFailed.selector);
        migrationHelper.premiumTransfer(from_, to_, secondDelegations_, compliance_);
    }

    function test_premiumTransfer_revertsOnFromMismatch() public {
        uint256 shares_ = _depositToPremium(users.alice, DEPOSIT_AMOUNT, 250, block.timestamp + 30 minutes);
        address to_ = address(users.carol.deleGator);
        Delegation[] memory delegations_ = _createPremiumTransferChain(users.alice, shares_, 251, address(migrationHelper));
        IComplianceVedaTeller.ComplianceData memory compliance_ = _transferComplianceData(
            address(users.carol.deleGator), to_, shares_, block.timestamp + 30 minutes, COMPLIANCE_SIGNER_KEY
        );

        vm.expectRevert(VaultMigrationHelper.DelegatorMismatch.selector);
        migrationHelper.premiumTransfer(address(users.carol.deleGator), to_, delegations_, compliance_);
    }

    function test_premiumTransfer_revertsOnLeafAmountMismatch() public {
        uint256 shares_ = _depositToPremium(users.alice, DEPOSIT_AMOUNT, 260, block.timestamp + 30 minutes);
        address from_ = address(users.alice.deleGator);
        address to_ = address(users.carol.deleGator);
        Delegation[] memory delegations_ = _createPremiumTransferChain(users.alice, shares_ - 1, 261, address(migrationHelper));
        IComplianceVedaTeller.ComplianceData memory compliance_ =
            _transferComplianceData(from_, to_, shares_, block.timestamp + 30 minutes, COMPLIANCE_SIGNER_KEY);

        vm.expectRevert(VaultMigrationHelper.InvalidTransferAmount.selector);
        migrationHelper.premiumTransfer(from_, to_, delegations_, compliance_);
    }

    function test_premiumTransfer_revertsOnShortDelegationChain() public {
        uint256 shares_ = _depositToPremium(users.alice, DEPOSIT_AMOUNT, 270, block.timestamp + 30 minutes);
        Delegation[] memory delegations_ = new Delegation[](1);
        address from_ = address(users.alice.deleGator);
        address to_ = address(users.carol.deleGator);
        IComplianceVedaTeller.ComplianceData memory compliance_ =
            _transferComplianceData(from_, to_, shares_, block.timestamp + 30 minutes, COMPLIANCE_SIGNER_KEY);

        vm.expectRevert(VaultMigrationHelper.InvalidDelegationsLength.selector);
        migrationHelper.premiumTransfer(from_, to_, delegations_, compliance_);
    }

    function test_premiumTransfer_revertsOnZeroTo() public {
        uint256 shares_ = _depositToPremium(users.alice, DEPOSIT_AMOUNT, 280, block.timestamp + 30 minutes);
        address from_ = address(users.alice.deleGator);
        Delegation[] memory delegations_ = _createPremiumTransferChain(users.alice, shares_, 281, address(migrationHelper));
        IComplianceVedaTeller.ComplianceData memory compliance_ =
            _transferComplianceData(from_, address(0), shares_, block.timestamp + 30 minutes, COMPLIANCE_SIGNER_KEY);

        vm.expectRevert(VaultMigrationHelper.InvalidZeroAddress.selector);
        migrationHelper.premiumTransfer(from_, address(0), delegations_, compliance_);
    }

    function test_premiumTransfer_revertsWhenHelperNotAllowlisted() public {
        uint256 shares_ = _depositToPremium(users.alice, DEPOSIT_AMOUNT, 290, block.timestamp + 30 minutes);
        address from_ = address(users.alice.deleGator);
        address to_ = address(users.carol.deleGator);
        Delegation[] memory delegations_ = _createPremiumTransferChain(users.alice, shares_, 291, address(migrationHelper));
        IComplianceVedaTeller.ComplianceData memory compliance_ =
            _transferComplianceData(from_, to_, shares_, block.timestamp + 30 minutes, COMPLIANCE_SIGNER_KEY);

        vm.prank(PREMIUM_ROLES_AUTHORITY.owner());
        PREMIUM_ROLES_AUTHORITY.setUserRole(address(migrationHelper), TRANSFER_ALLOWED_ROLE, false);

        vm.prank(address(users.bob.deleGator));
        vm.expectRevert();
        migrationHelper.premiumTransfer(from_, to_, delegations_, compliance_);

        assertEq(PREMIUM_VAULT.balanceOf(from_), shares_);
    }

    function test_premiumTransfer_revertsWhenCalldataToIsNotHelper() public {
        uint256 shares_ = _depositToPremium(users.alice, DEPOSIT_AMOUNT, 300, block.timestamp + 30 minutes);
        address from_ = address(users.alice.deleGator);
        address to_ = address(users.carol.deleGator);
        Delegation[] memory delegations_ = _createPremiumTransferChain(users.alice, shares_, 301, to_);
        IComplianceVedaTeller.ComplianceData memory compliance_ =
            _transferComplianceData(from_, to_, shares_, block.timestamp + 30 minutes, COMPLIANCE_SIGNER_KEY);

        vm.prank(address(users.bob.deleGator));
        vm.expectRevert("AllowedCalldataEnforcer:invalid-calldata");
        migrationHelper.premiumTransfer(from_, to_, delegations_, compliance_);

        assertEq(PREMIUM_VAULT.balanceOf(from_), shares_);
    }

    function test_premiumTransfer_revertsOnDepositComplianceSignature() public {
        uint256 shares_ = _depositToPremium(users.alice, DEPOSIT_AMOUNT, 310, block.timestamp + 30 minutes);
        address from_ = address(users.alice.deleGator);
        address to_ = address(users.carol.deleGator);
        uint256 deadline_ = block.timestamp + 30 minutes;
        Delegation[] memory delegations_ = _createPremiumTransferChain(users.alice, shares_, 311, address(migrationHelper));
        IComplianceVedaTeller.ComplianceData memory depositCompliance_ = IComplianceVedaTeller.ComplianceData({
            deadline: deadline_, signature: _signCompliance(users.alice, shares_, deadline_, COMPLIANCE_SIGNER_KEY)
        });

        vm.prank(address(users.bob.deleGator));
        vm.expectRevert(VaultMigrationHelper.ComplianceCheckFailed.selector);
        migrationHelper.premiumTransfer(from_, to_, delegations_, depositCompliance_);

        assertEq(PREMIUM_VAULT.balanceOf(from_), shares_);
    }

    function test_premiumTransfer_revertsWhenComplianceDisabled() public {
        uint256 shares_ = _depositToPremium(users.alice, DEPOSIT_AMOUNT, 320, block.timestamp + 30 minutes);
        address from_ = address(users.alice.deleGator);
        address to_ = address(users.carol.deleGator);
        Delegation[] memory delegations_ = _createPremiumTransferChain(users.alice, shares_, 321, address(migrationHelper));
        IComplianceVedaTeller.ComplianceData memory compliance_ =
            _transferComplianceData(from_, to_, shares_, block.timestamp + 30 minutes, COMPLIANCE_SIGNER_KEY);

        vm.mockCall(
            address(PREMIUM_TELLER),
            abi.encodeWithSelector(IComplianceVedaTeller.complianceSignerRole.selector),
            abi.encode(type(uint8).max)
        );

        vm.prank(address(users.bob.deleGator));
        vm.expectRevert(VaultMigrationHelper.ComplianceDisabled.selector);
        migrationHelper.premiumTransfer(from_, to_, delegations_, compliance_);

        assertEq(PREMIUM_VAULT.balanceOf(from_), shares_);
        vm.clearMockedCalls();
    }

    function test_premiumTransferBatch_movesEachDelegatorToRecipient() public {
        uint256 aliceShares_ = _depositToPremium(users.alice, 300e6, 330, block.timestamp + 20 minutes);
        uint256 carolShares_ = _depositToPremium(users.carol, 400e6, 331, block.timestamp + 21 minutes);
        address recipient_ = makeAddr("premiumTransferRecipient");
        address alice_ = address(users.alice.deleGator);
        address carol_ = address(users.carol.deleGator);

        VaultMigrationHelper.PremiumTransferParams[] memory params_ = new VaultMigrationHelper.PremiumTransferParams[](2);
        params_[0] = _premiumTransferParams(users.alice, aliceShares_, 332, recipient_, block.timestamp + 20 minutes);
        params_[1] = _premiumTransferParams(users.carol, carolShares_, 333, recipient_, block.timestamp + 21 minutes);

        vm.expectEmit(true, false, false, true, address(migrationHelper));
        emit BatchPremiumTransferExecuted(address(users.bob.deleGator), 2);
        vm.prank(address(users.bob.deleGator));
        migrationHelper.premiumTransferBatch(params_);

        assertEq(PREMIUM_VAULT.balanceOf(alice_), 0);
        assertEq(PREMIUM_VAULT.balanceOf(carol_), 0);
        assertEq(PREMIUM_VAULT.balanceOf(recipient_), aliceShares_ + carolShares_);
        _assertNoAdapterDust();
    }

    function test_premiumTransferBatch_revertsAllWhenLaterStreamFails() public {
        uint256 aliceShares_ = _depositToPremium(users.alice, 300e6, 340, block.timestamp + 20 minutes);
        uint256 carolShares_ = _depositToPremium(users.carol, 400e6, 341, block.timestamp + 21 minutes);
        address recipient_ = makeAddr("premiumTransferRecipient");
        address alice_ = address(users.alice.deleGator);
        address carol_ = address(users.carol.deleGator);

        VaultMigrationHelper.PremiumTransferParams[] memory params_ = new VaultMigrationHelper.PremiumTransferParams[](2);
        params_[0] = _premiumTransferParams(users.alice, aliceShares_, 342, recipient_, block.timestamp + 20 minutes);
        params_[1] = _premiumTransferParams(users.carol, carolShares_, 343, recipient_, block.timestamp - 1);

        vm.prank(address(users.bob.deleGator));
        vm.expectRevert(VaultMigrationHelper.ComplianceCheckFailed.selector);
        migrationHelper.premiumTransferBatch(params_);

        assertEq(PREMIUM_VAULT.balanceOf(alice_), aliceShares_);
        assertEq(PREMIUM_VAULT.balanceOf(carol_), carolShares_);
        assertEq(PREMIUM_VAULT.balanceOf(recipient_), 0);
        _assertNoAdapterDust();
    }

    function test_withdrawEmergency_revertsOnNonOwner() public {
        BasicERC20 testToken_ = new BasicERC20(adapterOwner, "TestToken", "TST", 0);
        vm.prank(adapterOwner);
        testToken_.mint(address(migrationHelper), 100 ether);

        vm.prank(address(users.alice.deleGator));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(users.alice.deleGator)));
        migrationHelper.withdrawEmergency(testToken_, 50 ether, address(users.alice.deleGator));

        assertEq(testToken_.balanceOf(address(migrationHelper)), 100 ether);
    }

    function test_withdrawEmergency_recoverTokens() public {
        BasicERC20 testToken_ = new BasicERC20(adapterOwner, "TestToken", "TST", 0);
        vm.prank(adapterOwner);
        testToken_.mint(address(migrationHelper), 100 ether);

        vm.expectEmit(true, true, false, true, address(migrationHelper));
        emit StuckTokensWithdrawn(testToken_, address(users.alice.deleGator), 50 ether);

        vm.prank(adapterOwner);
        migrationHelper.withdrawEmergency(testToken_, 50 ether, address(users.alice.deleGator));

        assertEq(testToken_.balanceOf(address(migrationHelper)), 50 ether);
        assertEq(testToken_.balanceOf(address(users.alice.deleGator)), 50 ether);
    }

    function test_withdrawEmergency_revertsOnZeroRecipient() public {
        BasicERC20 testToken_ = new BasicERC20(adapterOwner, "TestToken", "TST", 0);
        vm.prank(adapterOwner);
        testToken_.mint(address(migrationHelper), 100 ether);

        vm.expectRevert(VaultMigrationHelper.InvalidRecipient.selector);
        vm.prank(adapterOwner);
        migrationHelper.withdrawEmergency(testToken_, 50 ether, address(0));
    }

    function _configureBaseAdapterRole() internal {
        vm.prank(BASE_ROLES_AUTHORITY.owner());
        BASE_ROLES_AUTHORITY.setUserRole(address(baseAdapter), BASE_ADAPTER_ROLE, true);
    }

    function _configurePremiumForkRoles() internal {
        address authorityOwner_ = PREMIUM_ROLES_AUTHORITY.owner();
        address tellerOwner_ = ITellerConfiguration(address(PREMIUM_TELLER)).owner();
        assertEq(authorityOwner_, tellerOwner_);

        vm.startPrank(authorityOwner_);
        PREMIUM_ROLES_AUTHORITY.setUserRole(complianceSigner, COMPLIANCE_SIGNER_ROLE, true);
        PREMIUM_ROLES_AUTHORITY.setUserRole(address(premiumAdapter), TRANSFER_ALLOWED_ROLE, true);
        PREMIUM_ROLES_AUTHORITY.setUserRole(address(migrationHelper), TRANSFER_ALLOWED_ROLE, true);
        PREMIUM_ROLES_AUTHORITY.setUserRole(address(premiumAdapter), TEST_ROUTER_ROLE, true);
        PREMIUM_ROLES_AUTHORITY.setRoleCapability(
            TEST_ROUTER_ROLE, address(PREMIUM_TELLER), IComplianceVedaTeller.withdraw.selector, true
        );
        ITellerConfiguration(address(PREMIUM_TELLER)).setTransferRestrictions(TRANSFER_ALLOWED_ROLE, TEST_ROUTER_ROLE);
        vm.stopPrank();
    }

    function _fundUser(TestUser memory _user) internal {
        vm.prank(MUSD_WHALE);
        require(MUSD.transfer(address(_user.deleGator), INITIAL_MUSD_BALANCE), "mUSD funding failed");
    }

    function _quoteAssets(uint256 _shares) internal view returns (uint256) {
        return _shares * ACCOUNTANT.getRateInQuoteSafe(address(MUSD)) / (10 ** ACCOUNTANT.decimals());
    }

    function _depositToBase(TestUser memory _delegator, uint256 _amount, uint256 _salt) internal returns (uint256 shares_) {
        uint256 sharesBefore_ = BASE_VAULT.balanceOf(address(_delegator.deleGator));
        Delegation[] memory delegations_ = _createDelegationChain(_delegator, address(baseAdapter), address(MUSD), _amount, _salt);

        vm.prank(address(users.bob.deleGator));
        baseAdapter.depositByDelegation(delegations_, 0);
        shares_ = BASE_VAULT.balanceOf(address(_delegator.deleGator)) - sharesBefore_;
    }

    function _withdrawFromBase(
        TestUser memory _delegator,
        uint256 _shareAmount,
        uint256 _salt
    )
        internal
        returns (uint256 assetsOut_)
    {
        uint256 musdBefore_ = MUSD.balanceOf(address(_delegator.deleGator));
        Delegation[] memory delegations_ =
            _createDelegationChain(_delegator, address(baseAdapter), address(BASE_VAULT), _shareAmount, _salt);

        vm.prank(address(users.bob.deleGator));
        baseAdapter.withdrawByDelegation(delegations_, 0);
        assetsOut_ = MUSD.balanceOf(address(_delegator.deleGator)) - musdBefore_;
    }

    function _depositToPremium(
        TestUser memory _delegator,
        uint256 _amount,
        uint256 _salt,
        uint256 _deadline
    )
        internal
        returns (uint256 shares_)
    {
        uint256 sharesBefore_ = PREMIUM_VAULT.balanceOf(address(_delegator.deleGator));
        Delegation[] memory delegations_ =
            _createDelegationChain(_delegator, address(premiumAdapter), address(MUSD), _amount, _salt);
        IComplianceVedaTeller.ComplianceData memory compliance_ = _complianceData(_delegator, _amount, _deadline);

        vm.prank(address(users.bob.deleGator));
        premiumAdapter.depositByDelegation(delegations_, 0, compliance_);
        shares_ = PREMIUM_VAULT.balanceOf(address(_delegator.deleGator)) - sharesBefore_;
    }

    function _withdrawFromPremium(TestUser memory _delegator, uint256 _shareAmount, uint256 _salt) internal {
        Delegation[] memory delegations_ =
            _createDelegationChain(_delegator, address(premiumAdapter), address(PREMIUM_VAULT), _shareAmount, _salt);

        vm.prank(address(users.bob.deleGator));
        premiumAdapter.withdrawByDelegation(delegations_, 0);
    }

    function _toPremiumParams(
        TestUser memory _delegator,
        uint256 _shareAmount,
        uint256 _assetAmount,
        uint256 _withdrawalSalt,
        uint256 _depositAmount,
        uint256 _depositSalt,
        uint256 _deadline
    )
        internal
        view
        returns (VaultMigrationHelper.ToPremiumParams memory)
    {
        return VaultMigrationHelper.ToPremiumParams({
            withdrawalDelegations: _createDelegationChain(
                _delegator, address(baseAdapter), address(BASE_VAULT), _shareAmount, _withdrawalSalt
            ),
            minimumAssets: 0,
            depositDelegations: _createDelegationChain(
                _delegator, address(premiumAdapter), address(MUSD), _depositAmount, _depositSalt
            ),
            minimumMint: 0,
            compliance: _complianceData(_delegator, _assetAmount, _deadline)
        });
    }

    function _toBaseParams(
        TestUser memory _delegator,
        uint256 _shareAmount,
        uint256 _withdrawalSalt,
        uint256 _depositAmount,
        uint256 _depositSalt
    )
        internal
        view
        returns (VaultMigrationHelper.ToBaseParams memory)
    {
        return VaultMigrationHelper.ToBaseParams({
            withdrawalDelegations: _createDelegationChain(
                _delegator, address(premiumAdapter), address(PREMIUM_VAULT), _shareAmount, _withdrawalSalt
            ),
            minimumAssets: 0,
            depositDelegations: _createDelegationChain(
                _delegator, address(baseAdapter), address(MUSD), _depositAmount, _depositSalt
            ),
            minimumMint: 0
        });
    }

    function _premiumTransferParams(
        TestUser memory _delegator,
        uint256 _amount,
        uint256 _salt,
        address _to,
        uint256 _deadline
    )
        internal
        view
        returns (VaultMigrationHelper.PremiumTransferParams memory)
    {
        address from_ = address(_delegator.deleGator);
        return VaultMigrationHelper.PremiumTransferParams({
            from: from_,
            to: _to,
            delegations: _createPremiumTransferChain(_delegator, _amount, _salt, address(migrationHelper)),
            compliance: _transferComplianceData(from_, _to, _amount, _deadline, COMPLIANCE_SIGNER_KEY)
        });
    }

    function _createDelegationChain(
        TestUser memory _delegator,
        address _adapter,
        address _token,
        uint256 _amount,
        uint256 _salt
    )
        internal
        view
        returns (Delegation[] memory delegations_)
    {
        Delegation memory root_ = _createTransferDelegation(_delegator, _adapter, _token, type(uint256).max, _salt);
        bytes32 authority_ = EncoderLib._getDelegationHash(root_);
        Delegation memory leaf_ = _createAdapterRedelegation(_adapter, authority_, _token, _amount, _salt);

        delegations_ = new Delegation[](2);
        delegations_[0] = leaf_;
        delegations_[1] = root_;
    }

    function _createTransferDelegation(
        TestUser memory _delegator,
        address _adapter,
        address _token,
        uint256 _amount,
        uint256 _salt
    )
        internal
        view
        returns (Delegation memory)
    {
        Caveat[] memory caveats_ = new Caveat[](2);
        caveats_[0] =
            Caveat({ args: hex"", enforcer: address(erc20TransferAmountEnforcer), terms: abi.encodePacked(_token, _amount) });
        caveats_[1] = Caveat({ args: hex"", enforcer: address(redeemerEnforcer), terms: abi.encodePacked(_adapter) });

        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(_delegator.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: _salt,
            signature: hex""
        });
        return signDelegation(_delegator, delegation_);
    }

    function _createAdapterRedelegation(
        address _adapter,
        bytes32 _authority,
        address _token,
        uint256 _amount,
        uint256 _salt
    )
        internal
        view
        returns (Delegation memory)
    {
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] =
            Caveat({ args: hex"", enforcer: address(erc20TransferAmountEnforcer), terms: abi.encodePacked(_token, _amount) });

        Delegation memory delegation_ = Delegation({
            delegate: _adapter,
            delegator: address(users.bob.deleGator),
            authority: _authority,
            caveats: caveats_,
            salt: _salt,
            signature: hex""
        });
        return signDelegation(users.bob, delegation_);
    }

    function _createPremiumTransferChain(
        TestUser memory _delegator,
        uint256 _amount,
        uint256 _salt,
        address _calldataTo
    )
        internal
        view
        returns (Delegation[] memory delegations_)
    {
        Caveat[] memory rootCaveats_ = new Caveat[](4);
        rootCaveats_[0] = Caveat({
            args: hex"",
            enforcer: address(erc20TransferAmountEnforcer),
            terms: abi.encodePacked(address(PREMIUM_VAULT), type(uint256).max)
        });
        rootCaveats_[1] =
            Caveat({ args: hex"", enforcer: address(redeemerEnforcer), terms: abi.encodePacked(address(migrationHelper)) });
        rootCaveats_[2] = Caveat({
            args: hex"", enforcer: address(allowedCalldataEnforcer), terms: abi.encodePacked(uint256(4), abi.encode(_calldataTo))
        });
        rootCaveats_[3] =
            Caveat({ args: hex"", enforcer: address(allowedTargetsEnforcer), terms: abi.encodePacked(address(PREMIUM_VAULT)) });

        Delegation memory root_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(_delegator.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: rootCaveats_,
            salt: _salt,
            signature: hex""
        });
        root_ = signDelegation(_delegator, root_);

        Caveat[] memory leafCaveats_ = new Caveat[](1);
        leafCaveats_[0] = Caveat({
            args: hex"", enforcer: address(erc20TransferAmountEnforcer), terms: abi.encodePacked(address(PREMIUM_VAULT), _amount)
        });

        Delegation memory leaf_ = Delegation({
            delegate: address(migrationHelper),
            delegator: address(users.bob.deleGator),
            authority: EncoderLib._getDelegationHash(root_),
            caveats: leafCaveats_,
            salt: _salt,
            signature: hex""
        });
        leaf_ = signDelegation(users.bob, leaf_);

        delegations_ = new Delegation[](2);
        delegations_[0] = leaf_;
        delegations_[1] = root_;
    }

    function _transferComplianceData(
        address _from,
        address _to,
        uint256 _amount,
        uint256 _deadline,
        uint256 _signerKey
    )
        internal
        view
        returns (IComplianceVedaTeller.ComplianceData memory)
    {
        bytes32 messageHash_ = keccak256(
            abi.encode(
                address(migrationHelper),
                address(PREMIUM_TELLER),
                block.chainid,
                _from,
                _to,
                address(PREMIUM_VAULT),
                _amount,
                _deadline
            )
        );
        bytes32 ethSignedMessageHash_ = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash_));
        (uint8 v_, bytes32 r_, bytes32 s_) = vm.sign(_signerKey, ethSignedMessageHash_);
        return IComplianceVedaTeller.ComplianceData({ deadline: _deadline, signature: abi.encodePacked(r_, s_, v_) });
    }

    function _complianceData(
        TestUser memory _delegator,
        uint256 _amount,
        uint256 _deadline
    )
        internal
        view
        returns (IComplianceVedaTeller.ComplianceData memory)
    {
        return IComplianceVedaTeller.ComplianceData({
            deadline: _deadline, signature: _signCompliance(_delegator, _amount, _deadline, COMPLIANCE_SIGNER_KEY)
        });
    }

    function _signCompliance(
        TestUser memory _delegator,
        uint256 _amount,
        uint256 _deadline,
        uint256 _signerKey
    )
        internal
        view
        returns (bytes memory)
    {
        bytes32 messageHash_ = keccak256(
            abi.encode(
                address(PREMIUM_TELLER),
                block.chainid,
                address(premiumAdapter),
                address(_delegator.deleGator),
                address(MUSD),
                _amount,
                _deadline
            )
        );
        bytes32 ethSignedMessageHash_ = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash_));
        (uint8 v_, bytes32 r_, bytes32 s_) = vm.sign(_signerKey, ethSignedMessageHash_);
        return abi.encodePacked(r_, s_, v_);
    }

    function _assertNoAdapterDust() internal {
        assertEq(MUSD.balanceOf(address(baseAdapter)), 0);
        assertEq(MUSD.balanceOf(address(premiumAdapter)), 0);
        assertEq(MUSD.balanceOf(address(migrationHelper)), 0);
        assertEq(BASE_VAULT.balanceOf(address(baseAdapter)), 0);
        assertEq(PREMIUM_VAULT.balanceOf(address(premiumAdapter)), 0);
        assertEq(BASE_VAULT.balanceOf(address(migrationHelper)), 0);
        assertEq(PREMIUM_VAULT.balanceOf(address(migrationHelper)), 0);
    }
}
