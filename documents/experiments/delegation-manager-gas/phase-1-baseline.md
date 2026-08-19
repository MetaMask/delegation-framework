# Phase 1 — branch setup and baselines

## Environment

| Field | Value |
| --- | --- |
| Git repo | `/Users/hanzel/delegation-framework` |
| Branch | `feat/limit-order-manager-gas-experiments` |
| Base branch | `feat/optimized-delegation-manager` |
| Source commit (base) | `53dd5cb46103b5e10f763e7015af7833f686eb3f` |
| Foundry | `1.5.1-stable` (commit `b0a9dd9ceda36f63e2326ce530c10e6916f4b8a2`) |
| Solc | `0.8.23` (`optimizer = true` in `foundry.toml`) |

### Submodule revisions (at branch point)

| Dependency | Commit |
| --- | --- |
| erc7579-implementation | `42aa538397138e0858bae09d1bd1a1921aa24b8c` |
| forge-std | `ae570fec082bfe1c1f45b0acca4a2b4f84d345ce` |
| openzeppelin-contracts | `105fa4e1b0832a6a40cb7ba6e545bb844f02a711` |
| account-abstraction | `7af70c8993a6f42973f520ae0752386a5032abe7` |

## Worktree note

Tracked files were clean on branch creation. Untracked paths present on the base branch: `documents/reviews/`, `test/review/` (not part of Phase 1 commit).

## Baseline gas (`forge test --isolate -vv`)

### SimpleDelegationManagerComparison (`test_compare_*`)

| Scenario | DelegationManager exec | Simple exec | Calldata | Est. tx (canonical / simple) |
| --- | ---: | ---: | ---: | ---: |
| Baseline, single, no caveats | 94,748 | 83,494 | 5,668 | 121,416 / 110,162 |
| Gasless swap, 1-exec combined enforcer | 156,625 | 126,934 | 10,272 | 187,897 / 158,206 |
| Gasless tx, 2-exec combined enforcer | 193,315 | 159,338 | 13,628 | 227,943 / 193,966 |
| Chained delegation swap | 181,993 | 142,280 | 13,524 | 216,517 / 176,804 |

### GasOptimizationAblation (canonical manager)

| Scenario | Exec | Calldata | Est. tx |
| --- | ---: | ---: | ---: |
| 1-exec batch, combined enforcer | 156,563 | 10,272 | 187,835 |
| 1-exec batch, separate enforcers | 180,084 | 11,340 | 212,424 |
| 2-exec batch, combined enforcer | 193,216 | 13,592 | 227,808 |
| 2-exec batch, separate enforcers | 216,820 | 14,660 | 252,480 |

### Erc7821BaselineBenchmark (floor, excl. 7702 auth)

| Scenario | executeBatch exec | Calldata | Est. standalone tx |
| --- | ---: | ---: | ---: |
| Gasless swap, 1-exec signed batch | 97,542 | 4,868 | 123,410 |
| Gasless tx, 2-exec signed batch | 126,542 | 6,540 | 154,082 |

## Harness commands

```bash
forge test --isolate -vv --match-contract GasExperimentMatrix
forge test --isolate -vv --match-contract ExecuteFromExecutorForwardingSpy
```
