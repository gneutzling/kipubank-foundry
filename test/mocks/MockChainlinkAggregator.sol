// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Minimal mock of Chainlink AggregatorV3Interface.
/// @dev Returns a fixed ETH/USD price and fixed decimals (8),
///      matching what the KipuBank contract expects in tests.
contract MockChainlinkAggregator {
    function latestRoundData()
        external
        pure
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        // Pretend ETH = $2000.00 with 8 decimals (i.e. 2000 * 1e8)
        return (0, 2000e8, 0, 0, 0);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }
}
