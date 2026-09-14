export const BASE_CHAIN_ID = 8453;

export const DELEGATION_MANAGER =
  "0xdb9B1e94B5b69Df7e401DDbedE43491141047dB3" as const;

// TODO(upgradeable-enforcer): after deploying the TransparentUpgradeableProxy on Base via
// script/DeployLiFiSwapEnforcer.s.sol, replace the address below with the logged PROXY address
// (NOT the implementation address). New delegations will then bind to the upgradeable proxy; existing
// signed delegations keep hitting this non-upgradeable enforcer and continue to work.
export const LIFI_SWAP_ENFORCER =
  "0xD0e70cd777a527fB798e5EcA8800c5E3588041d4" as const;

export const CHAINLINK_PRICE_RULE_ENFORCER =
  "0x4dAEbF9C5813EFF2606acD41BA25e57841e7cb75" as const;

export const CHAINLINK_TERMS_LENGTH = 68;

export const RULE_KIND_DIP = 0;
export const RULE_KIND_RISE = 1;
export const RULE_KIND_ABSOLUTE_GTE = 2;
export const RULE_KIND_ABSOLUTE_LTE = 3;

/** Base mainnet ETH/USD Chainlink feed */
export const DEFAULT_CHAINLINK_PRICE_FEED =
  "0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70" as const;

export const ROOT_AUTHORITY =
  "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" as const;

export const LIFI_API_BASE = "https://li.quest/v1";

export const DEFAULT_RELAYER_URL = "https://relayer.1shotapi.com/relayers";

export const TERMS_LENGTH = 284;

export const QUOTE_EXPIRATION_SECONDS = 15 * 60;

export const MOCK_FEE_USDC_ATOMS = 10_000n; // 0.01 USDC
