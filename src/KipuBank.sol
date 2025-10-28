// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @title KipuBank
 * @notice Simple USDC vault that accepts ERC20 tokens and ETH, swaps to USDC,
 *         and tracks user balances in 6‑decimal USDC units.
 *
 * Key points:
 *  - Supports ERC20 and native ETH deposits.
 *  - Swaps deposits to USDC via Uniswap Universal Router; credits users in USDC (6 decimals).
 *  - Global USDC cap (BANK_CAP) limits total TVL (Total Value Locked).
 *  - Optional Chainlink ETH/USD feed for observability.
 *  - Two deposit paths: standard ERC20 approval or Uniswap Permit2 signature.
 *
 * Safety:
 *  - Enforces bank cap and slippage + deadline on swaps.
 *  - No persistent infinite approvals (scoped per call).
 *  - Reentrancy guard on external state-changing functions.
 *  - AccessControl roles for admin/manager recovery.
 */

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";

import {AggregatorV3Interface} from "chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/// @notice Minimal interface for Uniswap Universal Router.
/// The router:
///  - pulls approved tokens from this contract,
///  - executes the encoded swap/wrap/sweep sequence,
///  - returns USDC to this contract.
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
/// This models the permit-based transfer used by the deposit flow.
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

    /// @dev Native ETH address alias (0xEeee... convention).
    address public constant ETH_ALIAS =
        0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // ========= Immutable Configuration =========

    /// @notice USDC-like asset used for accounting (assumed 6 decimals).
    IERC20 public immutable USDC;

    /// @notice Maximum assets managed, in USDC (6 decimals).
    uint256 public immutable BANK_CAP;

    /// @notice Uniswap Universal Router used for swaps.
    IUniversalRouter public immutable UNIVERSAL_ROUTER;

    /// @notice Uniswap Permit2 contract used for signature-based deposits.
    IPermit2 public immutable PERMIT2;

    /// @notice Chainlink ETH/USD feed for observability.
    AggregatorV3Interface public immutable ETH_USD_PRICE_FEED;

    // ========= State =========

    /// @dev Maps user to their USDC balance.
    mapping(address => uint256) public balances;

    /// @dev Simple audit counters.
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
    error DirectEthTransferNotAllowed();

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
     * @param _usdc            USDC token address
     * @param _bankCapUsdc     Global USDC cap (6 decimals)
     * @param _universalRouter Uniswap Universal Router address
     * @param _permit2         Uniswap Permit2 address
     * @param _ethUsdPriceFeed Chainlink ETH/USD feed address
     * @param _admin           Admin address (gets DEFAULT_ADMIN_ROLE and MANAGER_ROLE)
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

    /// @notice User's USDC balance (6 decimals).
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
    // Two deposit methods:
    // 1) depositArbitraryToken: user approves; we pull and optionally swap to USDC.
    // 2) depositWithPermit2: user signs a permit; we pull and optionally swap to USDC.
    // Both: enforce BANK_CAP, credit USDC balance, and apply slippage/deadline guards.

    /**
     * @notice Deposit ERC20 or ETH and receive USDC credit.
     *
     * Cases:
     *  - USDC: pull and credit 1:1.
     *  - ETH_ALIAS: msg.value must equal amountIn; router swaps to USDC.
     *  - Other ERC20: pull via safeTransferFrom; swap to USDC with scoped allowance.
     *
     * Afterward: enforce BANK_CAP, apply slippage checks, and update user balance.
     *
     * @param tokenIn        USDC, ETH_ALIAS, or any ERC20.
     * @param amountIn       Amount of tokenIn (must equal msg.value for ETH_ALIAS).
     * @param minUsdcOut     Minimum acceptable USDC (slippage guard).
     * @param deadline       Latest execution time for the router.
     * @param routerCommands Encoded Universal Router command sequence.
     * @param routerInputs   ABI-encoded inputs for each command.
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

        // USDC balance of the vault BEFORE any modifications
        uint256 usdcBefore = USDC.balanceOf(address(this));

        uint256 usdcReceived;
        address actualTokenIn = tokenIn;

        if (tokenIn == ETH_ALIAS) {
            if (msg.value != amountIn) {
                revert EthValueMismatch(amountIn, msg.value);
            }

            // execute route using sent ETH
            UNIVERSAL_ROUTER.execute{value: amountIn}(
                routerCommands,
                routerInputs,
                deadline
            );

            // how much USDC actually came in
            uint256 usdcAfter = USDC.balanceOf(address(this));
            usdcReceived = usdcAfter - usdcBefore;
        } else if (tokenIn == address(USDC)) {
            _pullTokenFromUser(tokenIn, msg.sender, amountIn);
            usdcReceived = amountIn;
        } else if (tokenIn != address(0)) {
            _pullTokenFromUser(tokenIn, msg.sender, amountIn);

            // swap tokenIn -> USDC
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

        // slippage check if it was not a direct USDC deposit
        if (actualTokenIn != address(USDC) && usdcReceived < minUsdcOut) {
            revert InsufficientSwapOutput(minUsdcOut, usdcReceived);
        }

        // check CAP using the balance that existed before + what is coming in now
        _enforceBankCap(usdcBefore, usdcReceived);

        // credit internal ledger only after passing the cap
        balances[msg.sender] += usdcReceived;

        depositCount++;

        emit DepositedUSDC(msg.sender, actualTokenIn, amountIn, usdcReceived);
    }

    /**
     * @notice Deposit using Uniswap Permit2 (no prior ERC20.approve needed).
     *
     * Flow:
     *  - User signs a Permit2 authorization for `tokenIn` and `amountIn` until `deadline`.
     *  - We submit the signature; Permit2 transfers `tokenIn` here.
     *  - If needed, swap to USDC, then enforce BANK_CAP and slippage.
     *
     * Limitation:
     *  - Does not accept native ETH; use depositArbitraryToken with ETH_ALIAS.
     *
     * @param tokenIn        ERC20 token (not ETH_ALIAS).
     * @param amountIn       Amount authorized by the Permit2 signature.
     * @param minUsdcOut     Minimum acceptable USDC (slippage guard).
     * @param deadline       Permit2 expiry and router swap deadline.
     * @param routerCommands Encoded Universal Router command sequence.
     * @param routerInputs   ABI-encoded inputs per command.
     * @param v              ECDSA v.
     * @param r              ECDSA r.
     * @param s              ECDSA s.
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

        // USDC balance of the vault before
        uint256 usdcBefore = USDC.balanceOf(address(this));

        // 1. pull tokens via Permit2
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

        // 2. convert to USDC if needed
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

        // 3. slippage guard if not direct USDC
        if (tokenIn != address(USDC) && usdcReceived < minUsdcOut) {
            revert InsufficientSwapOutput(minUsdcOut, usdcReceived);
        }

        // 4. enforce cap using before + received
        _enforceBankCap(usdcBefore, usdcReceived);

        // 5. credit after passing the cap
        balances[msg.sender] += usdcReceived;

        depositCount++;

        emit DepositedUSDC(msg.sender, tokenIn, amountIn, usdcReceived);
    }

    // ========= Withdraw / Admin =========

    /**
     * @notice Withdraw USDC from the user's balance.
     * @dev Balances are in USDC (6 decimals).
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
     * @notice Manager (MANAGER_ROLE) can set a user's USDC balance.
     * @dev Used to correct balances.
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
     * @notice Rejects direct ETH transfers.
     * @dev Use depositArbitraryToken with ETH_ALIAS for ETH deposits.
     */
    receive() external payable {
        revert DirectEthTransferNotAllowed();
    }

    // ========= Internal Helpers =========

    /**
     * @dev Ensures total USDC does not exceed BANK_CAP.
     *      Reverts if before + incomingUsdc > BANK_CAP.
     */
    function _enforceBankCap(
        uint256 beforeBalance,
        uint256 incomingUsdc
    ) internal view {
        uint256 projected = beforeBalance + incomingUsdc;

        if (projected > BANK_CAP) {
            revert BankCapacityExceeded(beforeBalance, incomingUsdc, BANK_CAP);
        }
    }

    /**
     * @dev Pulls `amount` of `token` from `from` address into this contract.
     *      Requires prior ERC20 approval. Permit2 path uses a signed permit instead.
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
     * @dev Swaps `amountIn` of `tokenIn` (held by this contract) to USDC via Universal Router.
     *      Uses scoped allowance and computes USDC delta after execution.
     *      Deadline prevents stale execution.
     * @return usdcReceived Incremental USDC received by this contract.
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

        // Scope allowance: reset to 0, then approve exactly amountIn.
        require(
            token.approve(address(UNIVERSAL_ROUTER), 0),
            "approve reset failed"
        );
        require(
            token.approve(address(UNIVERSAL_ROUTER), amountIn),
            "approve failed"
        );

        // Router pulls tokenIn, executes swaps, and returns USDC here.
        UNIVERSAL_ROUTER.execute(routerCommands, routerInputs, deadline);

        uint256 balanceAfter = USDC.balanceOf(address(this));
        usdcReceived = balanceAfter - balanceBefore;
    }
}
