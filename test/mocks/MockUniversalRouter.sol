// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Minimal mock of Uniswap's Universal Router for testing KipuBank.
/// @dev This does NOT perform real swaps. Instead, when `execute` is called,
///      it "credits" USDC to the vault by calling `mint(address,uint256)`
///      on the configured USDC mock contract. This lets tests simulate:
///        - successful swaps (large output)
///        - bad swaps / slippage (small output)
contract MockUniversalRouter {
    /// @notice Address of the mock USDC token contract (must expose mint()).
    address public usdc;

    /// @notice Address of the vault (the KipuBank instance under test).
    address public vault;

    /// @notice Amount of USDC that will be minted to `vault` on the next execute().
    uint256 public simulatedSwapOutput;

    constructor(address _usdc) {
        usdc = _usdc;
    }

    /// @notice Configure which address is considered the vault (the KipuBank contract).
    function setVault(address _vault) external {
        vault = _vault;
    }

    /// @notice changes which token is treated as USDC
    function setUsdc(address _usdc) external {
        usdc = _usdc;
    }

    /// @notice Configure the amount of USDC the router should "deliver" to the vault on swap.
    /// @dev Setting this lets you simulate good/bad swap rates on demand from tests.
    function setSimulatedSwapOutput(uint256 amount) external {
        simulatedSwapOutput = amount;
    }

    /// @notice Simulate a Uniswap Universal Router execution.
    /// @dev The real Universal Router:
    ///        - pulls tokens from the caller
    ///        - performs multi-step actions (wrap ETH, swap, sweep, etc.)
    ///        - returns final asset(s) to a recipient
    ///
    ///      Our mock just mints `simulatedSwapOutput` USDC to the vault.
    ///      If `simulatedSwapOutput` is zero, it does nothing (useful for tests
    ///      where tokenIn is already USDC and no swap is actually needed).
    function execute(
        bytes calldata, // commands
        bytes[] calldata, // inputs
        uint256 // deadline
    ) external payable {
        if (simulatedSwapOutput == 0) {
            // No-op path: represents cases where we deposit USDC directly
            // or where we intentionally don't simulate output.
            return;
        }

        require(vault != address(0), "vault not set");
        require(usdc != address(0), "usdc not set");

        // Call mint(vault, simulatedSwapOutput) on the mock USDC.
        // We deliberately use low-level call so we don't need to import MockUSDC here.
        (bool ok, ) = usdc.call(
            abi.encodeWithSignature(
                "mint(address,uint256)",
                vault,
                simulatedSwapOutput
            )
        );
        require(ok, "mint failed");
    }
}
