// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @title KipuBankV3
 * @notice Educational DeFi vault that:
 *  - accepts arbitrary ERC20 (and ETH),
 *  - swaps them to USDC using Uniswap (Universal Router),
 *  - credits user balances in USDC,
 *  - and enforces a global bank cap in USDC.
 *
 * High-level goals:
 *  - Users always end up with a USDC-denominated balance.
 *  - The bank never holds more than BANK_CAP USDC (AUM limit).
 *  - Owner/manager can still recover balances if needed.
 *
 * Important:
 *  - All internal accounting is in USDC (6 decimals).
 *  - Bank cap is defined in USDC units.
 *  - We keep a Chainlink price feed reference to satisfy the "preserve V2 functionality"
 *    requirement, although withdrawals are simplified to USDC only.
 */

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";

// Chainlink price feed interface (kept for spec continuity)
import {AggregatorV3Interface} from "chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

// Uniswap V4-style router interface placeholder.
// We'll refine the interface when we wire swap logic.
interface IUniversalRouter {
    function execute(
        bytes calldata commands,
        bytes[] calldata inputs
    ) external payable;
}

// Permit2 placeholder interface (will be filled when we actually use it)
interface IPermit2 {
    // we'll add exact function sigs we need later
}

contract KipuBankV3 is AccessControl {
    using SafeERC20 for IERC20;

    // ========= Roles =========
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    // We still expose an ETH alias for deposits of native ETH.
    address public constant ETH_ALIAS =
        0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // ========= Immutable Config =========

    // The single asset we account in (USDC, 6 decimals expected).
    IERC20 public immutable USDC;

    // Max total USDC the vault is allowed to custody.
    uint256 public immutable BANK_CAP;

    // Uniswap's universal router to perform swaps from arbitrary tokens -> USDC.
    IUniversalRouter public immutable UNIVERSAL_ROUTER;

    // Permit2 contract (gas-efficient approvals / pull funds).
    IPermit2 public immutable PERMIT2;

    // Chainlink ETH/USD feed (kept for legacy compatibility with V2 requirements).
    AggregatorV3Interface public immutable ETH_USD_PRICE_FEED;

    // ========= State =========

    // User balances, always denominated in USDC.
    // In V2 it was balances[user][token]; V3 simplifies to only USDC.
    mapping(address => uint256) public balances;

    // simple counters for telemetry / auditability
    uint256 public depositCount;
    uint256 public withdrawCount;

    // basic reentrancy guard
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

    // ========= Errors =========

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

    // ========= Modifiers =========

    modifier noReentrancy() {
        if (locked) revert ReentrancyDetected();
        locked = true;
        _;
        locked = false;
    }

    // ========= Constructor =========

    constructor(
        address _usdc,
        uint256 _bankCapUsdc, // cap in 6-decimal USDC units
        address _universalRouter,
        address _permit2,
        address _ethUsdPriceFeed,
        address _admin // gets DEFAULT_ADMIN_ROLE and MANAGER_ROLE
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

    // ========= Views =========

    /// @notice Total USDC actually held by the contract.
    function totalUsdcInVault() public view returns (uint256) {
        return USDC.balanceOf(address(this));
    }

    /// @notice USDC balance credited to a specific user.
    function balanceOfUsdc(address user) external view returns (uint256) {
        return balances[user];
    }

    /// @notice How much room (in USDC units) is left before hitting BANK_CAP.
    function remainingCapacityUsdc() external view returns (uint256) {
        uint256 current = USDC.balanceOf(address(this));
        return current >= BANK_CAP ? 0 : (BANK_CAP - current);
    }

    // ========= Core external functions (to implement next) =========

    /**
     * @notice Deposit any supported token.
     *
     * If tokenIn == USDC:
     *   - pull USDC directly from sender
     *   - enforce BANK_CAP
     *   - credit balances[sender]
     *
     * Else:
     *   - pull tokenIn
     *   - swap -> USDC via universalRouter
     *   - enforce BANK_CAP
     *   - credit balances[sender]
     *
     * @dev minUsdcOut is slippage protection.
     */
    function depositArbitraryToken(
        address tokenIn,
        uint256 amountIn,
        uint256 minUsdcOut,
        bytes calldata routerCommands,
        bytes[] calldata routerInputs
    ) external noReentrancy {
        // implementation will come in next step
        // we'll:
        // 1. require(amountIn > 0)
        // 2. pull tokenIn from msg.sender (via SafeERC20 for now)
        // 3. if tokenIn != address(USDC), run universalRouter.execute(...)
        // 4. measure how much USDC arrived (must be >= minUsdcOut)
        // 5. _enforceBankCap(usdcReceived)
        // 6. balances[msg.sender] += usdcReceived
        // 7. emit DepositedUSDC(...)
        // 8. depositCount++
    }

    /**
     * @notice Withdraw USDC.
     */
    function withdrawUsdc(uint256 amountUsdc) external noReentrancy {
        if (amountUsdc == 0) revert ZeroAmountNotAllowed();

        uint256 bal = balances[msg.sender];
        if (bal < amountUsdc) {
            revert InsufficientBalance(amountUsdc, bal);
        }

        // effects
        balances[msg.sender] = bal - amountUsdc;
        withdrawCount++;

        // interaction
        USDC.safeTransfer(msg.sender, amountUsdc);

        emit WithdrawnUSDC(msg.sender, amountUsdc);
    }

    /**
     * @notice Manager can force-set someone's USDC balance.
     * Mirrors the "recoverFunds" spirit from V2.
     */
    function recoverFunds(
        address user,
        uint256 newBalanceUsdc
    ) external onlyRole(MANAGER_ROLE) {
        if (user == address(0)) revert ZeroAddressNotAllowed();
        balances[user] = newBalanceUsdc;
        emit FundsRecovered(msg.sender, user, newBalanceUsdc);
    }

    // ========= Internal helpers (will be added later) =========
    // - _pullTokenFromUser(address token, address from, uint256 amount)
    // - _swapToUSDCIfNeeded(...)
    // - (optional) _getEthUsdPrice() from Chainlink for legacy compatibility

    /**
     * @dev Reverts if adding `incomingUsdc` would push the vault above BANK_CAP.
     * We always measure cap in USDC units (6 decimals).
     */
    function _enforceBankCap(uint256 incomingUsdc) internal view {
        uint256 current = USDC.balanceOf(address(this));
        uint256 projected = current + incomingUsdc;

        if (projected > BANK_CAP) {
            revert BankCapacityExceeded(current, incomingUsdc, BANK_CAP);
        }
    }
}
