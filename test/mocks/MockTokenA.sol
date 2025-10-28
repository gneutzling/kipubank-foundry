// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/// @notice Generic ERC20 mock with 18 decimals.
/// @dev Used to simulate "any arbitrary token" that is NOT USDC.
contract MockTokenA is ERC20 {
    constructor() ERC20("Mock Token A", "TKA") {}

    /// @notice Mint helper for tests.
    /// @dev Anyone can mint. This would NOT be safe in production.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Override decimals to 18 to differ from USDC (6 decimals).
    function decimals() public pure override returns (uint8) {
        return 18;
    }
}
