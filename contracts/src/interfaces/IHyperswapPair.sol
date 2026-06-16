// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title Minimal Uniswap-V2-pair view interface
/// @notice Hyperswap V2-style LP pair (MRCY/HYPE) exposes the three views
///         we need to embed a TWAP inside `MercuryToken`. If Hyperswap
///         turns out to be V3-only on mainnet, this interface is swapped
///         for a tick-cumulative reader without touching MercuryToken's
///         storage layout — only `_readReserves()` would change.
interface IHyperswapPair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves()
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}
