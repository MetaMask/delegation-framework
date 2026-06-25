// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

/**
 * @title HookFlagsLib
 * @notice Uniswap-v4-style hook-permission flags encoded in the LOW NIBBLE (lowest 4 bits) of a caveat-enforcer address.
 * @dev Inspired by Uniswap v4's `Hooks` library, which packs each callback's permission into a bit of the hook contract's
 *      address and gates every callback with a pure `uint160(addr) & FLAG != 0` test — so the core never makes an external
 *      call into a phase a hook didn't opt into. We apply the same idea to `CaveatEnforcer`'s four hook phases.
 *
 *      An enforcer's hook permissions are therefore carried by its ADDRESS, which is part of the EIP-712-signed
 *      `Caveat.enforcer` (see `EncoderLib._getCaveatPacketHash`). The flags are thus committed by the delegator's signature
 *      and cannot be forged without breaking the delegation hash / chain-authority check — exactly v4's trust model.
 *
 *      To deploy an enforcer at a flag-bearing address, mine a CREATE2 salt until the resulting address's low nibble equals
 *      the desired flag bits (see the comparison test's `_deployFlagged` helper). Enforcers that only implement `beforeHook`
 *      (e.g. ExactExecution*, LimitedCalls) want a low nibble of `BEFORE_HOOK_FLAG` (0x4).
 */
library HookFlagsLib {
    /// @dev The enforcer implements `beforeAllHook`.
    uint160 internal constant BEFORE_ALL_HOOK_FLAG = 1 << 3; // 0x08

    /// @dev The enforcer implements `beforeHook`.
    uint160 internal constant BEFORE_HOOK_FLAG = 1 << 2; // 0x04

    /// @dev The enforcer implements `afterHook`.
    uint160 internal constant AFTER_HOOK_FLAG = 1 << 1; // 0x02

    /// @dev The enforcer implements `afterAllHook`.
    uint160 internal constant AFTER_ALL_HOOK_FLAG = 1 << 0; // 0x01

    /// @dev Mask covering all hook-permission bits (the low nibble).
    uint160 internal constant HOOK_FLAG_MASK = (1 << 4) - 1; // 0x0f

    /**
     * @notice Pure bit-test for a hook permission on an enforcer address — zero storage reads, zero external calls.
     * @param _enforcer The caveat-enforcer address whose low-nibble encodes its hook permissions.
     * @param _flag The hook-permission flag to test for.
     * @return True if the enforcer's address has the given flag bit set.
     */
    function hasFlag(address _enforcer, uint160 _flag) internal pure returns (bool) {
        return uint160(_enforcer) & _flag != 0;
    }
}
