// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title Governable — 2-step ownable + granular per-parameter freeze
/// @notice Shared admin base for every Mercury contract. Gives operators
///         two complementary kill-switches:
///
///         1. **Granular freeze.** Each tunable parameter is tagged with a
///            `bytes32` key. `freezeParam(key)` permanently disables the
///            setter(s) guarded by that key (one-way; a frozen key can
///            never be un-frozen). Lets the team keep risky levers live
///            during the early/uncertain phase, then lock each one
///            individually as it stabilises.
///
///         2. **Global renounce.** `renounceOwnership()` (inherited from
///            OpenZeppelin `Ownable`) sets the owner to `address(0)`,
///            permanently revoking ALL admin authority on the contract in
///            one shot — after which it is fully immutable/trustless.
///
/// @dev    Mainnet credibility note: the fair-launch promise (no insiders,
///         fixed economics) is only as strong as what is frozen. The
///         intended end-state is to `freezeParam` the economic keys (fees,
///         cap, emission) — or `renounceOwnership` entirely — once the
///         protocol is stable. Until then, the owner (a multisig on
///         mainnet) can re-tune within the hard bounds enforced by each
///         setter.
abstract contract Governable is Ownable2Step {
    /// @notice key → frozen. Once true, never false again.
    mapping(bytes32 => bool) public paramFrozen;

    event ParamFrozen(bytes32 indexed key);

    error ParamIsFrozen(bytes32 key);
    /// @dev Shared bound-check errors for the bounded admin setters in every
    ///      inheriting contract. Selectors are signature-derived, so they are
    ///      identical wherever raised.
    error AboveMax(uint256 requested, uint256 max);
    error BelowMin(uint256 requested, uint256 min);

    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @dev Guards a setter. Reverts once the matching key is frozen.
    modifier notFrozen(bytes32 key) {
        if (paramFrozen[key]) revert ParamIsFrozen(key);
        _;
    }

    /// @notice Permanently lock the setter(s) guarded by `key`. One-way.
    ///         Idempotent (re-freezing a frozen key is a harmless no-op
    ///         that still emits, useful as an on-chain attestation).
    /// @dev    Freeze keys are namespaced per contract (e.g.
    ///         keccak256("GRID_FEES") vs keccak256("STAKING_TREASURY")) so
    ///         the same logical lever in two contracts can never collide.
    ///         Read frozen state directly via the public `paramFrozen` getter.
    function freezeParam(bytes32 key) external onlyOwner {
        paramFrozen[key] = true;
        emit ParamFrozen(key);
    }
}
