// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title ITreasury — the slice of Treasury that GridMining depends on
/// @notice GridMining forwards the per-round vault fee (a cut of the
///         losers' pool, plus the whole pot on a no-winner round) to
///         the Treasury, which batches it into a Hyperswap buyback.
///         Full Treasury surface lands in T3.1.3.
interface ITreasury {
    /// @notice Receive HYPE destined for the buyback vault. Treasury
    ///         restricts the caller to GridMining.
    function receiveVault() external payable;
}
