import type { Chain } from "viem";
import {
  arbitrum,
  base,
  bsc,
  gnosis,
  linea,
  mainnet,
  optimism,
  polygon,
} from "viem/chains";

const KNOWN_CHAINS: Record<number, Chain> = {
  [mainnet.id]: mainnet,
  [base.id]: base,
  [polygon.id]: polygon,
  [arbitrum.id]: arbitrum,
  [optimism.id]: optimism,
  [bsc.id]: bsc,
  [gnosis.id]: gnosis,
  [linea.id]: linea,
};

/** Map a chain ID to a viem Chain; falls back to a minimal chain using the supplied RPC URL. */
export function viemChainFromId(chainId: number, rpcUrl: string): Chain {
  const known = KNOWN_CHAINS[chainId];
  if (known) return known;

  return {
    id: chainId,
    name: `chain-${chainId}`,
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [rpcUrl] } },
  } as Chain;
}
