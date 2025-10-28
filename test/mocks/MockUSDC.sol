// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    /// @notice Override decimals to mimic real USDC (6 decimals)
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Mint helper for tests
    /// @dev Anyone can mint in tests; this is NOT production-safe.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
