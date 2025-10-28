// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal Permit2 mock.
/// @dev This mock ignores signature validation and simply transfers tokens
///      from the `owner` to `to`. It's enough for testing the "1 tx deposit"
///      flow without needing an ERC20.approve first.
contract MockPermit2 {
    function permitTransferFrom(
        address owner,
        address token,
        uint256 amount,
        address to,
        uint256 /*permitDeadline*/,
        uint8 /*v*/,
        bytes32 /*r*/,
        bytes32 /*s*/
    ) external {
        // Mint directly to the recipient if the token supports it; otherwise, fallback to transferFrom.
        (bool ok, ) = token.call(
            abi.encodeWithSignature("mint(address,uint256)", to, amount)
        );
        if (!ok) {
            bool success = IERC20(token).transferFrom(owner, to, amount);
            require(success, "transferFrom failed");
        }
    }
}
