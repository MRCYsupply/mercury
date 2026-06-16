// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IAffiliateRegistry — pre-mainnet hook for v1.1 affiliate system
/// @notice Optional, off-by-default. v1 GridMining ships with a mutable
///         `affiliateRegistry` pointer (default address(0) = disabled).
///         v1.1 deploys a concrete AffiliateRegistry and wires it via
///         `GridMining.setAffiliateRegistry(...)`. This avoids a full
///         GridMining redeploy when affiliates ship later.
///
/// @dev    The user→referrer binding happens VIA THE REGISTRY DIRECTLY
///         (registry-side `setMyReferrer(code)` user-callable function,
///         not on GridMining). GridMining only consumes the registry at
///         settle time to slice a portion of each loser's vault
///         contribution to their referrer (winners untouched).
///
///         See the referral design notes for the
///         full design. v1 GridMining wraps every external call in
///         try/catch so a buggy or absent registry can NEVER brick
///         settle.
interface IAffiliateRegistry {
    /// @notice Bind `code` to `referee` on their first-deploy path. No-op
    ///         if the referee already has a code claimed, the code is
    ///         unknown, or owner == referee (self-affiliate). Called by
    ///         GridMining inside `deployWithCode` in try/catch — must
    ///         NEVER revert in a way that bricks the deploy.
    function claimCode(address referee, string calldata code) external;

    /// @notice Accrue HYPE (msg.value) to the affiliate of `referee`. If
    ///         `referee` has no claimed code, the registry MUST refund
    ///         the value to msg.sender so GridMining can fold it back
    ///         into the Treasury vault deposit.
    function accrueFor(address referee) external payable;

    /// @notice Returns the configured affiliate skim in basis points
    ///         (e.g. 50 = 0.5% of the loser-miner's vault cut). Used by
    ///         GridMining at settle time to compute the per-loser slice.
    ///         Capped to a protocol-level maximum on the registry side.
    function affiliateBps() external view returns (uint16);
}
