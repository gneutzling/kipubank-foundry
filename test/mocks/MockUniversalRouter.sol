// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract MockUniversalRouter {
    IERC20 public immutable USDC;

    constructor(address _usdc) {
        USDC = IERC20(_usdc);
    }

    function execute(
        bytes calldata,
        bytes[] calldata,
        uint256
    ) external payable {
        // For tests, we don't actually need to implement swapping
        // The contract just needs to exist
    }
}
