// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title Pyth Entropy V2 — vendored minimal interface + consumer base
/// @notice Faithful to the official `@pythnetwork/entropy-sdk-solidity`
///         package (verified against docs.pyth.network/entropy,
///         2026-05-29). Vendored locally because Pyth Entropy is **not
///         deployed on HyperEVM** as of launch research
///         (per our launch RNG design) — so
///         we can't pull the npm package against a live deployment yet.
///         The shapes match the SDK exactly, so swapping to the real
///         package is a drop-in import change if/when Pyth ships on
///         HyperEVM.

/// @notice The subset of Pyth's `IEntropyV2` that the adapter uses.
interface IEntropyV2 {
    /// @notice Default-provider request fee, in wei of native gas token.
    function getFeeV2() external view returns (uint128);

    /// @notice Request randomness from the default provider. Entropy
    ///         calls `_entropyCallback` on the requester once revealed.
    function requestV2() external payable returns (uint64 sequenceNumber);
}

/// @notice Mirror of Pyth's `IEntropyConsumer` abstract base. A consumer
///         inherits this, overrides `getEntropy()` + `entropyCallback()`,
///         and Entropy invokes the public `_entropyCallback` dispatcher
///         (which enforces caller == Entropy) to deliver the result.
abstract contract IEntropyConsumer {
    /// @notice External entry the Entropy contract calls. Verifies the
    ///         caller is the configured Entropy, then dispatches to the
    ///         consumer's internal handler.
    function _entropyCallback(uint64 sequence, address provider, bytes32 randomNumber) external {
        address entropy = getEntropy();
        require(msg.sender == entropy, "Only the Entropy contract can call this function");
        entropyCallback(sequence, provider, randomNumber);
    }

    /// @notice Address of the Entropy contract this consumer trusts.
    function getEntropy() internal view virtual returns (address);

    /// @notice Consumer's randomness handler. Implemented by the adapter.
    function entropyCallback(uint64 sequence, address provider, bytes32 randomNumber)
        internal
        virtual;
}
