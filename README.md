# 🏦 KipuBank V3

**KipuBank V3** is a Solidity smart contract that acts as a USDC-based vault.
It accepts ETH or ERC20 tokens, swaps them to USDC via Uniswap’s **Universal Router**,
and keeps all user balances in USDC. It also enforces a global **bank cap** in USDC and supports **Permit2 deposits** (no need to call `approve`).

---

## ✨ Key Features

### 🪙 Unified USDC Accounting

- All deposits are converted and credited as **USDC** (6 decimals).
- Withdrawals are always done in USDC.

### ⚙️ Universal Router Integration

- Swaps any ERC20 or ETH → USDC using Uniswap’s **Universal Router**.
- The route (`commands` and `inputs`) is provided by the caller or frontend.

### 💰 Bank Cap (AUM Limit)

- Enforces a maximum total USDC balance (`BANK_CAP`).
- Prevents the vault from holding more than allowed.

### 🪄 Permit2 Integration

- Users can deposit ERC20 tokens without calling `approve`.
- Uses Uniswap’s **Permit2** for signature-based token pulls.
- Improves UX and avoids infinite token approvals.

### 🔐 Security Controls

- **Reentrancy guard**: prevents reentrancy attacks.
- **Scoped approvals**: approvals are set per swap, never infinite.
- **Slippage & deadline**: prevents stale or unfair swaps.
- **ETH alias** (`0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE`) standard for native deposits.
- **Role-based control**: manager can recover balances.

### 📈 Oracle Integration

- Uses **Chainlink ETH/USD feed** for price visibility (same as V2).
- Keeps backward compatibility and transparency.

---

## 🚀 How It Works

### 1. Deposit Flow

#### 🪙 ERC20 Deposit

1. Approve the vault (or use Permit2).
2. Call `depositArbitraryToken(tokenIn, amountIn, minUsdcOut, deadline, commands, inputs)`.
3. Contract:

   - Pulls the token.
   - Swaps to USDC via Universal Router.
   - Checks bank cap.
   - Credits USDC to the sender.

#### 💧 ETH Deposit

1. Call `depositArbitraryToken(ETH_ALIAS, amount, minUsdcOut, deadline, commands, inputs)`.
2. Send the same `msg.value` as `amount`.
3. Router wraps ETH to WETH and swaps to USDC.

#### 🪄 Permit2 Deposit

1. User signs a Permit2 approval.
2. Call `depositWithPermit2(token, amount, permitData, ...)`.
3. Contract pulls tokens via Permit2 and performs the same flow.

---

### 2. Withdraw

Call:

```solidity
withdrawUsdc(amount)
```

- Decreases the user’s internal balance.
- Sends USDC back to the wallet.

---

### 3. Admin

**Manager role** can:

```solidity
recoverFunds(user, newBalance)
```

Used for emergency balance corrections.

---

## 📊 Constructor Params

| Parameter          | Description                      |
| ------------------ | -------------------------------- |
| `_usdc`            | USDC token address               |
| `_bankCapUsdc`     | Vault cap (in USDC, 6 decimals)  |
| `_universalRouter` | Uniswap Universal Router address |
| `_permit2`         | Permit2 contract address         |
| `_ethUsdPriceFeed` | Chainlink ETH/USD feed address   |
| `_admin`           | Initial admin/manager            |

---

## 🧠 Example Workflow

1. **Deploy** KipuBank V3 with constructor params.
2. **Deposit ETH**:

   ```solidity

   ```

depositArbitraryToken(ETH_ALIAS, 1 ether, 900 \* 1e6, deadline, commands, inputs);

````
3. **Deposit ERC20**:
```solidity
depositArbitraryToken(tokenAddress, amountIn, minUsdcOut, deadline, commands, inputs);
````

4. **Withdraw USDC**:

   ```solidity

   ```

withdrawUsdc(100_000_000); // 100 USDC

````
5. **Check Price Feed**:
```solidity
getEthUsdPrice();
````

---

## 🧰 Tech Stack

- **Solidity 0.8.30**
- **OpenZeppelin**: `AccessControl`, `SafeERC20`
- **Chainlink**: ETH/USD feed
- **Uniswap**: Universal Router + Permit2
- **Foundry**: for compilation, testing, and deployment

---

## ⚖️ Security & Design Highlights

- No direct ETH transfers (must call via function).
- No infinite allowances.
- Reentrancy guard on all external functions.
- BANK_CAP enforced per deposit.
- CEI pattern everywhere.

---

## 🧾 Summary

KipuBank V3 is a **USDC-denominated vault** that brings together:

- Token and ETH deposits → auto-swapped to USDC.
- Controlled AUM via `BANK_CAP`.
- Safe deposits via Permit2 or classic approval.
- Fully audited-style architecture with Uniswap + Chainlink integration.

> Simple, composable, and secure — a DeFi vault with guardrails.
