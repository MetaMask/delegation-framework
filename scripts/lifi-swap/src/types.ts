import type { Delegation } from "@metamask/smart-accounts-kit";
import type { Address, Hex } from "viem";

export type ChainlinkRuleKind = "dip" | "rise" | "absolute_gte" | "absolute_lte";

/**
 * Calldata decode path selected by LiFiSwapEnforcer.beforeHook. Mirrors the Solidity
 * `LiFiSwapQuoteLib.RouteKind` enum (order matters — abi-encoded as uint8).
 * Provided in `_args` (not signed by the quote signer); the enforcer cross-checks it
 * against the calldata selector and terms shape before decoding.
 */
export enum RouteKind {
  SameChain = 0,
  EvmBridge = 1,
  NearBtc = 2,
  LayerSwapBtc = 3,
}

export type ChainlinkTermsRecord = {
  priceFeed: Address;
  ruleKind: ChainlinkRuleKind;
  expectedDecimals: number;
  windowSeconds: string;
  thresholdBps: number;
  maxStaleSeconds: string;
  minGapSeconds: string;
  triggerPrice: string;
};

export type ChainlinkCreateParams = {
  ruleKind: ChainlinkRuleKind;
  windowSeconds: number;
  thresholdBps: number;
  triggerPrice: bigint;
};

export type ChainlinkEnvConfig = {
  priceFeed: Address;
  maxStaleSeconds: number;
  minGapSeconds: number;
};

export type LiFiTermsRecord = {
  lifiDiamond: Address;
  inputToken: Address;
  outputAssetId: Hex;
  outputRecipient: Hex;
  destinationChainId: string;
  quoteSigner: Address;
  periodAmount: string;
  periodDuration: string;
  startDate: string;
  slippageBps: number;
};

export type SavedDelegationMetadata = {
  inputChain?: string;
  outputChain?: string;
  inputSymbol?: string;
  outputSymbol?: string;
  toChain?: string;
  /** Human-readable LiFi toAddress (EVM, Solana pubkey, BTC address) */
  outputRecipient?: string;
};

export type CliConfig = {
  privateKey: Hex;
  rpcUrl: string;
  relayerUrl: string;
  slippage: number;
  periodAmount: bigint;
  periodDuration: number;
  slippageBps: number;
  fromAmount: bigint;
  outputRecipient?: string;
  outputAssetIdOverride?: Hex;
  outputRecipientBytes32Override?: Hex;
  /** Override LiFi diamond on source chain (create only); default from chains API */
  lifiDiamondOverride?: Address;
};

export type SavedDelegation = {
  id: string;
  name: string;
  createdAt: string;
  chainId: number;
  delegator: Address;
  delegationHash: Hex;
  toToken: string;
  /** Set at create from relayer_getCapabilities; absent on pre-migration saved files */
  relayerTargetAddress?: Address;
  relayerUrl?: string;
  terms: LiFiTermsRecord;
  swapDelegation: Delegation;
  approveDelegation?: Delegation;
  metadata?: SavedDelegationMetadata;
  /** Present when created via create-chainlink */
  chainlinkTerms?: ChainlinkTermsRecord;
  delegationType?: "lifi" | "chainlink-lifi";
};

export type ManifestEntry = {
  id: string;
  name: string;
  createdAt: string;
  delegationHash: Hex;
  periodAmount: string;
  periodDuration: string;
  chainlinkRuleKind?: ChainlinkRuleKind;
  delegationType?: "lifi" | "chainlink-lifi";
};

export type Manifest = {
  delegations: ManifestEntry[];
};

export type SignedLiFiQuote = {
  delegator: Address;
  lifiDiamond: Address;
  inputToken: Address;
  outputAssetId: Hex;
  outputRecipient: Hex;
  destinationChainId: bigint;
  inputAmount: bigint;
  expectedAmountOut: bigint;
  minAmountOut: bigint;
  calldataHash: Hex;
  expiration: bigint;
};

/** @deprecated Prefer CliConfig + ResolvedRoute for create; execute uses saved delegation + CliConfig. */
export type SwapConfig = CliConfig & {
  fromToken: Address;
  toToken: string;
  toChain: number;
};
