// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @title KipuBank
 * @notice USDC-denominated vault with on-chain token routing and AUM limits.
 *
 * Core properties:
 *  - Accepts arbitrary ERC20 tokens and native ETH.
 *  - Swaps all inbound assets into USDC via Uniswap's Universal Router.
 *  - Credits users internally in USDC units (6 decimals).
 *  - Enforces a global bank cap (BANK_CAP) measured in USDC.
 *  - Exposes a Chainlink ETH/USD oracle for observability and continuity with KipuBankV2.
 *  - Provides both an "ERC20 approval" deposit path and a "Permit2 signature" deposit path.
 *
 * Security posture:
 *  - Bank cap prevents uncontrolled TVL growth.
 *  - Slippage + deadline guard swaps.
 *  - No infinite approvals: allowances to the router are scoped per-call.
 *  - Reentrancy guard on all state-mutating external entrypoints.
 *  - AccessControl-based owner/manager role for recovery.
 *
 * This contract is educational in nature but follows production-lean patterns.
 */

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";

import {AggregatorV3Interface} from "chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/// @notice Minimal Universal Router interface.
/// The Universal Router is expected to:
///  - pull approved tokens from this contract,
///  - execute an encoded sequence of swap / wrap / sweep commands,
///  - send the resulting USDC back to this contract.
interface IUniversalRouter {
    function execute(
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external payable;
}

/// @notice Minimal Permit2 interface subset.
/// Permit2 lets a user authorize token spending via an off-chain signature,
/// instead of first issuing a direct `approve` to this contract.
///
/// NOTE: This is a pedagogical subset. The real Permit2 contract uses
/// structured data (PermitTransferFrom) with nonce management. For the
/// purposes of this exercise and clarity of integration, we model the
/// essential "pull with a signed permit" behavior.
interface IPermit2 {
    function permitTransferFrom(
        address owner,
        address token,
        uint256 amount,
        address to,
        uint256 permitDeadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}

contract KipuBank is AccessControl {
    using SafeERC20 for IERC20;

    // ========= Roles =========

    /// @dev Manager role can perform administrative recovery.
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    /// @dev Sentinel address used to represent native ETH in user-facing calls.
    ///      Matches the common 0xEeee... convention.
    address public constant ETH_ALIAS =
        0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // ========= Immutable Configuration =========

    /// @notice USDC-like asset used for accounting (assumed 6 decimals).
    IERC20 public immutable USDC;

    /// @notice Upper bound on total assets under management, in USDC units (6 decimals).
    uint256 public immutable BANK_CAP;

    /// @notice Uniswap Universal Router used for swaps.
    IUniversalRouter public immutable UNIVERSAL_ROUTER;

    /// @notice Uniswap Permit2 contract used for signature-based deposits.
    IPermit2 public immutable PERMIT2;

    /// @notice Chainlink ETH/USD feed for observability / continuity with V2.
    AggregatorV3Interface public immutable ETH_USD_PRICE_FEED;

    // ========= State =========

    /// @dev Internal ledger: user => credited USDC balance (6 decimals).
    ///      KipuBankV2 tracked balances per token; KipuBank consolidates to USDC only.
    mapping(address => uint256) public balances;

    /// @dev Simple telemetry / audit counters.
    uint256 public depositCount;
    uint256 public withdrawCount;

    /// @dev Reentrancy guard flag.
    bool private locked;

    // ========= Events =========

    event DepositedUSDC(
        address indexed user,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 usdcCredited
    );

    event WithdrawnUSDC(address indexed user, uint256 amountUsdc);

    event FundsRecovered(
        address indexed manager,
        address indexed user,
        uint256 newBalanceUsdc
    );

    // ========= Custom Errors =========

    error ZeroAmountNotAllowed();
    error BankCapacityExceeded(
        uint256 currentTotal,
        uint256 incoming,
        uint256 cap
    );
    error InsufficientBalance(uint256 requested, uint256 available);
    error ReentrancyDetected();
    error ZeroAddressNotAllowed();
    error ZeroBankCapNotAllowed();
    error InsufficientSwapOutput(uint256 expected, uint256 received);
    error EthValueMismatch(uint256 declared, uint256 actual);

    // ========= Modifiers =========

    modifier noReentrancy() {
        _noReentrancyBefore();
        _;
        _noReentrancyAfter();
    }

    function _noReentrancyBefore() internal {
        if (locked) revert ReentrancyDetected();
        locked = true;
    }

    function _noReentrancyAfter() internal {
        locked = false;
    }

    // ========= Constructor =========

    /**
     * @param _usdc              Address of the USDC token on the target network
     * @param _bankCapUsdc       Global TVL cap, denominated in USDC units (6 decimals)
     * @param _universalRouter   Deployed Universal Router address (Uniswap)
     * @param _permit2           Deployed Permit2 address (Uniswap)
     * @param _ethUsdPriceFeed   Chainlink ETH/USD price feed address
     * @param _admin             Admin/manager address that will receive DEFAULT_ADMIN_ROLE and MANAGER_ROLE
     */
    constructor(
        address _usdc,
        uint256 _bankCapUsdc,
        address _universalRouter,
        address _permit2,
        address _ethUsdPriceFeed,
        address _admin
    ) {
        if (
            _usdc == address(0) ||
            _universalRouter == address(0) ||
            _permit2 == address(0) ||
            _ethUsdPriceFeed == address(0) ||
            _admin == address(0)
        ) revert ZeroAddressNotAllowed();

        if (_bankCapUsdc == 0) revert ZeroBankCapNotAllowed();

        USDC = IERC20(_usdc);
        BANK_CAP = _bankCapUsdc;
        UNIVERSAL_ROUTER = IUniversalRouter(_universalRouter);
        PERMIT2 = IPermit2(_permit2);
        ETH_USD_PRICE_FEED = AggregatorV3Interface(_ethUsdPriceFeed);

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(MANAGER_ROLE, _admin);
    }

    // ========= View Functions =========

    /// @notice Total USDC currently custodied by the vault.
    function totalUsdcInVault() public view returns (uint256) {
        return USDC.balanceOf(address(this));
    }

    /// @notice User's internal USDC-denominated balance (6 decimals).
    function balanceOfUsdc(address user) external view returns (uint256) {
        return balances[user];
    }

    /// @notice Remaining capacity before hitting the global BANK_CAP.
    function remainingCapacityUsdc() external view returns (uint256) {
        uint256 current = USDC.balanceOf(address(this));
        return current >= BANK_CAP ? 0 : (BANK_CAP - current);
    }

    /// @notice Exposes latest ETH/USD price info from Chainlink.
    /// @dev KipuBankV2 exposed oracle data; we maintain that observability here.
    function getEthUsdPrice()
        external
        view
        returns (int256 price, uint8 decimals)
    {
        (, int256 answer, , , ) = ETH_USD_PRICE_FEED.latestRoundData();

        return (answer, ETH_USD_PRICE_FEED.decimals());
    }

    // ========= Deposit Flows =========
    //
    // We support two ways to deposit assets:
    //
    // 1. depositArbitraryToken (classic flow)
    //    - User first does ERC20.approve(KipuBank, amountIn).
    //    - We pull the tokens via safeTransferFrom.
    //
    // 2. depositWithPermit2 (signature-based flow)
    //    - User signs an off-chain Permit2 approval.
    //    - We execute that permit and pull the tokens in the same tx.
    //
    // Both paths:
    //  - Optionally swap tokenIn -> USDC via Universal Router.
    //  - Enforce BANK_CAP.
    //  - Credit caller's balance in USDC.
    //  - Slippage-protect and deadline-bound the swap.

    /**
     * @notice Deposit any supported asset (ERC20 or native ETH), get USDC credit.
     *
     * tokenIn cases:
     *
     *  - tokenIn == address(USDC):
     *      We simply pull USDC and credit it 1:1.
     *
     *  - tokenIn == ETH_ALIAS (0xEeee...EEeE):
     *      Caller must send native ETH in msg.value.
     *      UniversalRouter is invoked with that ETH to perform:
     *        WRAP_ETH -> SWAP_EXACT_IN -> USDC
     *
     *  - otherwise (any ERC20):
     *      Caller must have approved this contract to spend `amountIn`.
     *      We pull tokenIn via safeTransferFrom().
     *      We then swap tokenIn -> USDC through UniversalRouter using a
     *      scoped allowance (zero-then-set).
     *
     * After the swap (or direct credit if already USDC), we:
     *  - enforce BANK_CAP,
     *  - apply slippage checks,
     *  - update the user's USDC-denominated balance.
     *
     * @param tokenIn         Asset to deposit (USDC, ETH_ALIAS, or any ERC20).
     * @param amountIn        Amount of that asset.
     *                        For ETH_ALIAS deposits, must equal msg.value.
     * @param minUsdcOut      Minimum USDC the user is willing to receive (slippage guard).
     * @param deadline        Swap deadline. The router must execute before this timestamp.
     * @param routerCommands  Encoded UniversalRouter command sequence.
     *                        Off-chain build using Uniswap V4 types (PoolKey, Currency, etc).
     * @param routerInputs    Per-command ABI-encoded arguments consumed by each command.
     */
    function depositArbitraryToken(
        address tokenIn,
        uint256 amountIn,
        uint256 minUsdcOut,
        uint256 deadline,
        bytes calldata routerCommands,
        bytes[] calldata routerInputs
    ) external payable noReentrancy {
        if (amountIn == 0) revert ZeroAmountNotAllowed();

        uint256 usdcReceived;
        address actualTokenIn = tokenIn;

        // 1. Native ETH path
        if (tokenIn == ETH_ALIAS) {
            // Require correct msg.value to avoid "phantom" deposits.
            if (msg.value != amountIn) {
                revert EthValueMismatch(amountIn, msg.value);
            }

            uint256 balanceBefore = USDC.balanceOf(address(this));

            // Router executes provided commands with msg.value as input liquidity.
            // Off-chain supplied route should: wrap ETH -> swap to USDC -> return to this contract.
            UNIVERSAL_ROUTER.execute{value: amountIn}(
                routerCommands,
                routerInputs,
                deadline
            );

            uint256 balanceAfter = USDC.balanceOf(address(this));
            usdcReceived = balanceAfter - balanceBefore;

            // 2. Direct USDC path (no swap, just custody)
        } else if (tokenIn == address(USDC)) {
            _pullTokenFromUser(tokenIn, msg.sender, amountIn);
            usdcReceived = amountIn;

            // 3. Arbitrary ERC20 path
        } else if (tokenIn != address(0)) {
            _pullTokenFromUser(tokenIn, msg.sender, amountIn);

            usdcReceived = _swapExactInputSingle(
                tokenIn,
                amountIn,
                deadline,
                routerCommands,
                routerInputs
            );
        } else {
            revert ZeroAddressNotAllowed();
        }

        // Slippage check for routes that involved swapping.
        if (actualTokenIn != address(USDC) && usdcReceived < minUsdcOut) {
            revert InsufficientSwapOutput(minUsdcOut, usdcReceived);
        }

        // Enforce TVL cap BEFORE updating internal balances.
        _enforceBankCap(usdcReceived);

        // Credit user's internal ledger.
        balances[msg.sender] += usdcReceived;

        depositCount++;

        emit DepositedUSDC(msg.sender, actualTokenIn, amountIn, usdcReceived);
    }

    /**
     * @notice Deposit using Uniswap Permit2 instead of caller-side ERC20.approve().
     *
     * This path improves UX and safety:
     *  - The user signs an off-chain Permit2 authorization that says
     *    "KipuBank can pull up to amountIn of tokenIn until deadline".
     *  - We submit that signature here in the same tx.
     *  - Permit2 moves `amountIn` of `tokenIn` from the caller directly
     *    into this contract.
     *
     * After we custody `tokenIn`, we follow the same flow as depositArbitraryToken():
     *  - If tokenIn is USDC: credit directly.
     *  - Else: swap tokenIn -> USDC through UniversalRouter.
     *  - Enforce BANK_CAP.
     *  - Check slippage.
     *
     * NOTE:
     *  - This function does NOT handle native ETH. ETH deposits should go
     *    through depositArbitraryToken using ETH_ALIAS + msg.value.
     *  - This uses a simplified Permit2 interface for educational clarity.
     *
     * @param tokenIn         ERC20 token address being deposited (not ETH_ALIAS).
     * @param amountIn        Amount of tokenIn authorized by the Permit2 signature.
     * @param minUsdcOut      Minimum USDC the user is willing to receive.
     * @param deadline        Both:
     *                        - The Permit2 permit expiry,
     *                        - And the Universal Router swap deadline.
     * @param routerCommands  Encoded UniversalRouter command sequence.
     * @param routerInputs    Per-command ABI-encoded router inputs.
     * @param v               ECDSA sig v (from user's permit).
     * @param r               ECDSA sig r (from user's permit).
     * @param s               ECDSA sig s (from user's permit).
     */
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
    ) external noReentrancy {
        if (amountIn == 0) revert ZeroAmountNotAllowed();
        if (tokenIn == address(0) || tokenIn == ETH_ALIAS)
            revert ZeroAddressNotAllowed();

        // 1. Pull tokenIn from the user into this contract via Permit2.
        //    User authorized this transfer off-chain via signature.
        PERMIT2.permitTransferFrom(
            msg.sender,
            tokenIn,
            amountIn,
            address(this),
            deadline,
            v,
            r,
            s
        );

        // 2. Convert to USDC if needed.
        uint256 usdcReceived;
        if (tokenIn == address(USDC)) {
            usdcReceived = amountIn;
        } else {
            usdcReceived = _swapExactInputSingle(
                tokenIn,
                amountIn,
                deadline,
                routerCommands,
                routerInputs
            );
        }

        // 3. Slippage guard for non-USDC tokens.
        if (tokenIn != address(USDC) && usdcReceived < minUsdcOut) {
            revert InsufficientSwapOutput(minUsdcOut, usdcReceived);
        }

        // 4. Enforce vault capacity before credit.
        _enforceBankCap(usdcReceived);

        // 5. Credit internal ledger.
        balances[msg.sender] += usdcReceived;

        depositCount++;

        emit DepositedUSDC(msg.sender, tokenIn, amountIn, usdcReceived);
    }

    // ========= Withdraw / Admin =========

    /**
     * @notice Withdraw USDC from the user's internal balance.
     * @dev All internal balances are denominated in USDC.
     */
    function withdrawUsdc(uint256 amountUsdc) external noReentrancy {
        if (amountUsdc == 0) revert ZeroAmountNotAllowed();

        uint256 bal = balances[msg.sender];
        if (bal < amountUsdc) {
            revert InsufficientBalance(amountUsdc, bal);
        }

        balances[msg.sender] = bal - amountUsdc;
        withdrawCount++;

        USDC.safeTransfer(msg.sender, amountUsdc);

        emit WithdrawnUSDC(msg.sender, amountUsdc);
    }

    /**
     * @notice Manager override to correct a user's internal USDC balance.
     * @dev Mirrors KipuBankV2's "recoverFunds" capability.
     */
    function recoverFunds(
        address user,
        uint256 newBalanceUsdc
    ) external onlyRole(MANAGER_ROLE) {
        if (user == address(0)) revert ZeroAddressNotAllowed();

        balances[user] = newBalanceUsdc;

        emit FundsRecovered(msg.sender, user, newBalanceUsdc);
    }

    /**
     * @notice Plain ETH transfers are rejected.
     * @dev ETH deposits must go through depositArbitraryToken with ETH_ALIAS.
     */
    receive() external payable {
        revert("Use depositArbitraryToken with ETH_ALIAS");
    }

    // ========= Internal Helpers =========

    /**
     * @dev Ensures BANK_CAP (global TVL limit in USDC units) is not exceeded.
     *      Reverts if current holdings + incomingUsdc > BANK_CAP.
     */
    function _enforceBankCap(uint256 incomingUsdc) internal view {
        uint256 current = USDC.balanceOf(address(this));
        uint256 projected = current + incomingUsdc;
        if (projected > BANK_CAP) {
            revert BankCapacityExceeded(current, incomingUsdc, BANK_CAP);
        }
    }

    /**
     * @dev Pull `amount` of `token` from `from` into this contract.
     *      User must have approved this contract beforehand (classic ERC20 flow).
     *
     * NOTE: The Permit2-based path (`depositWithPermit2`) avoids this explicit
     *       approve() step and instead uses a signed permit to authorize transfer.
     */
    function _pullTokenFromUser(
        address token,
        address from,
        uint256 amount
    ) internal {
        if (token == address(0)) revert ZeroAddressNotAllowed();
        IERC20(token).safeTransferFrom(from, address(this), amount);
    }

    /**
     * @dev Swap `amountIn` of `tokenIn` (already custodied by this contract)
     *      into USDC via the Universal Router.
     *
     * The caller provides:
     *  - routerCommands: encoded "program" for UniversalRouter. It contains
     *    byte-level Commands / Actions that instruct the router how to route,
     *    wrap, and swap. These are typically composed off-chain using Uniswap
     *    V4 types like PoolKey and Currency.
     *
     *  - routerInputs: ABI-encoded per-command arguments consumed by each step
     *    in `routerCommands`.
     *
     * Execution model:
     *  1. We do a scoped allowance:
     *     - reset allowance to 0
     *     - approve exactly amountIn for the router
     *  2. UniversalRouter pulls `tokenIn` from this contract.
     *  3. Router executes the provided route and returns USDC to this contract.
     *  4. We compute the delta in USDC balance.
     *
     * Security considerations:
     *  - No infinite approvals left behind.
     *  - deadline ensures swaps cannot execute under stale market conditions.
     *
     * @return usdcReceived The incremental USDC obtained by this contract.
     */
    function _swapExactInputSingle(
        address tokenIn,
        uint256 amountIn,
        uint256 deadline,
        bytes calldata routerCommands,
        bytes[] calldata routerInputs
    ) internal returns (uint256 usdcReceived) {
        uint256 balanceBefore = USDC.balanceOf(address(this));

        IERC20 token = IERC20(tokenIn);

        // Reset then set allowance for exact amountIn.
        require(
            token.approve(address(UNIVERSAL_ROUTER), 0),
            "approve reset failed"
        );
        require(
            token.approve(address(UNIVERSAL_ROUTER), amountIn),
            "approve failed"
        );

        // Router will now:
        //  - pull tokenIn from this contract,
        //  - perform the swap(s),
        //  - send USDC back to this contract.
        UNIVERSAL_ROUTER.execute(routerCommands, routerInputs, deadline);

        uint256 balanceAfter = USDC.balanceOf(address(this));
        usdcReceived = balanceAfter - balanceBefore;
    }
}
