// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { TransparentUpgradeableProxy } from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { ITransparentUpgradeableProxy } from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import { LiFiSwapEnforcer } from "../../src/enforcers/LiFiSwapEnforcer.sol";
import { ModeCode } from "../../src/utils/Types.sol";

/**
 * @title UpgradeableLiFiSwapEnforcerTest
 * @notice Verifies the TransparentUpgradeableProxy mechanics around LiFiSwapEnforcer: hook forwarding
 *         with `msg.sender` (the DelegationManager) preserved, upgrade swaps the implementation while the
 *         proxy address stays constant, and storage written under V1 survives an upgrade to V2.
 * @dev These tests exercise the proxy plumbing only; the enforcer's business logic is covered by
 *      `LiFiSwapEnforcer.t.sol`.
 */
contract UpgradeableLiFiSwapEnforcerTest is Test {
    /// @dev keccak256("eip1967.proxy.admin") - 1
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    /// @dev keccak256("eip1967.proxy.implementation") - 1
    bytes32 internal constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    ModeCode internal singleDefaultMode = ModeLib.encodeSimpleSingle();

    address internal proxyAdminOwner;
    address internal delegationManager;

    LiFiSwapEnforcer internal implV1;
    TransparentUpgradeableProxy internal proxy;
    ProxyAdmin internal proxyAdmin;

    function setUp() public {
        proxyAdminOwner = makeAddr("ProxyAdminOwner");
        delegationManager = makeAddr("DelegationManager");
        vm.label(delegationManager, "DelegationManager");

        vm.startPrank(proxyAdminOwner);
        implV1 = new LiFiSwapEnforcer();
        proxy = new TransparentUpgradeableProxy(address(implV1), proxyAdminOwner, "");
        vm.stopPrank();

        proxyAdmin = ProxyAdmin(address(uint160(uint256(vm.load(address(proxy), ADMIN_SLOT)))));
        vm.label(address(implV1), "LiFiSwapEnforcer V1");
        vm.label(address(proxy), "LiFiSwapEnforcer Proxy");
        vm.label(address(proxyAdmin), "ProxyAdmin");
    }

    ////////////////////// Hook forwarding //////////////////////

    /// @dev beforeAllHook is a no-op in CaveatEnforcer; a successful non-reverting call from a non-admin
    ///      proves the proxy forwarded it (the transparent proxy would have reverted with
    ///      ProxyDeniedAdminAccess if it treated the caller as admin).
    function test_proxy_forwardsBeforeAllHook_withoutAdminRevert() public {
        LiFiSwapEnforcer(address(proxy)).beforeAllHook(
            hex"", hex"", singleDefaultMode, hex"", bytes32(0), address(0), address(0)
        );
    }

    /// @dev beforeHook with garbage calldata reaches V1 logic and reverts with a known enforcer error
    ///      (terms-length validation runs first on empty `_terms`), proving the call was forwarded to
    ///      the implementation rather than rejected as an admin call.
    function test_proxy_forwardsBeforeHook_toImplementation() public {
        vm.prank(delegationManager);
        vm.expectRevert("LiFiSwapQuoteLib:invalid-terms-length");
        LiFiSwapEnforcer(address(proxy)).beforeHook(
            hex"", hex"", singleDefaultMode, hex"", bytes32(0), address(0), address(0)
        );
    }

    /// @dev afterHook with no context is a no-op; a successful call proves forwarding (admin
    ///      misrouting would revert with ProxyDeniedAdminAccess).
    function test_proxy_forwardsAfterHook_withoutAdminRevert() public {
        vm.prank(delegationManager);
        LiFiSwapEnforcer(address(proxy)).afterHook(
            hex"", hex"", singleDefaultMode, hex"", bytes32(0), address(0), address(0)
        );
    }

    /// @dev afterAllHook is a no-op; successful call proves forwarding.
    function test_proxy_forwardsAfterAllHook_withoutAdminRevert() public {
        LiFiSwapEnforcer(address(proxy)).afterAllHook(
            hex"", hex"", singleDefaultMode, hex"", bytes32(0), address(0), address(0)
        );
    }

    /// @dev A non-owner (anyone except the ProxyAdmin) cannot upgrade the proxy: the transparent proxy
    ///      only honors `upgradeToAndCall` from its admin.
    function test_proxy_rejectsUpgradeFromNonOwner() public {
        LiFiSwapEnforcerV2Stub newImpl = new LiFiSwapEnforcerV2Stub();
        vm.prank(delegationManager);
        vm.expectRevert();
        ITransparentUpgradeableProxy(payable(address(proxy))).upgradeToAndCall(address(newImpl), "");
    }

    ////////////////////// Upgrade + msg.sender preservation //////////////////////

    /// @dev Upgrading swaps the implementation (V2 stub reverts with a unique marker that echoes
    ///      `msg.sender`), while the proxy address and the caller-identity semantics are unchanged.
    function test_upgrade_swapsImplementation_preservesProxyAddressAndMsgSender() public {
        address proxyAddress = address(proxy);

        LiFiSwapEnforcerV2Stub newImpl = new LiFiSwapEnforcerV2Stub();
        vm.label(address(newImpl), "LiFiSwapEnforcer V2 stub");

        vm.prank(proxyAdminOwner);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(payable(proxyAddress)), address(newImpl), "");

        // Proxy address is unchanged.
        assertEq(address(proxy), proxyAddress);
        // Implementation slot now points at V2.
        assertEq(
            address(uint160(uint256(vm.load(proxyAddress, IMPLEMENTATION_SLOT)))),
            address(newImpl)
        );

        // V2's overridden beforeHook reverts with a marker that echoes msg.sender. Prank as the
        // DelegationManager (the real caller during redemption) and assert the marker carries that
        // address — proving msg.sender is preserved through proxy + delegatecall.
        vm.prank(delegationManager);
        bytes32 markerHash_ = keccak256("LiFiSwapEnforcerV2:marker");
        bytes memory expectedMarker = abi.encodePacked(markerHash_, delegationManager);
        vm.expectRevert(expectedMarker);
        LiFiSwapEnforcer(address(proxy)).beforeHook(
            hex"", hex"", singleDefaultMode, hex"", bytes32(0), address(0), address(0)
        );
    }

    ////////////////////// Storage persistence across upgrade //////////////////////

    /// @dev Storage written under V1 (via the proxy) is readable by V2 after upgrade, because V2
    ///      inherits V1's storage layout. Writes a sentinel into `afterHookContexts[key].enabled`
    ///      (slot 1 mapping) directly, upgrades, and reads it back through V2's inherited public getter.
    function test_storage_persistsAcrossUpgrade() public {
        bytes32 key = keccak256("storage-persistence-key");
        // afterHookContexts is at slot 1; the base slot for afterHookContexts[key] is
        // keccak256(abi.encode(key, uint256(1))). The `enabled` (bool) field is the first slot of the
        // struct, so writing 1 to the base slot sets enabled = true.
        bytes32 baseSlot = keccak256(abi.encode(key, uint256(1)));
        vm.store(address(proxy), baseSlot, bytes32(uint256(1)));

        // Sanity: V1 reads it back.
        (bool enabledBefore,,,,) = LiFiSwapEnforcer(address(proxy)).afterHookContexts(key);
        assertTrue(enabledBefore);

        // Upgrade to V2 (inherits V1's storage layout).
        LiFiSwapEnforcerV2Stub newImpl = new LiFiSwapEnforcerV2Stub();
        vm.prank(proxyAdminOwner);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(payable(address(proxy))), address(newImpl), "");

        // V2 reads the same storage back through the inherited getter.
        (bool enabledAfter,,,,) = LiFiSwapEnforcer(address(proxy)).afterHookContexts(key);
        assertTrue(enabledAfter);
    }
}

/**
 * @title LiFiSwapEnforcerV2Stub
 * @notice A minimal V2 implementation used to prove the upgrade path. It inherits V1's exact storage
 *         layout (so live state survives) and overrides `beforeHook` to revert with a unique marker
 *         that echoes `msg.sender`, so a test can distinguish V2 logic from V1 and confirm caller
 *         identity is preserved through the proxy.
 * @dev In a real upgrade, V2 would extend the calldata verification (e.g. new bridge routes) while
 *      preserving `periodicAllowances` (slot 0) and `afterHookContexts` (slot 1) in order and type,
 *      only appending new state. This stub appends `v2Marker` after the inherited state, which is
 *      upgrade-safe.
 */
contract LiFiSwapEnforcerV2Stub is LiFiSwapEnforcer {
    /// @dev First 32 bytes of the revert marker; concatenated with the observed `msg.sender`.
    bytes32 public constant V2_MARKER_HASH = keccak256("LiFiSwapEnforcerV2:marker");

    // Appended state (upgrade-safe: comes after inherited periodicAllowances + afterHookContexts).
    uint256 internal _v2Sentinel;

    function beforeHook(
        bytes calldata,
        bytes calldata,
        ModeCode,
        bytes calldata,
        bytes32,
        address,
        address
    )
        public
        override
    {
        // Echo msg.sender so the test can assert the DelegationManager identity survived the proxy hop.
        bytes memory marker = abi.encodePacked(V2_MARKER_HASH, msg.sender);
        assembly {
            revert(add(marker, 0x20), mload(marker))
        }
    }
}
