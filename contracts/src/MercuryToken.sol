// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

import {Governable} from "./Governable.sol";
import {IHyperswapPair} from "./interfaces/IHyperswapPair.sol";

/// @title MercuryToken (MRCY)
/// @notice Cap-bound ERC20 with EIP-2612 permit, revocable-then-frozen
///         minter authority, and an embedded 5-snapshot reserve-based
///         TWAP buffer used by `Treasury` to floor buyback slippage.
/// @dev    Port of BEAN's `Bean.sol` pattern. See `docs/CONTRACTS.md` §4
///         and `docs/TOKENOMICS.md` §2 for the numerical anchors. All
///         numeric magic in this file traces back to TOKENOMICS.md.
contract MercuryToken is ERC20, ERC20Permit, Governable {
    // ---------------------------------------------------------------
    //                          Constants
    // ---------------------------------------------------------------

    /// @notice Absolute ceiling the admin can never raise MAX_SUPPLY past.
    ///         10× the genesis cap — bounds the worst-case dilution lever
    ///         even before MAX_SUPPLY is frozen. Hard constant.
    uint256 public constant MAX_SUPPLY_CEILING = 20_059_000 * 1e18;

    /// @notice Number of snapshots in the TWAP ring buffer. Structural
    ///         (sizes the storage array) — intentionally NOT tunable.
    /// @dev    `docs/TOKENOMICS.md` §2 — BEAN-port.
    uint8 public constant TWAP_SNAPSHOT_COUNT = 5;

    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant PRICE_PRECISION = 1e18;

    /// @dev Freeze keys (see Governable).
    bytes32 public constant KEY_MAX_SUPPLY = keccak256("MRCY_MAX_SUPPLY");
    bytes32 public constant KEY_TWAP_DEVIATION = keccak256("MRCY_TWAP_DEVIATION");
    bytes32 public constant KEY_SNAPSHOT_INTERVAL = keccak256("MRCY_SNAPSHOT_INTERVAL");

    // ---------------------------------------------------------------
    //                      Tunable economic params
    // ---------------------------------------------------------------

    /// @notice Hard cap on $MRCY supply (cumulative-mint ceiling, true-burn).
    /// @dev    Genesis: atomic weight 200.59 × 10⁴ = 2,005,900 (TOKENOMICS.md
    ///         §2). Admin-tunable within [totalMinted, MAX_SUPPLY_CEILING];
    ///         freezable via KEY_MAX_SUPPLY. Intended to be frozen at mainnet
    ///         to preserve the fair-launch promise.
    uint256 public MAX_SUPPLY = 2_005_900 * 1e18;

    /// @notice Max tolerated deviation between spot and TWAP price (bps).
    ///         Above this, Treasury reverts the buyback (flash-loan guard).
    /// @dev    Genesis: atomic number 80 × 10 = 800 bps. Admin-tunable up to
    ///         BPS_DENOMINATOR; freezable via KEY_TWAP_DEVIATION.
    uint256 public MAX_TWAP_DEVIATION_BPS = 800;

    // ---------------------------------------------------------------
    //                       Mint authority
    // ---------------------------------------------------------------

    /// @notice Address authorized to call `mint`. Typically `GridMining`
    ///         once deployed.
    address public minter;

    /// @notice Once true, `setMinter` is permanently disabled.
    bool public minterFrozen;

    /// @notice Monotonic count of all $MRCY ever minted. NEVER decreases
    ///         on burn. The hard cap is a *cumulative-mint* ceiling
    ///         (true burn): once `totalMinted == MAX_SUPPLY`, emission
    ///         stops forever and burned supply is gone for good — it does
    ///         NOT reopen mint headroom (that would be ORE-style "bury").
    ///         Locked by the coordinator + DIFFERENTIATION.md +
    ///         TOKENOMICS.md §5.4 + the tokenomics-v1 ADR.
    uint256 public totalMinted;

    // ---------------------------------------------------------------
    //                          TWAP state
    // ---------------------------------------------------------------

    struct Snapshot {
        uint112 reserve0;
        uint112 reserve1;
        uint32 blockTimestampLast;
    }

    /// @notice MRCY/HYPE Hyperswap pair.
    IHyperswapPair public pair;

    /// @notice True iff `address(this)` is `pair.token0()`. Cached at
    ///         `setPair` so we don't pay an external call per read.
    bool public isMrcyToken0;

    /// @notice Minimum seconds between snapshots. Anyone can call
    ///         `updateReserveSnapshot` but it no-ops within this window.
    /// @dev    `docs/TOKENOMICS.md` §2: 60s (= 4 rounds of 15s).
    uint32 public minSnapshotInterval = 60;

    /// @notice Ring buffer of reserves. Filled clockwise.
    Snapshot[TWAP_SNAPSHOT_COUNT] public reserveHistory;

    /// @notice Position of the next slot to be written.
    uint8 public currentSnapshotIndex;

    /// @notice Number of snapshots ever written, capped at
    ///         `TWAP_SNAPSHOT_COUNT`. Used as the readiness gate.
    uint8 public snapshotsTaken;

    /// @notice Wall-clock seconds at which the most recent snapshot was
    ///         written. Drives the rate limit.
    uint32 public lastSnapshotAt;

    // ---------------------------------------------------------------
    //                            Events
    // ---------------------------------------------------------------

    event MinterChanged(address indexed previous, address indexed current);
    event MinterFrozen();
    event PairChanged(address indexed previous, address indexed current);
    event MinSnapshotIntervalChanged(uint32 previous, uint32 current);
    event MaxSupplyChanged(uint256 previous, uint256 current);
    event MaxTwapDeviationChanged(uint256 previous, uint256 current);
    event ReserveSnapshotted(
        uint8 indexed index,
        uint112 reserve0,
        uint112 reserve1,
        uint32 timestamp
    );

    // ---------------------------------------------------------------
    //                            Errors
    // ---------------------------------------------------------------

    error NotMinter();
    error MinterAlreadyFrozen();
    error MintCapExceeded(uint256 attempted, uint256 cap);
    error PairNotSet();
    error PairNotSeeded();
    error PairAlreadySet();
    error SnapshotIntervalNotElapsed(uint32 nextAllowedAt);
    error TWAPNotReady(uint8 snapshotsTaken);
    error TokenMismatch();
    error MaxSupplyBelowMinted(uint256 requested, uint256 minted);
    error MaxSupplyAboveCeiling(uint256 requested, uint256 ceiling);
    error TwapDeviationTooHigh(uint256 requested, uint256 max);

    // ---------------------------------------------------------------
    //                          Constructor
    // ---------------------------------------------------------------

    constructor(address initialOwner)
        ERC20("Mercury", "MRCY")
        ERC20Permit("Mercury")
        Governable(initialOwner)
    {}

    // ---------------------------------------------------------------
    //                   Economic-param admin surface
    // ---------------------------------------------------------------

    /// @notice Re-tune the supply hard cap. Bounded: cannot drop below
    ///         what has already been minted (would otherwise strand mint
    ///         accounting), nor exceed MAX_SUPPLY_CEILING. Freezable via
    ///         KEY_MAX_SUPPLY.
    function setMaxSupply(uint256 newMaxSupply) external onlyOwner notFrozen(KEY_MAX_SUPPLY) {
        if (newMaxSupply < totalMinted) revert MaxSupplyBelowMinted(newMaxSupply, totalMinted);
        if (newMaxSupply > MAX_SUPPLY_CEILING) revert MaxSupplyAboveCeiling(newMaxSupply, MAX_SUPPLY_CEILING);
        emit MaxSupplyChanged(MAX_SUPPLY, newMaxSupply);
        MAX_SUPPLY = newMaxSupply;
    }

    /// @notice Re-tune the TWAP deviation guard (bps). Bounded by
    ///         BPS_DENOMINATOR. Freezable via KEY_TWAP_DEVIATION.
    function setMaxTwapDeviation(uint256 newBps) external onlyOwner notFrozen(KEY_TWAP_DEVIATION) {
        if (newBps > BPS_DENOMINATOR) revert TwapDeviationTooHigh(newBps, BPS_DENOMINATOR);
        emit MaxTwapDeviationChanged(MAX_TWAP_DEVIATION_BPS, newBps);
        MAX_TWAP_DEVIATION_BPS = newBps;
    }

    // ---------------------------------------------------------------
    //                      Mint authority surface
    // ---------------------------------------------------------------

    /// @notice Mint $MRCY. Restricted to the current minter. Reverts if
    ///         the cumulative amount ever minted would exceed
    ///         `MAX_SUPPLY`. True-burn semantics: the ceiling is on
    ///         lifetime mint, NOT on live `totalSupply()`, so burns do
    ///         not reopen mint headroom.
    function mint(address to, uint256 amount) external {
        if (msg.sender != minter) revert NotMinter();
        uint256 mintedAfter = totalMinted + amount;
        if (mintedAfter > MAX_SUPPLY) revert MintCapExceeded(mintedAfter, MAX_SUPPLY);
        totalMinted = mintedAfter;
        _mint(to, amount);
    }

    /// @notice Remaining mint headroom under the cap: the largest `amount`
    ///         for which `mint` would NOT revert `MintCapExceeded`. Single
    ///         source of truth for cap-fit checks — callers that want to mint
    ///         without reverting (e.g. GridMining.claimAll deferral) gate on
    ///         `amount <= headroom()` rather than re-deriving the invariant.
    ///         Safe (never underflows): `totalMinted <= MAX_SUPPLY` always.
    function headroom() external view returns (uint256) {
        return MAX_SUPPLY - totalMinted;
    }

    /// @notice Burn $MRCY from the caller's balance. True burn — the
    ///         tokens are gone and the cumulative-mint ceiling does NOT
    ///         move, so this supply can never be re-minted.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /// @notice Burn $MRCY from `from`'s balance, spending the caller's
    ///         allowance. Used by `Treasury.executeBuyback` to remove
    ///         the 90% slice from circulation in a single call.
    function burnFrom(address from, uint256 amount) external {
        _spendAllowance(from, msg.sender, amount);
        _burn(from, amount);
    }

    /// @notice Replace the minter. No-op until `freezeMinter` is called,
    ///         at which point the minter becomes immutable.
    function setMinter(address newMinter) external onlyOwner {
        if (minterFrozen) revert MinterAlreadyFrozen();
        address prev = minter;
        minter = newMinter;
        emit MinterChanged(prev, newMinter);
    }

    /// @notice Lock the minter forever. Mint authority can never be
    ///         transferred again.
    function freezeMinter() external onlyOwner {
        if (minterFrozen) revert MinterAlreadyFrozen();
        minterFrozen = true;
        emit MinterFrozen();
    }

    // ---------------------------------------------------------------
    //                       Pair / TWAP admin
    // ---------------------------------------------------------------

    /// @notice Wire the Hyperswap MRCY/HYPE pair. One-shot — bulldozing
    ///         the existing pair would corrupt the snapshot buffer and
    ///         is therefore disallowed. To rotate the pair, deploy a
    ///         fresh token (mainnet ops decision).
    function setPair(address newPair) external onlyOwner {
        if (address(pair) != address(0)) revert PairAlreadySet();
        IHyperswapPair p = IHyperswapPair(newPair);
        address t0 = p.token0();
        address t1 = p.token1();
        if (t0 != address(this) && t1 != address(this)) revert TokenMismatch();
        pair = p;
        isMrcyToken0 = (t0 == address(this));
        emit PairChanged(address(0), newPair);
    }

    /// @notice Tune the rate-limit between snapshots. Multisig only.
    function setMinSnapshotInterval(uint32 newInterval) external onlyOwner notFrozen(KEY_SNAPSHOT_INTERVAL) {
        uint32 prev = minSnapshotInterval;
        minSnapshotInterval = newInterval;
        emit MinSnapshotIntervalChanged(prev, newInterval);
    }

    // ---------------------------------------------------------------
    //                       TWAP write surface
    // ---------------------------------------------------------------

    /// @notice Capture a fresh reserve snapshot from the pair. Anyone
    ///         can call. Rate-limited by `minSnapshotInterval`. The
    ///         buffer fills sequentially, then rotates.
    function updateReserveSnapshot() external {
        if (address(pair) == address(0)) revert PairNotSet();

        uint32 nowTs = uint32(block.timestamp);
        // Gate on snapshotsTaken (not lastSnapshotAt != 0): a first
        // snapshot at block.timestamp == 0 would leave lastSnapshotAt at
        // 0 and silently bypass the rate limit on the next call.
        if (snapshotsTaken > 0 && nowTs < lastSnapshotAt + minSnapshotInterval) {
            revert SnapshotIntervalNotElapsed(lastSnapshotAt + minSnapshotInterval);
        }

        (uint112 r0, uint112 r1, uint32 ts) = pair.getReserves();
        // F-009: refuse zero-reserve snapshots — they poison the buffer
        // average during bootstrap (or any extreme drain). Treasury's
        // buyback would mis-quote and accept dramatic slippage.
        if (r0 == 0 || r1 == 0) revert PairNotSeeded();
        uint8 idx = currentSnapshotIndex;
        reserveHistory[idx] = Snapshot({reserve0: r0, reserve1: r1, blockTimestampLast: ts});

        currentSnapshotIndex = (idx + 1) % TWAP_SNAPSHOT_COUNT;
        if (snapshotsTaken < TWAP_SNAPSHOT_COUNT) {
            snapshotsTaken += 1;
        }
        lastSnapshotAt = nowTs;

        emit ReserveSnapshotted(idx, r0, r1, ts);
    }

    // ---------------------------------------------------------------
    //                       TWAP read surface
    // ---------------------------------------------------------------

    /// @notice True iff the buffer holds `TWAP_SNAPSHOT_COUNT` entries.
    function isTWAPReady() public view returns (bool) {
        return snapshotsTaken == TWAP_SNAPSHOT_COUNT;
    }

    /// @notice Arithmetic average of the buffered reserves, oriented to
    ///         the pair (NOT to MRCY). Use `_readAverageMrcyHype` for
    ///         the MRCY-oriented view.
    /// @dev    Returns (0, 0) if no snapshots have been taken yet.
    function calculateAverageReserves()
        public
        view
        returns (uint112 avgReserve0, uint112 avgReserve1)
    {
        uint8 n = snapshotsTaken;
        if (n == 0) return (0, 0);
        uint256 sum0;
        uint256 sum1;
        for (uint8 i = 0; i < n; i++) {
            Snapshot memory s = reserveHistory[i];
            sum0 += s.reserve0;
            sum1 += s.reserve1;
        }
        avgReserve0 = uint112(sum0 / n);
        avgReserve1 = uint112(sum1 / n);
    }

    /// @notice Quote `hypeAmountIn` of HYPE into MRCY using the buffer
    ///         average. Reverts if the TWAP is not ready — Treasury
    ///         catches this and refuses to swap until the buffer fills.
    function getTWAPAmountOut(uint256 hypeAmountIn)
        external
        view
        returns (uint256 mrcyAmountOut)
    {
        if (!isTWAPReady()) revert TWAPNotReady(snapshotsTaken);
        (uint256 avgMrcy, uint256 avgHype) = _readAverageMrcyHype();
        if (avgHype == 0) return 0;
        mrcyAmountOut = (hypeAmountIn * avgMrcy) / avgHype;
    }

    /// @notice Compare the current spot price to the buffer average.
    /// @return currentRatio  Price of HYPE per MRCY at the current
    ///                       reserves, scaled by `PRICE_PRECISION`.
    /// @return twapRatio     Same ratio over the buffer average.
    /// @return deviationBps  `|currentRatio - twapRatio| / twapRatio`
    ///                       in basis points. Returns 0 if `twapRatio`
    ///                       is zero (no data).
    function getPriceDeviation()
        external
        view
        returns (uint256 currentRatio, uint256 twapRatio, uint256 deviationBps)
    {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (uint256 curMrcy, uint256 curHype) = _orientMrcyHype(r0, r1);
        currentRatio = curMrcy == 0 ? 0 : (curHype * PRICE_PRECISION) / curMrcy;

        (uint256 avgMrcy, uint256 avgHype) = _readAverageMrcyHype();
        twapRatio = avgMrcy == 0 ? 0 : (avgHype * PRICE_PRECISION) / avgMrcy;

        if (twapRatio == 0) {
            deviationBps = 0;
        } else {
            uint256 diff = currentRatio > twapRatio
                ? currentRatio - twapRatio
                : twapRatio - currentRatio;
            deviationBps = (diff * BPS_DENOMINATOR) / twapRatio;
        }
    }

    // ---------------------------------------------------------------
    //                           Internals
    // ---------------------------------------------------------------

    function _readAverageMrcyHype()
        internal
        view
        returns (uint256 avgMrcy, uint256 avgHype)
    {
        (uint112 a0, uint112 a1) = calculateAverageReserves();
        (avgMrcy, avgHype) = _orientMrcyHype(a0, a1);
    }

    function _orientMrcyHype(uint112 r0, uint112 r1)
        internal
        view
        returns (uint256 mrcyReserve, uint256 hypeReserve)
    {
        if (isMrcyToken0) {
            mrcyReserve = uint256(r0);
            hypeReserve = uint256(r1);
        } else {
            mrcyReserve = uint256(r1);
            hypeReserve = uint256(r0);
        }
    }
}
