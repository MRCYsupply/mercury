// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IRandomnessSource, IRandomnessConsumer} from "../interfaces/IRandomnessSource.sol";
import {IDrandBeacon} from "./drand/IDrandBeacon.sol";

/// @title DrandSource — trustless RNG adapter backed by drand `evmnet`
/// @notice The final Mercury RNG (ADR 2026-05-29-vrf-drand-anyrand).
///         Randomness comes from the drand `evmnet` beacon
///         (`bls-bn254-unchained-on-g1`, period 3s). Each game round is
///         bound to a specific *future* drand round at request time; the
///         round is only resolved once someone relays that round's BLS
///         signature, which is verified on-chain against the pinned
///         public key by the audited `DrandBeacon` (frogworks/anyrand,
///         audit 2024-10-14).
///
/// @dev    Trust model:
///         - **Outcome is trustless.** A drand signature is unforgeable
///           and is verified on-chain before it can resolve a round. No
///           operator, relayer, or miner can choose or bias the result.
///         - **Liveness is permissionless.** Anyone may call `fulfill`
///           with the beacon signature, so a censoring relayer cannot
///           stall the game indefinitely.
///         - **Unpredictable.** The bound drand round is strictly in the
///           future at request time (its signature does not yet exist),
///           so players cannot know the outcome while a round is open.
///
/// @dev    No provider fee: `quoteFee()` is 0, so `GridMining.settle()`
///         forwards no value and player deposits are never touched. The
///         relayer pays only gas for `fulfill`.
contract DrandSource is IRandomnessSource, Ownable2Step {
    /// @notice The pinned drand `evmnet` beacon (audited verifier).
    IDrandBeacon public immutable beacon;

    /// @notice The wired consumer (GridMining).
    IRandomnessConsumer public consumer;

    /// @notice Monotonic request counter.
    uint256 public lastRequestId;

    struct Request {
        uint64 gameRound; // GridMining round id
        uint64 drandRound; // the exact beacon round that may fulfill this request
        bool pending;
    }

    /// @notice requestId → request.
    mapping(uint256 => Request) public requests;

    event ConsumerSet(address indexed consumer);
    event RandomnessRequested(
        uint256 indexed requestId, uint64 indexed gameRound, uint64 drandRound
    );
    event RandomnessFulfilled(
        uint256 indexed requestId, uint64 indexed gameRound, uint256 randomWord
    );

    error NotConsumer();
    error ConsumerAlreadySet();
    error ZeroAddress();
    error UnknownRequest(uint256 requestId);
    error BeaconNotReady(uint64 drandRound, uint256 producedAt);

    constructor(address initialOwner, IDrandBeacon beacon_) Ownable(initialOwner) {
        if (address(beacon_) == address(0)) revert ZeroAddress();
        beacon = beacon_;
    }

    /// @notice Wire the consumer once (GridMining). Immutable thereafter.
    function setConsumer(IRandomnessConsumer c) external onlyOwner {
        if (address(consumer) != address(0)) revert ConsumerAlreadySet();
        if (address(c) == address(0)) revert ZeroAddress();
        consumer = c;
        emit ConsumerSet(address(c));
    }

    /// @inheritdoc IRandomnessSource
    function quoteFee() external pure returns (uint256) {
        return 0; // drand: no provider fee, relayer pays gas only
    }

    /// @notice The drand round bound to a request made at `timestamp`.
    /// @dev The first beacon STRICTLY in the future: round `cur+1`, whose
    ///      scheduled time `> timestamp`, so its signature is not yet
    ///      produced and cannot be known when the request is made.
    function drandRoundFor(uint256 timestamp) public view returns (uint64) {
        uint256 genesis = beacon.genesisTimestamp();
        uint256 period = beacon.period();
        uint256 elapsed = timestamp - genesis; // settle always happens well after genesis
        // current round = elapsed / period + 1 ; target = current + 1
        return uint64(elapsed / period + 2);
    }

    /// @notice The unix timestamp at which a drand round is scheduled.
    function roundTimestamp(uint64 drandRound) public view returns (uint256) {
        return beacon.genesisTimestamp() + (uint256(drandRound) - 1) * beacon.period();
    }

    /// @inheritdoc IRandomnessSource
    /// @dev Only the wired consumer (GridMining) may request. Binds the
    ///      request to a future drand round; never reverts on external
    ///      conditions so it cannot brick `settle()`.
    function requestRandomness(uint64 roundId) external payable returns (uint256 requestId) {
        if (msg.sender != address(consumer)) revert NotConsumer();
        requestId = ++lastRequestId;
        uint64 target = drandRoundFor(block.timestamp);
        requests[requestId] = Request({gameRound: roundId, drandRound: target, pending: true});
        emit RandomnessRequested(requestId, roundId, target);
    }

    /// @notice Permissionless: relay the drand beacon signature for the
    ///         exact round bound to `requestId`. Reverts unless the BLS
    ///         signature verifies against the pinned `evmnet` public key,
    ///         so a wrong/forged/wrong-round signature cannot resolve the
    ///         round.
    /// @param requestId The request to fulfill.
    /// @param signature The drand `evmnet` G1 signature (x, y) for the
    ///        bound round, as returned by the drand HTTP API.
    function fulfill(uint256 requestId, uint256[2] calldata signature) external {
        Request memory r = requests[requestId];
        if (!r.pending) revert UnknownRequest(requestId);

        // The bound beacon round must already be scheduled (produced).
        // A valid signature can't exist before then anyway; this just
        // returns a clear error instead of an opaque verification revert.
        uint256 producedAt = roundTimestamp(r.drandRound);
        if (block.timestamp < producedAt) revert BeaconNotReady(r.drandRound, producedAt);

        // Audited on-chain BLS verification. Reverts on any invalid,
        // forged, or wrong-round signature.
        beacon.verifyBeaconRound(uint256(r.drandRound), signature);

        // The verified, unforgeable signature is the entropy. Namespaced
        // by request/round so two requests can never collide.
        uint256 randomWord =
            uint256(keccak256(abi.encodePacked(signature[0], signature[1], requestId, r.gameRound)));

        // CEI: clear state before the external callback.
        requests[requestId].pending = false;

        emit RandomnessFulfilled(requestId, r.gameRound, randomWord);
        consumer.fulfillRandomness(requestId, randomWord);
    }
}
