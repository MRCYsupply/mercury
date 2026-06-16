// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IHyperswapRouter — Uniswap-V2-style router subset
/// @notice The Treasury routes its buyback through Hyperswap. Modelled
///         on V2 `swapExactETHForTokens`. If Hyperswap is V3 on mainnet
///         the adapter swaps to `exactInputSingle` behind this same
///         call site — the slippage math (minOut) is unchanged.
interface IHyperswapRouter {
    /// @notice Swap exact native HYPE in for $MRCY out.
    /// @param amountOutMin Minimum $MRCY to receive (slippage floor).
    /// @param path [WHYPE, MRCY].
    /// @param to Recipient of the bought $MRCY.
    /// @param deadline Unix deadline.
    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    /// @notice Constant-product quote across `path` for `amountIn` (V2
    ///         `getAmountsOut`, price impact + fee included). Treasury sizes
    ///         the buyback `minOut` from this — the realistic, achievable
    ///         output — rather than a linear spot/TWAP quote, which overstates
    ///         output on a shallow pool and would make the swap revert.
    /// @return amounts `amounts[0] == amountIn`, `amounts[last]` = output.
    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);
}
