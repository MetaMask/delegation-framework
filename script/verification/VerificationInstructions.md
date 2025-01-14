# Verification Script Instructions

## Overview

This folder contains scripts to verify smart contracts and libraries across multiple chains. Each script serves a specific purpose and must be run from within the `verification/` directory.

### Prerequisites

- Ensure you have installed the necessary tools (e.g., `forge`, `cast`).
- API keys for various block explorers must be set in the `.env` file in the project root.

## General Usage Instructions

1. **Navigate to the `verification` folder:**

   ```bash
   cd path/to/verification
   ```

2. **Run the desired script:**
   - Each script is self-contained and has a specific use case.

### Scripts

#### `verify-contract.sh`

Verifies a standard contract with optional constructor arguments.

**Usage:**

```bash
./verify-contract.sh
```

#### `verify-contract-with-lib.sh`

Verifies a contract that depends on an external library.

**Usage:**

```bash
./verify-contract-with-lib.sh
```

#### `verify-lib.sh`

Verifies a library deployed across multiple chains.

**Usage:**

```bash
./verify-lib.sh
```

#### `verify-enforcer-contracts.sh`

Verifies an array of enforcer contracts.

**Usage:**

```bash
./verify-enforcer-contracts.sh
```

## Notes

- Ensure the `.env` file is correctly configured and contains all necessary API keys.
- The scripts are designed to be run after navigating to the `verification/` folder.
- Modify the variables inside each script as needed for your specific use case.

For additional details or troubleshooting, refer to the script comments or contact the maintainer.
