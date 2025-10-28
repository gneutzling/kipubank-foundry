# KipuBank V3

KipuBank V3 is a USDC vault. It accepts ERC20 tokens or ETH, swaps to USDC via Uniswap Universal Router, and tracks balances in USDC (6 decimals). It enforces a global USDC cap and supports Permit2 deposits (no prior `approve`).

## Key Features

- Unified USDC balances (6 decimals); withdrawals in USDC
- Universal Router swaps (ERC20/ETH → USDC); caller supplies `commands` and `inputs`
- Global cap (`BANK_CAP`) on total USDC held
- Permit2 deposits (signature-based, no infinite approvals)
- Chainlink ETH/USD price feed
- Reentrancy guard, scoped approvals, slippage/deadline guards

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
