// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title Randomness source / consumer interfaces
/// @notice Decouples `GridMining` from the concrete RNG implementation
///         (Pyth Entropy V2 primary, commit-reveal fallback). See
///         an accepted internal design decision.

interface IRandomnessSource {
    /// @notice Request randomness for a round. Returns an opaque
    ///         requestId the source echoes in its callback. Payable to
    ///         forward any provider fee (Pyth charges; commit-reveal
    ///         does not).
    function requestRandomness(uint64 roundId) external payable returns (uint256 requestId);

    /// @notice Upfront fee for a request, in wei of native HYPE. 0 for
    ///         sources that don't charge.
    function quoteFee() external view returns (uint256);
}

interface IRandomnessConsumer {
    /// @notice Called back by the randomness source. Implementations
    ///         MUST restrict the caller to the configured source.
    function fulfillRandomness(uint256 requestId, uint256 randomWord) external;
}
