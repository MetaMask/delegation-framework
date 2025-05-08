# Deployments

## **Deterministic Deployment**

The deployment scripts use this salt value to deterministically deploy contracts at the same address across different networks. This is achieved using Solidity's **CREATE2 opcode**, which ensures that contract addresses remain consistent given the same salt, bytecode, and deployer address.

## **Running the Deployment Script**

Before running the deployment script make sure to fill all the .env variables needed for the script, after that run source .env in the terminal where you will run the script.
Below is an example of how to use the deployment scripts:

```sh
forge script script/DeployCaveatEnforcers.s.sol --rpc-url <your_rpc_url> --private-key $PRIVATE_KEY --broadcast
```

### Salt Value

The deployment scripts use a predefined salt value, which is **"GATOR"**. This value is converted into a **`bytes32`** format.

### **How the Salt is Processed**

1. The string **"GATOR"** is retrieved and processed using `abi.encodePacked`, which converts it into a dynamic-length byte array.
2. This encoded value is then cast to **`bytes32`**, ensuring a fixed-length representation for deterministic deployment.

#### **Example in Solidity:**

```solidity
bytes32 salt = bytes32(abi.encodePacked("GATOR"));
```

## **Deployments Chains**

### Mainnets

- Ethereum
- Polygon
- Binance Smart Chain
- Optimism
- Abitrum
- Linea
- Base
- Gnosis Chain

### Testnets

- Ethereum Sepolia
- Linea Sepolia
- Base Sepolia
- MegaEth

## **Deployments**

### **v1.3.0**

```
DelegationManager: 0xdb9B1e94B5b69Df7e401DDbedE43491141047dB3
MultiSigDeleGatorImpl: 0x56a9EdB16a0105eb5a4C54f4C062e2868844f3A7
HybridDeleGatorImpl: 0x48dBe696A4D990079e039489bA2053B36E8FFEC4
EIP7702StatelessDeleGatorImpl: 0x63c0c19a282a1B52b07dD5a65b58948A07DAE32B
AllowedCalldataEnforcer: 0xc2b0d624c1c4319760C96503BA27C347F3260f55
AllowedMethodsEnforcer: 0x2c21fD0Cb9DC8445CB3fb0DC5E7Bb0Aca01842B5
AllowedTargetsEnforcer: 0x7F20f61b1f09b08D970938F6fa563634d65c4EeB
BlockNumberEnforcer: 0x5d9818dF0AE3f66e9c3D0c5029DAF99d1823ca6c
DeployedEnforcer: 0x24ff2AA430D53a8CD6788018E902E098083dcCd2
ERC20BalanceChangeEnforcer: 0xcdF6aB796408598Cea671d79506d7D48E97a5437
ERC20BalanceGteEnforcer: 0x433A6A4d9875D87510584fd6cc586eB1c5F8A1d2
ERC20TransferAmountEnforcer: 0xf100b0819427117EcF76Ed94B358B1A5b5C6D2Fc
ERC20PeriodTransferEnforcer: 0x474e3Ae7E169e940607cC624Da8A15Eb120139aB
ERC20StreamingEnforcer: 0x56c97aE02f233B29fa03502Ecc0457266d9be00e
ERC721BalanceChangeEnforcer: 0x8aFdf96eDBbe7e1eD3f5Cd89C7E084841e12A09e
ERC721BalanceGteEnforcer: 0xA5d03eb350FA89f854685f6313CeCA27A4212542
ERC721TransferEnforcer: 0x3790e6B7233f779b09DA74C72b6e94813925b9aF
ERC1155BalanceChangeEnforcer: 0x63c322732695cAFbbD488Fc6937A0A7B66fC001A
ERC1155BalanceGteEnforcer: 0x831b76f53601f38BfaCa2e6b442D6A5408Ae375c
ExactCalldataBatchEnforcer: 0x982FD5C86BBF425d7d1451f974192d4525113DfD
ExactCalldataEnforcer: 0x99F2e9bF15ce5eC84685604836F71aB835DBBdED
ExactExecutionBatchEnforcer: 0x1e141e455d08721Dd5BCDA1BaA6Ea5633Afd5017
ExactExecutionEnforcer: 0x146713078D39eCC1F5338309c28405ccf85Abfbb
IdEnforcer: 0xC8B5D93463c893401094cc70e66A206fb5987997
LogicalOrWrapperEnforcer: 0xE1302607a3251AF54c3a6e69318d6aa07F5eB46c
LimitedCallsEnforcer: 0x04658B29F6b82ed55274221a06Fc97D318E25416
MultiTokenPeriodEnforcer: 0xFB2f1a9BD76d3701B730E5d69C3219D42D80eBb7
NativeBalanceChangeEnforcer: 0xbD7B277507723490Cd50b12EaaFe87C616be6880
NativeBalanceGteEnforcer: 0x54e17146b9CCE2642881E0879e06e9D63F7d7606
ArgsEqualityCheckEnforcer: 0x44B8C6ae3C304213c3e298495e12497Ed3E56E41
NativeTokenPaymentEnforcer: 0x4803a326ddED6dDBc60e659e5ed12d85c7582811
NativeTokenTransferAmountEnforcer: 0xF71af580b9c3078fbc2BBF16FbB8EEd82b330320
NativeTokenStreamingEnforcer: 0xD10b97905a320b13a0608f7E9cC506b56747df19
NativeTokenPeriodTransferEnforcer: 0x9BC0FAf4Aca5AE429F4c06aEEaC517520CB16BD9
NonceEnforcer: 0xDE4f2FAC4B3D87A1d9953Ca5FC09FCa7F366254f
OwnershipTransferEnforcer: 0x7EEf9734E7092032B5C56310Eb9BbD1f4A524681
RedeemerEnforcer: 0xE144b0b2618071B4E56f746313528a669c7E65c5
SpecificActionERC20TransferBatchEnforcer: 0x00e0251aaA263dfE3B3541B758A82D1CBA1c3B6D
TimestampEnforcer: 0x1046bb45C8d673d4ea75321280DB34899413c069
ValueLteEnforcer: 0x92Bf12322527cAA612fd31a0e810472BBB106A8F

DelegationMetaSwapAdapter
Ethereum: 0xe41eB5A3F6e35f1A8C77113F372892D09820C3fD
Opmtimism, Base, Arbitrum, Linea: 0x5e4b49156D23D890e7DC264c378a443C2d22A80E
BSC, Polygon: 0x9c06653D3f1A331eAf4C3833F7235156e47305F1
```
