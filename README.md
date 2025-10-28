# KipuBank V3

KipuBank V3 is a USDC vault. It accepts ERC20 tokens or ETH, swaps to USDC via Uniswap Universal Router, and tracks balances in USDC (6 decimals). It enforces a global USDC cap and supports Permit2 deposits (no prior `approve`).

## Improvements Over Previous Versions

This version introduces several significant improvements focused on user experience, security, and operational flexibility:

1. **Permit2 Integration**: Users can now deposit tokens using signature-based approval (Permit2) without requiring infinite ERC20 approvals. This reduces gas costs and improves security by eliminating persistent allowances.

2. **Uniswap Universal Router Support**: Flexible swap routing through Uniswap's Universal Router allows for sophisticated swap paths, multi-hop swaps, and native ETH support, giving users better execution prices and more options.

3. **Enhanced Access Control**: Implemented OpenZeppelin's AccessControl with MANAGER_ROLE for secure fund recovery operations, replacing single-owner patterns.

4. **Native ETH Deposits**: Added first-class support for ETH deposits through the Universal Router, enabling users to deposit ETH directly instead of requiring WETH wrapping.

5. **Scoped Approvals**: All router approvals are scoped to exact amounts per transaction, eliminating the security risk of infinite approvals to the swap router.

6. **Chainlink Oracle Integration**: Integrated ETH/USD price feed for observability and future expansion into price-aware features.

## Key Features

- Unified USDC balances (6 decimals); withdrawals in USDC
- Universal Router swaps (ERC20/ETH → USDC); caller supplies `commands` and `inputs`
- Global cap (`BANK_CAP`) on total USDC held
- Permit2 deposits (signature-based, no infinite approvals)
- Chainlink ETH/USD price feed
- Reentrancy guard, scoped approvals, slippage/deadline guards

## Design Decisions and Trade-offs

### Why Permit2?

Permit2 eliminates the need for infinite token approvals by allowing signature-based spending authorizations. This improves security (no persistent allowances) and UX (single transaction deposits for new users). Trade-off: Slightly more complex user flow for users who don't already have Permit2 set up.

### Why Universal Router?

The Universal Router provides more flexibility than standard DEX routers, enabling complex swap paths through multiple DEXes and better execution. It also natively supports ETH via `V3_SWAP_EXACT_INPUT` and wrapping. Trade-off: Users must construct `commands` and `inputs` arrays, requiring more frontend integration work.

### Why Separate Permit2 and Standard Deposit Flows?

Having two deposit functions (`depositArbitraryToken` and `depositWithPermit2`) allows users to choose based on their preferences. Standard approval is simpler for existing users, while Permit2 offers better security. This flexibility comes at the cost of more code surface area to audit.

### Why Scoped Approvals Instead of Persistent Ones?

Each swap resets and sets router approvals to the exact amount needed (`approve(amount), swap, approve(0)`). This prevents dust attacks and reduces approval-related risks. Trade-off: Two approval transactions per non-USDC swap, slightly higher gas costs.

### Why Global Bank Cap?

The `BANK_CAP` is enforced on every deposit to limit total value at risk. This protects the protocol and users from concentration risk. The cap is immutable, traded off against flexibility for future adjustments.

## How It Works

### Deposits

- ERC20: approve or use Permit2, then call `depositArbitraryToken(tokenIn, amountIn, minUsdcOut, deadline, commands, inputs)`
- ETH: call `depositArbitraryToken(ETH_ALIAS, amount, minUsdcOut, deadline, commands, inputs)` and send `msg.value == amount`
- Permit2: sign a permit and call `depositWithPermit2(token, amount, ...)`

All paths: optionally swap to USDC, enforce `BANK_CAP`, credit USDC, and apply slippage/deadline.

### Withdraw

```solidity
withdrawUsdc(amount);
```

### Admin

```solidity
recoverFunds(user, newBalance);
```

## Deployment Instructions

### Prerequisites

1. Install dependencies:

```bash
forge install
```

2. Set up environment variables in a `.env` file:

```bash
# Deployer wallet
ADMIN_PRIVATE_KEY=0x...

# Contract addresses (examples for Ethereum mainnet/Sepolia)
USDC_ADDRESS=0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48  # Mainnet USDC
BANK_CAP_USDC=1000000000000  # 1,000,000 USDC (6 decimals = 1000000000000)
UNIVERSAL_ROUTER=0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD  # Uniswap Universal Router
PERMIT2=0x000000000022D473030F116dDEE9F6B43aC78BA3  # Permit2 address
CHAINLINK_ETH_USD_FEED=0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419  # Mainnet ETH/USD feed
ADMIN_ADDRESS=0x...  # Your admin address
```

### Deploy to Testnet (Sepolia)

```bash
# Set testnet RPC URL
export RPC_URL="https://sepolia.infura.io/v3/YOUR_INFURA_KEY"

# Deploy
forge script script/KipuBank.s.sol:DeployKipuBank \
    --rpc-url $RPC_URL \
    --broadcast \
    --verify \
    -vvvv
```

## Interaction Instructions

### 1. Deposit USDC Directly

```solidity
// 1. Approve USDC
IERC20(usdc).approve(kipuBank, amount);

// 2. Deposit (no swap needed for USDC)
kipuBank.depositArbitraryToken(
    address(usdc),
    amount,
    0, // minUsdcOut (no slippage for direct USDC)
    block.timestamp + 3600, // deadline
    bytes(""), // no router commands
    new bytes[](0) // no router inputs
);
```

### 2. Deposit ERC20 Token (with swap)

```solidity
// 1. Approve the token
IERC20(token).approve(kipuBank, amount);

// 2. Prepare Universal Router inputs
bytes memory commands = abi.encodePacked(uint8(0)); // V3_SWAP_EXACT_INPUT
bytes[] memory inputs = new bytes[](1);
inputs[0] = abi.encode(
    msg.sender, // recipient
    amount, // amountIn
    minUsdcOut,
    abi.encodePacked(token, poolFee, address(usdc)),
    false
);

// 3. Deposit
kipuBank.depositArbitraryToken(
    token,
    amount,
    minUsdcOut,
    block.timestamp + 3600,
    commands,
    inputs
);
```

### 3. Deposit ETH

```solidity
// 1. Prepare Universal Router inputs for ETH -> USDC swap
bytes memory commands = abi.encodePacked(uint8(0));
bytes[] memory inputs = new bytes[](1);
inputs[0] = abi.encode(
    msg.sender, // recipient
    msg.value, // amountIn
    minUsdcOut,
    abi.encodePacked(weth, poolFee, address(usdc)),
    false
);

// 2. Send ETH with the transaction
kipuBank.depositArbitraryToken{value: msg.value}(
    0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE, // ETH_ALIAS
    msg.value,
    minUsdcOut,
    block.timestamp + 3600,
    commands,
    inputs
);
```

### 4. Deposit with Permit2 (No Approval Needed)

```solidity
// 1. Sign permit off-chain (frontend integration)
// See: https://github.com/Uniswap/permit2

// 2. Deposit with signature
kipuBank.depositWithPermit2(
    token,
    amount,
    minUsdcOut,
    block.timestamp + 3600,
    routerCommands,
    routerInputs,
    v, // signature v
    r, // signature r
    s  // signature s
);
```

### 5. Withdraw USDC

```solidity
kipuBank.withdrawUsdc(amount);
```

### 6. Check Balances

```solidity
// User balance in USDC
uint256 balance = kipuBank.balanceOfUsdc(user);

// Total USDC in vault
uint256 total = kipuBank.totalUsdcInVault();

// Remaining capacity
uint256 capacity = kipuBank.remainingCapacityUsdc();
```

### 7. Admin Functions

```solidity
// Only MANAGER_ROLE can call this
kipuBank.recoverFunds(user, newBalance);
```

## Constructor Params

| Parameter          | Description                      |
| ------------------ | -------------------------------- |
| `_usdc`            | USDC token address               |
| `_bankCapUsdc`     | Vault cap (in USDC, 6 decimals)  |
| `_universalRouter` | Uniswap Universal Router address |
| `_permit2`         | Permit2 contract address         |
| `_ethUsdPriceFeed` | Chainlink ETH/USD feed address   |
| `_admin`           | Initial admin/manager            |

## Security

- Direct ETH transfers are rejected; use `depositArbitraryToken` with `ETH_ALIAS`
- Scoped approvals (no infinite allowances)
- Reentrancy guard on external functions
- `BANK_CAP` enforced per deposit
