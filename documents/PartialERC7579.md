## ERC-7579 Partial Implementation

### Overview

The DelegationManager and DelegatorCore contracts implement key aspects of ERC-7579, focusing on the execution interface within DeleGators. This partial integration addresses the most relevant features for the delegation system.

### Key ERC-7579 features integrated:

- **executeFromExecutor**: Allows the DelegationManager to execute actions within DeleGator accounts, ensuring proper authorization and reverting on unsupported modes.

- **execute**: Authorizes the EntryPoint to execute actions within DeleGator accounts, ensuring proper authorization and reverting on unsupported modes.

- **ModeCode**: Encodes options for:

  - **callType**: Determines whether the execution will be single or batch. This provides flexibility for users, allowing them to execute either one transaction or multiple transactions in a single delegation.
  - **execType**: Controls error handling, allowing users to specify whether executions should revert on errors or return values even if errors occur.

### Excluded Features

Non-essential features for this delegation framework:

- Delegate Call (CALLTYPE_DELEGATECALL) is excluded.
- All other ERC-7579 features are unsupported (e.g., install and uninstall modules, hooks, accountIds, components).

For more information, see the original [EIP-7579](https://eips.ethereum.org/EIPS/eip-7579) proposal.
