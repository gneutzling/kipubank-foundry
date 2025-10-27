// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract MockPermit2 {
    function permitTransferFrom(
        address owner,
        address token,
        uint256 amount,
        address to,
        uint256,
        uint8,
        bytes32,
        bytes32
    ) external {
        IERC20(token).transferFrom(owner, to, amount);
    }
}
