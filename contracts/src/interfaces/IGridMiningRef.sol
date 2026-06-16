// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title IGridMiningRef — minimal mining-engine view used by AffiliateRegistry
/// @notice The affiliate registry only needs to know how many rounds an address
///         has played: it gates code creation (≥1 round) and the binding
///         acquisition window. The mining engine itself is not part of this
///         published interface — only this single, side-effect-free view.
interface IGridMiningRef {
    /// @notice Number of rounds `player` has participated in.
    function roundsPlayedOf(address player) external view returns (uint256);
}
