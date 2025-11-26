# KipuBankV3 – Pre-Audit Threat Analysis and Invariant Specification

## 1. Protocol Overview

### 1.1 High-Level Description

KipuBankV3 is a non-custodial USDC vault that:

- Accepts ERC-20 tokens and native ETH as deposits.
- Uses the Uniswap Universal Router to swap arbitrary tokens / ETH into USDC.
- Tracks user balances in USDC units with 6 decimals.
- Enforces a global TVL cap (BANK_CAP) in USDC.
- Optionally exposes Chainlink ETH/USD price data for observability.

Supports two deposit flows:

- Classic ERC-20 approve + deposit.
- Permit2-based deposit (signature-based allowance).

The contract is non-upgradeable, uses OpenZeppelin AccessControl, and applies a custom non-reentrant guard around state-changing external functions.

### 1.2 Core Components

**KipuBank (main contract)**

Immutable configuration:

- **USDC**: ERC-20 used as accounting asset (assumed 6 decimals, non-rebasing).
- **BANK_CAP**: maximum total USDC allowed in the vault.
- **UNIVERSAL_ROUTER**: Uniswap Universal Router for swaps.
- **PERMIT2**: Uniswap Permit2 contract for signature-based approvals.
- **ETH_USD_PRICE_FEED**: Chainlink aggregator for ETH/USD price.

State:

- `mapping(address => uint256) balances`: internal ledger of user USDC credit.
- `uint256 depositCount, uint256 withdrawCount`: usage metrics.
- `bool locked`: reentrancy guard flag.

Roles (OpenZeppelin AccessControl):

- **DEFAULT_ADMIN_ROLE**: can manage roles.
- **MANAGER_ROLE**: can call recoverFunds() to adjust user balances.

**Deployment script (KipuBank.s.sol)**

Reads configuration from environment:

- USDC address, bank cap, Universal Router, Permit2, Chainlink feed, admin.

Deploys the contract and assigns DEFAULT_ADMIN_ROLE and MANAGER_ROLE to admin.

**Test suite (KipuBank.t.sol)**

Uses mocks for:

- USDC, Universal Router, Permit2, Chainlink aggregator, and a generic token MockTokenA.

Covers constructor behavior, deposit/withdraw flows, cap enforcement, events, and view functions.

### 1.3 Core Flows

#### 1.3.1 depositArbitraryToken

Signature (simplified):

```solidity
function depositArbitraryToken(
    address tokenIn,
    uint256 amountIn,
    uint256 minUsdcOut,
    uint256 deadline,
    bytes calldata routerCommands,
    bytes[] calldata routerInputs
) external payable noReentrancy;
```

Behavior:

**USDC deposits (tokenIn == USDC)**

- Pulls USDC via `safeTransferFrom(msg.sender, address(this), amountIn)`.
- `usdcReceived = amountIn` (1:1 credit).
- No Universal Router interaction.

**ETH deposits (tokenIn == ETH_ALIAS)**

- Requires `msg.value == amountIn` (otherwise EthValueMismatch).
- Calls `UNIVERSAL_ROUTER.execute{value: amountIn}(..., deadline)`.
- Measures USDC delta: `usdcReceived = USDC.balanceOf(this) - usdcBefore`.

**Other ERC-20 deposits**

- Pulls tokenIn from the user via `_pullTokenFromUser`.
- Calls `_swapExactInputSingle`:
  - Resets/sets allowance of tokenIn to UNIVERSAL_ROUTER.
  - Executes swap via `UNIVERSAL_ROUTER.execute(...)`.
- Computes USDC delta as the difference in USDC balance.

**Common checks:**

- `amountIn > 0` (ZeroAmountNotAllowed).
- For non-USDC deposits, enforce slippage guard:
  - `usdcReceived >= minUsdcOut` (InsufficientSwapOutput).
- Enforce global bank cap via `_enforceBankCap(usdcBefore, usdcReceived)`:
  - Revert with BankCapacityExceeded if projected balance exceeds BANK_CAP.
- Update internal ledger:
  - `balances[msg.sender] += usdcReceived`.
  - Increment depositCount.
- Emit `DepositedUSDC(user, actualTokenIn, amountIn, usdcReceived)`.

#### 1.3.2 depositWithPermit2

```solidity
function depositWithPermit2(
    address tokenIn,
    uint256 amountIn,
    uint256 minUsdcOut,
    uint256 deadline,
    bytes calldata routerCommands,
    bytes[] calldata routerInputs,
    uint8 v,
    bytes32 r,
    bytes32 s
) external noReentrancy;
```

Behavior:

- Does not accept ETH (tokenIn == ETH_ALIAS reverts).
- Uses `PERMIT2.permitTransferFrom` to pull tokenIn from the user based on ECDSA signature (v,r,s) and deadline.
- If `tokenIn == USDC`, credits 1:1: `usdcReceived = amountIn`.
- Otherwise:
  - Calls `_swapExactInputSingle` with tokenIn and amountIn.
  - Enforces slippage: `usdcReceived >= minUsdcOut`.
  - Enforces bank cap using usdcBefore and usdcReceived.
- Credits `balances[msg.sender] += usdcReceived`.
- Emits `DepositedUSDC(msg.sender, tokenIn, amountIn, usdcReceived)`.

#### 1.3.3 withdrawUsdc

```solidity
function withdrawUsdc(uint256 amountUsdc) external noReentrancy;
```

- Requires `amountUsdc > 0` (ZeroAmountNotAllowed).
- Checks internal ledger: `balances[msg.sender] >= amountUsdc` (else InsufficientBalance).
- Updates state before transferring out:
  - `balances[msg.sender] -= amountUsdc`.
  - `withdrawCount++`.
- Transfers USDC to user using `USDC.safeTransfer(msg.sender, amountUsdc)`.
- Emits `WithdrawnUSDC(msg.sender, amountUsdc)`.

#### 1.3.4 recoverFunds

```solidity
function recoverFunds(
    address user,
    uint256 newBalanceUsdc
) external onlyRole(MANAGER_ROLE);
```

Administrative function to correct internal ledger.

- Allows a manager to set `balances[user] = newBalanceUsdc`.
- Emits `FundsRecovered(manager, user, newBalanceUsdc)`.

#### 1.3.5 ETH Handling

- Contract defines a special ETH_ALIAS address for identifying ETH deposits.
- Direct ETH transfers (`receive() external payable`) are rejected with DirectEthTransferNotAllowed.
- ETH must go through depositArbitraryToken with `tokenIn = ETH_ALIAS`.

## 2. Protocol Maturity Assessment

### 2.1 Code Quality and Architecture

**Positive aspects:**

- Uses Solidity 0.8.30, benefitting from built-in overflow checks.
- Employs OpenZeppelin AccessControl for role management.
- Uses SafeERC20 for ERC-20 interactions.
- Core configuration is immutable, preventing post-deployment address changes for USDC, Router, Permit2 and Price Feed.
- Clean separation of responsibilities:
  - Deposit flows.
  - Withdraw flow.
  - Admin tooling (recoverFunds).
  - Internal helpers (`_pullTokenFromUser`, `_swapExactInputSingle`, `_enforceBankCap`).
- Custom errors improve revert clarity and gas efficiency.

**Limitations:**

- No pausing / emergency escape hatch for deposit/withdraw.
- No upgradeability or versioned migration path.
- Strong reliance on correct off-chain configuration (addresses for USDC, Router, Permit2, PriceFeed).

### 2.2 Test Coverage

From KipuBank.t.sol, the following is covered:

**Constructor**

- Happy path deployment.
- Reverts when critical addresses are zero (USDC, router, permit2, price feed, admin).
- Revert when BANK_CAP is zero.

**USDC Deposits (approve + depositArbitraryToken)**

- Single and multiple deposits.
- Multiple users depositing USDC.
- Zero amount deposit error.

**Permit2 Deposits**

- USDC deposits via Permit2.
- Rejection of ETH via depositWithPermit2.

**Non-USDC Deposits with Slippage Guard**

- Simulated swap output lower than minUsdcOut → revert with InsufficientSwapOutput.

**Withdrawals**

- Partial and full withdrawals.
- Zero amount withdraw error.
- Insufficient balance error.

**Bank Cap**

- Deposits within cap.
- Deposits exceeding cap revert.
- Withdrawals free up capacity for future deposits.

**Admin / recoverFunds**

- Manager can correct user balance.
- Non-manager cannot call recoverFunds.

**Events**

- DepositedUSDC, WithdrawnUSDC, FundsRecovered emission is tested.

**View functions**

- totalUsdcInVault, balanceOfUsdc, remainingCapacityUsdc, getEthUsdPrice.

**Direct ETH transfer**

- Direct ETH transfers revert as expected.

**Missing/testing gaps:**

- No fuzz testing (randomized inputs) or invariant tests.
- No mainnet-fork integration tests with real:
  - Uniswap Universal Router,
  - Permit2,
  - Live USDC,
  - Real Chainlink aggregator.
- No stress tests for large numbers of deposits/withdrawals, or edge cases around BANK_CAP.
- No tests around weird ERC-20 tokens (fee-on-transfer, non-standard return values).

### 2.3 Documentation

The contract has NatSpec-style comments explaining main flows and error conditions.

However, there is no standalone:

- Protocol whitepaper/specification document.
- Threat model or security considerations document (this report fills part of that gap).
- On-chain or off-chain user documentation (e.g., "how to interact via CLI/Front-end").

### 2.4 Actors and Privileges

**Regular User**

May call:

- depositArbitraryToken,
- depositWithPermit2,
- withdrawUsdc,
- View functions.

Cannot modify other users' balances directly.

Exposure:

- Potential slippage on swaps (user controls minUsdcOut).
- Potential router revert if commands/inputs are misconfigured.

**Admin / Manager**

Initially, the same address receives:

- DEFAULT_ADMIN_ROLE,
- MANAGER_ROLE.

With DEFAULT_ADMIN_ROLE, the admin can:

- Grant or revoke roles, including MANAGER_ROLE.

With MANAGER_ROLE, the admin can call:

- `recoverFunds(user, newBalanceUsdc)`.

This function is powerful: it can set any user's internal USDC balance to an arbitrary value. It does not move USDC tokens; it only adjusts accounting, but combined with withdrawUsdc it can lead to vault depletion if abused.

### 2.5 Overall Maturity

I would classify KipuBankV3 as:

**Pre-production / audit-ready prototype**

**Strengths:**

- Clear and simple design.
- Explicit cap on TVL.
- Explicit roles and error types.
- Solid unit test coverage for main flows.

**What is still missing for full "production-grade" maturity:**

- Invariant/fuzz tests.
- Mainnet-fork integration tests with real dependencies.
- Operational security practices (multisig for admin, deploy procedures, monitoring).
- External audit and/or bug bounty program.

## 3. Threat Model and Attack Vectors

### 3.1 Threat Model Summary

**Trusted components:**

- USDC contract address configured at deployment (assumed to be standard 6-dec ERC-20 stablecoin).
- Uniswap Universal Router and Permit2 contracts (assumed canonical and secure).
- Chainlink ETH/USD feed (assumed canonical).

**Untrusted inputs:**

- External users (deposit, withdraw, pass router commands).
- routerCommands and routerInputs provided by users.
- Network environment (MEV, front-running, pool manipulation).

**Privileged roles:**

- Admin / Manager keys (AccessControl).

### 3.2 Attack Surface 1 – Misconfiguration and Admin Key Compromise

**Scenario A: Misconfigured USDC address**

If the deployer accidentally configures USDC as:

- A token with decimals ≠ 6, or
- A fee-on-transfer token, or
- A malicious token with non-standard behavior,

then the following risks appear:

For direct USDC deposits (depositArbitraryToken / depositWithPermit2 with tokenIn == address(USDC)), the code assumes 1:1 credit:

- `usdcReceived = amountIn`.

If the token takes a fee on transfer, the vault's actual token balance increases by less than amountIn, but the internal ledger credits the full amountIn.

Over time, this can cause insolvency:

- Sum of user balances > vault balance.
- Withdrawals may start to fail or deplete the vault faster than expected.

**Scenario B: Compromised MANAGER_ROLE / DEFAULT_ADMIN_ROLE**

A compromised admin/manager key can:

- Call `recoverFunds(attacker, hugeAmount)` to set the attacker's balance to any value.
- Immediately call `withdrawUsdc(hugeAmount)`.
- Drain all USDC from the vault (subject only to current token balance).

**Category mapping:**

- Permission / access-control misconfiguration.
- Business logic assumption (admin is honest, USDC is standard).

**Mitigations:**

- Use a multisig for admin/manager roles.
- Deploy only with well-known, audited addresses (canonical USDC, canonical Uniswap/Chainlink contracts).
- Restrict or document the intended use of recoverFunds (e.g., internal incident recovery only).

### 3.3 Attack Surface 2 – Swap Behavior and Router Misuse

**Scenario: Malicious or mis-specified Universal Router**

The vault calls `UNIVERSAL_ROUTER.execute(...)` in:

- depositArbitraryToken for non-USDC deposits and ETH deposits.
- `_swapExactInputSingle` for non-USDC tokens.

The code only grants allowance to the router for tokenIn, not for USDC. This mitigates router draining USDC directly via transferFrom.

However, if UNIVERSAL_ROUTER is misconfigured to a malicious contract, it could:

- Revert systematically, making non-USDC deposits unusable (DoS on certain deposit paths).
- Attempt to perform other unexpected external calls.

**Reentrancy risk:**

- The routing path could, in theory, try to re-enter KipuBank, but all state-changing external functions are protected by the noReentrancy modifier.
- Reentrancy into other contracts is outside the scope of KipuBank but still part of the overall environment.

**Category mapping:**

- Abuse of protocol assumptions (router assumed canonical and honest).
- Economic / operational risk (DoS on routing/deposits if wrong router is set).

**Mitigations:**

- Lock UNIVERSAL_ROUTER to the canonical Uniswap deployment address.
- Validate router behavior on mainnet-fork before mainnet deployment.
- Consider allowing only pre-defined route templates in higher-level code, rather than arbitrary routerCommands provided by end users.

### 3.4 Attack Surface 3 – Accounting and Cap Enforcement

**Scenario A: Bank cap logic**

In both deposit flows:

The protocol calculates:

- `usdcBefore = USDC.balanceOf(this)`.
- `usdcReceived` as USDC delta (for non-USDC) or as amountIn (for USDC).
- Enforces cap: `_enforceBankCap(usdcBefore, usdcReceived)`.

If there is any path where:

- USDC leaves the vault without a corresponding decrease in user balances, or
- USDC enters the vault without being tracked in balances,

the following may occur:

- `totalUsdcInVault()` may diverge from the sum of internal balances.
- The cap check could become misleading:

  Example: tokens sent directly to the contract (without going through depositArbitraryToken) increase USDC balance but not user balances, artificially reducing remainingCapacityUsdc.

This can create situations where:

- Deposits are rejected due to cap even though no user actually owns that USDC (it was mistakenly or maliciously transferred to the vault).
- Conversely, if recoverFunds sets user balances higher than the actual vault balance, vault insolvency is possible.

**Category mapping:**

- Logic / accounting errors.
- Abuse of implicit assumptions (all USDC in the contract comes from valid deposits).

**Mitigations:**

- Treat direct USDC transfers as an operational incident and use recoverFunds to correct.
- Monitor on-chain metrics (sum of balances vs. USDC balance) to detect divergence.
- Consider adding an admin-controlled sweep function to move "untracked" USDC (that is not assigned to any user) to a treasury, with strong off-chain procedures.

### 3.5 Attack Surface 4 – User-Level Economic Risks (MEV / Slippage)

Even if not strictly protocol-breaking:

Users that set `minUsdcOut = 0` or very low may be exposed to:

- Sandwich attacks,
- Poor execution on illiquid pools.

This does not break protocol solvency (the vault measures actual usdcReceived) but can impact individual depositor's economic outcome.

**Mitigations:**

- Front-end UX:
  - Provide fair defaults for minUsdcOut.
  - Warn users about high slippage.
- Possible future invariant: "Protocol never credits more than actual usdcReceived" (already enforced by design).

## 4. Invariants Specification

Below are at least three key invariants that should always hold, assuming no malicious admin behavior and correct configuration.

### Invariant 1 – Bank Cap Safety

**I1 – Total USDC never exceeds BANK_CAP.**

**Formal statement:**

For all states reachable via valid function calls:

```
totalUsdcInVault() <= BANK_CAP
```

where:

```solidity
function totalUsdcInVault() public view returns (uint256) {
    return USDC.balanceOf(address(this));
}
```

**Impact if violated:**

If `USDC.balanceOf(this) > BANK_CAP`, the protocol violates its TVL limit.

This breaks the core design assumption that the bank is capped and may impact risk management, regulatory constraints, or insurance assumptions.

**Validation approach:**

- Already enforced in code via `_enforceBankCap(usdcBefore, usdcReceived)`.
- Should be validated via:
  - Invariant tests (Foundry `invariant_` tests).
  - Fuzzing deposit flows with random inputs and routes.
  - Mainnet-fork testing under realistic conditions.

### Invariant 2 – Individual Balance Solvency at Withdrawal

**I2 – A user can never withdraw more USDC than their internal balance, and internal balances never become negative.**

**Formal statement:**

For all users u and all transactions:

- `balances[u]` is always >= 0 (uint256 ensures this).
- `withdrawUsdc(amount)` requires `amount <= balances[msg.sender]`.

**Impact if violated:**

If a user could withdraw more than `balances[u]`, the internal accounting would be inconsistent and could lead to vault insolvency.

Negative balances are prevented by Solidity's safe math, but logical errors could still cause under-accounting.

**Validation approach:**

Test cases already cover:

- Withdraw with insufficient balance reverts.
- Zero amounts revert.

Invariant/fuzz tests should:

- Randomly interleave deposits/withdraws and verify that `balances[u]` always matches the net flows.
- Check that `balances[u]` never overflows or becomes inconsistent.

### Invariant 3 – Ledger vs Vault Relationship (Soft Invariant)

**I3 – The vault must always hold enough USDC to cover the sum of all user balances, except during admin recovery operations.**

This can be defined as:

Let L = sum(balances[u]) over all users u.

Let V = USDC.balanceOf(address(this)).

Then under normal operation (no recoverFunds manipulation):

```
L <= V
```

**Because:**

- Deposits increase both:
  - Vault USDC balance (V),
  - User internal balance (L).
- Withdrawals decrease both:
  - Vault USDC balance (V),
  - User internal balance (L).
- No other function should move USDC or change balances in a way that violates this relationship.

**Impact if violated:**

- If L > V:
  - The vault is under-collateralized: some users may not be able to withdraw fully.
- If L << V:
  - There is "idle" USDC that is not accounted to any user.
  - This may be acceptable but should be a conscious design choice (e.g., protocol fees).

**Validation approach:**

Implement invariant tests that:

- Track a finite set of test users and approximate L (summing their balances).
- Check L <= V after each sequence of operations (except when recoverFunds is explicitly used for simulation of correction scenarios).
- Operationally, monitor this relationship off-chain using indexers.

### Invariant 4 – Slippage Guard (Function-Level Invariant)

**I4 – For non-USDC deposits via router, credited USDC must be at least minUsdcOut.**

**Formal statement:**

In depositArbitraryToken and depositWithPermit2, when tokenIn != USDC:

```solidity
require(usdcReceived >= minUsdcOut);
```

**Impact if violated:**

Depositors could be credited with less USDC than expected, even though they requested a minimum.

This would break user-level guarantees and undermine trust in the deposit mechanism.

**Validation approach:**

- Already enforced with InsufficientSwapOutput revert.
- Fuzz tests with varying minUsdcOut, swap outputs, and router behavior can validate this invariant.

### Invariant 5 – Reentrancy Lock Integrity

**I5 – The locked flag must always be false at the end of any external call.**

**Formal statement:**

For every external function decorated with noReentrancy:

- `_noReentrancyBefore()` sets `locked = true` (or reverts if already true).
- `_noReentrancyAfter()` sets `locked = false`.

Therefore, after any successful external call, `locked == false`.

**Impact if violated:**

- If locked is left true:
  - All further state-changing calls protected by noReentrancy will revert, causing a protocol-wide DoS.
- If locked could be bypassed:
  - Reentrancy attacks could be mounted on deposit or withdraw flows.

**Validation approach:**

Add invariant tests that:

- Randomly call deposit/withdraw functions.
- After each sequence, assert `locked == false` via a testing accessor or via behavior (second call should not revert if it is not reentrant).

## 5. Impact of Invariant Violations

For each key invariant:

**I1 (Cap Safety):**

- Violation means TVL exceeds BANK_CAP.
- Risk: operational, financial and reputational damage (breach of promised cap).

**I2 (Individual Solvency):**

- Violation means a user could drain more than they own.
- Direct risk of loss of funds for the protocol or other users.

**I3 (Ledger vs Vault):**

- L > V implies insolvency, where withdrawals start reverting or partial funds become unbacked.
- L < V implies unassigned USDC, which could be misinterpreted or mishandled.

**I4 (Slippage Guard):**

- Violation means the protocol breaks a key user protection, making it unsafe to rely on minUsdcOut.
- Could allow subtle economic exploits on unsuspecting users.

**I5 (Reentrancy Lock):**

- Violations can lead either to a DoS (if stuck = true) or reentrancy risk (if bypassed).

## 6. Recommendations – Validating and Strengthening Invariants

### 6.1 Testing Improvements

**Invariant Tests (Foundry)**

Implement `invariant_` functions that:

- Check `totalUsdcInVault() <= BANK_CAP`.
- Track a set of test accounts and verify `sum(balances) <= USDC.balanceOf(address(this))`.
- Assert reentrancy lock integrity (`locked == false` at the end of calls).

**Fuzz Testing**

Fuzz:

- amountIn, minUsdcOut, deadline, and token addresses (within a controlled set of mock tokens).
- Sequences of depositArbitraryToken, depositWithPermit2, withdrawUsdc.

Ensure no unexpected reverts and that invariants continue to hold.

**Mainnet-Fork Integration Tests**

Test with real:

- USDC.
- Uniswap Universal Router and Permit2.
- Chainlink ETH/USD feed.

Validate deposit/withdraw flows with realistic liquidity and gas conditions.

### 6.2 Operational and Governance Recommendations

- Use a multisig for admin and manager roles; avoid EOA single key.
- Establish operational procedures for:
  - Recovering from mis-sent tokens or direct transfers,
  - Using recoverFunds only under clear, documented conditions.
- Consider adding:
  - A pause mechanism to halt deposits/withdraws in case of emergencies.
  - An explicit mechanism to handle "untracked" USDC (fees, donations, or admin sweep).

### 6.3 Documentation and Communication

Produce a short protocol specification describing:

- Supported tokens,
- Expected decimals,
- Dependencies (Uniswap and Chainlink addresses),
- Admin powers and responsibilities.

Publish a user-facing doc explaining:

- Slippage, minOut and MEV risks.
- How deposits and withdrawals work.

### 6.4 External Review

Once the above steps are implemented:

- Run static analysis tools (Slither, Mythril, etc.).
- Request an external audit.
- Optionally run a small bug bounty program before increasing BANK_CAP to a significant amount.

## 7. Conclusion and Next Steps

KipuBankV3 is a clean, focused USDC vault that demonstrates good security practices:

- Clear separation of roles and responsibilities.
- Explicit TVL cap (BANK_CAP).
- Reentrancy protection on all state-changing external functions.
- Safe ERC-20 interactions and custom errors for key failure modes.
- A reasonably complete unit-test suite for core flows.

However, for mainnet readiness, the following steps are recommended:

- Implement invariant and fuzz tests to validate the core safety properties described above.
- Add mainnet-fork tests with real dependencies to catch integration issues early.
- Strengthen operational security (multisig, deployment checklists, monitoring).
- Improve documentation (specification, threat model, user docs).
- Undergo at least one independent audit, and consider a limited bug bounty.

By following these steps, KipuBankV3 moves from a solid prototype to a protocol that is meaningfully prepared for a production deployment on mainnet.
