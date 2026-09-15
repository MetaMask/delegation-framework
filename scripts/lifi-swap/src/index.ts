#!/usr/bin/env tsx

import { runApproveCommand } from "./commands/approve.js";
import { runCheckChainlinkCommand } from "./commands/check-chainlink.js";
import { runCreateChainlinkCommand } from "./commands/create-chainlink.js";
import { runCreateCommand } from "./commands/create.js";
import { runDeleteCommand } from "./commands/delete.js";
import { runExecuteCommand } from "./commands/execute.js";
import { runEstimateGasCommand } from "./commands/estimate-gas.js";
import { runLifiChainsCommand } from "./commands/lifi-chains.js";
import { runLifiConnectionsCommand } from "./commands/lifi-connections.js";
import { runLifiQuoteCommand } from "./commands/lifi-quote.js";
import { runLifiTokensCommand } from "./commands/lifi-tokens.js";
import { runLifiToolsCommand } from "./commands/lifi-tools.js";
import { runListCommand } from "./commands/list.js";
import { runShowCommand } from "./commands/show.js";

function printHelp(): void {
  console.log(`LiFi Swap CLI (staged grant → execute)

Usage:
  npm run delegation -- create [options]
  npm run delegation -- create-chainlink [options]
  npm run delegation -- list
  npm run delegation -- show <id>
  npm run delegation -- delete <id> | delete --all
  npm run chainlink -- check <id> [--reference-round-id <id>]
  npm run approve -- <id> [--dry-run]
  npm run execute -- <id> [--amount <atoms>] [--dry-run] [--skip-approve] \\
    [--allow-bridges near,layerswap] [--deny-bridges relay] \\
    [--spoof-output-chain <name>] [--spoof-output-address <addr>] [--spoof-output-token <sym>]
  npm run estimate-gas -- <id> [--amount <atoms>] [--skip-control] [--skip-relayer] [--skip-rpc] \\
    [--fee-atoms <atoms>] [--allow-bridges ...] [--deny-bridges ...]

LiFi API discovery (read-only, no PRIVATE_KEY):
  npm run lifi -- chains [--chain-types EVM,SVM,UTXO,MVM,TVM] [--json]
  npm run lifi -- tokens --chain <name> [--tags stablecoin] [--symbol USDC] [--json]
  npm run lifi -- tools [--chains base,eth] [--json]
  npm run lifi -- connections --from-chain <name> --to-chain <name> [--from-token USDC] [--json]
  npm run lifi -- quote --input-chain <name> --input-token <sym> --input-address <addr> \\
    --output-chain <name> --output-token <sym> --output-address <addr> --amount <atoms> \\
    [--allow-bridges relay,layerswap] [--deny-bridges hop] [--calldata] [--raw-errors] [--json]

Create options (LiFi-only) — route flags (same style as lifi quote):
  --input-chain <name>        Source chain (e.g. Base); must match BASE_RPC_URL network
  --input-token <symbol>      Input token on source chain (e.g. USDC)
  --output-chain <name>       Destination chain (e.g. Ethereum, Bitcoin)
  --output-token <symbol>     Output token on destination chain (e.g. Eth, BTC)
  --output-address <addr>     Destination recipient (required for cross-chain; defaults to delegator for same-chain)
  --id <slug>                 Saved delegation id
  --name <label>              Human-readable name
  --period-amount <atoms>     Period budget (default: LIFI_PERIOD_AMOUNT)
  --period-duration <seconds> Period length (default: LIFI_PERIOD_DURATION)
  --slippage-bps <bps>        On-chain slippage cap (default: LIFI_SLIPPAGE_BPS)
  --no-approve                Do not save approve delegation alongside swap grant
  --lifi-diamond <addr>       Override LiFi diamond on source chain (default: chains API)
  --force                     Overwrite existing saved delegation id

  Legacy: omit route flags and set LIFI_FROM_TOKEN, LIFI_TO_TOKEN, LIFI_TO_CHAIN in .env

Create-chainlink options (Chainlink + LiFi stacked):
  All LiFi create options above, plus required:
  --rule-kind <dip|rise|absolute_gte|absolute_lte>
  --window-seconds <n>        > 0 for dip/rise; 0 for absolute rules
  --threshold-bps <n>         > 0 for dip/rise; 0 for absolute rules
  --trigger-price <n>         > 0 for absolute rules; 0 for dip/rise

Execute options:
  --amount <atoms>            Swap input amount (default: LIFI_FROM_AMOUNT)
  --dry-run                   Quote + relayer estimate only
  --verbose                   Print LiFi tx request details in quote summary
  --skip-approve              Skip allowance pre-check
  --reference-round-id <id>   Override Chainlink reference round (relative rules)
  --require-chainlink         Abort locally if Chainlink pre-check fails (strict mode)
  --skip-chainlink            Skip Chainlink resolve/patch (args stay empty)
  --allow-bridges <keys>      Limit LiFi quote to these bridges (comma-separated; execute-time only)
  --deny-bridges <keys>       Exclude bridges from LiFi quote (comma-separated; execute-time only)
  --spoof-output-chain <name> Enforcer test: wrong LiFi quote destination chain
  --spoof-output-address <addr> Enforcer test: wrong LiFi quote recipient
  --spoof-output-token <sym>  Enforcer test: wrong LiFi quote output token
                              Default: warn on pre-check fail, proceed to relayer
                              Over-budget amounts warn locally; enforcer enforces on-chain

Environment (scripts/lifi-swap/.env):
  PRIVATE_KEY, BASE_RPC_URL (must match --input-chain network), RELAYER_URL
  Optional defaults: LIFI_PERIOD_*, LIFI_SLIPPAGE*, LIFI_FROM_AMOUNT (execute)
  Legacy create-only: LIFI_FROM_TOKEN, LIFI_TO_TOKEN, LIFI_TO_CHAIN
  Optional create override: LIFI_DIAMOND (source-chain LiFi diamond address)
  LIFI_API_KEY (optional, for Li.FI API rate limits)
  CHAINLINK_PRICE_FEED, CHAINLINK_MAX_STALE_SECONDS, CHAINLINK_MIN_GAP_SECONDS
`);
}

async function main(): Promise<void> {
  const [, , command, subcommand, ...rest] = process.argv;

  try {
    if (command === "delegation" && subcommand === "create") {
      await runCreateCommand(rest);
      return;
    }
    if (command === "delegation" && subcommand === "create-chainlink") {
      await runCreateChainlinkCommand(rest);
      return;
    }
    if (command === "delegation" && subcommand === "list") {
      await runListCommand();
      return;
    }
    if (command === "delegation" && subcommand === "show") {
      await runShowCommand(rest);
      return;
    }
    if (command === "delegation" && subcommand === "delete") {
      await runDeleteCommand(rest);
      return;
    }
    if (command === "chainlink" && subcommand === "check") {
      await runCheckChainlinkCommand(rest);
      return;
    }
    if (command === "approve") {
      await runApproveCommand([subcommand, ...rest].filter(Boolean));
      return;
    }
    if (command === "execute") {
      await runExecuteCommand([subcommand, ...rest].filter(Boolean));
      return;
    }
    if (command === "estimate-gas") {
      await runEstimateGasCommand([subcommand, ...rest].filter(Boolean));
      return;
    }
    if (command === "lifi" && subcommand === "chains") {
      await runLifiChainsCommand(rest);
      return;
    }
    if (command === "lifi" && subcommand === "tokens") {
      await runLifiTokensCommand(rest);
      return;
    }
    if (command === "lifi" && subcommand === "tools") {
      await runLifiToolsCommand(rest);
      return;
    }
    if (command === "lifi" && subcommand === "connections") {
      await runLifiConnectionsCommand(rest);
      return;
    }
    if (command === "lifi" && subcommand === "quote") {
      await runLifiQuoteCommand(rest);
      return;
    }

    printHelp();
    process.exit(command ? 1 : 0);
  } catch (error) {
    console.error(error instanceof Error ? error.message : error);
    process.exit(1);
  }
}

await main();
