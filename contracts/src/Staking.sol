// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Governable} from "./Governable.sol";
import {MercuryToken} from "./MercuryToken.sol";

/// @title Staking — MasterChef accumulator over staked $MRCY
/// @notice Stake $MRCY, earn the Treasury's buyback yield slice (10% of
///         each buyback) pro-rata. A short post-deposit lockup
///         (`yieldLockup`) gates both `withdraw` and `claimYield` to defeat
///         just-in-time yield-sniping: because `executeBuyback` is
///         permissionless, without the lockup an attacker could atomically
///         deposit → trigger the buyback → claim → withdraw and siphon the
///         staker slice from long-term stakers. `compoundFor` is OUT of v1
///         out of v1 scope by design. Yield is paid in $MRCY.
/// @dev    Both the stake principal and the yield are $MRCY, so the
///         contract holds (totalStaked + undistributed yield) $MRCY.
///         Yield arrives pre-transferred by the Treasury immediately
///         before `distributeYield`, so the accumulator never promises
///         more than the contract holds.
contract Staking is Governable, ReentrancyGuard {
    uint256 internal constant ACC_PRECISION = 1e18;

    /// @dev Freeze keys (see Governable). freezeParam(KEY_*) locks the setter.
    bytes32 public constant KEY_TREASURY = keccak256("STAKING_TREASURY");
    bytes32 public constant KEY_MIN_STAKE = keccak256("STAKING_MIN_STAKE");
    bytes32 public constant KEY_LOCKUP = keccak256("STAKING_LOCKUP");

    /// @notice Upper bound the admin can set `minStake` to, so the lever can
    ///         never be used to lock out all staking. 1000 MRCY.
    uint256 public constant MAX_MIN_STAKE = 1_000e18;

    /// @notice Upper bound on `yieldLockup`, so the lever can never strand
    ///         stakers' funds for an unreasonable period. 7 days.
    uint256 public constant MAX_YIELD_LOCKUP = 7 days;

    MercuryToken public immutable mrcy;
    address public treasury; // only address allowed to distribute yield

    uint256 public accYieldPerShare; // 1e18 precision
    uint256 public totalStaked;

    /// @notice Minimum stake per deposit. Defense-in-depth against the
    ///         accumulator-inflation precondition (a dust staker spiking
    ///         accYieldPerShare). 0 = no minimum. Admin-tunable up to
    ///         MAX_MIN_STAKE; freezable via KEY_MIN_STAKE.
    uint256 public minStake;

    /// @notice Post-deposit lockup gating withdraw + claimYield. Defeats
    ///         JIT yield-sniping. Admin-tunable up to MAX_YIELD_LOCKUP;
    ///         freezable via KEY_LOCKUP. Default 1 hour.
    uint256 public yieldLockup = 1 hours;

    struct Stake {
        uint128 amount; // ≤ MAX_SUPPLY (2.0059e24) ⋘ 2^128, safe to pack
        uint64 lockedUntil; // earliest timestamp withdraw/claimYield is allowed
        // SECURITY: rewardDebt MUST be uint256. A dust-staker can inflate
        // accYieldPerShare (yield / tiny totalStaked) to ~1e37+, after which
        // `amount * acc / 1e18` for a normal stake exceeds 2^128. A uint128
        // rewardDebt would truncate silently, over-crediting pendingYield and
        // bricking withdraw/claim for the victim (principal locked forever).
        // See test/StakingGriefPoC.t.sol.
        uint256 rewardDebt;
    }
    mapping(address => Stake) public stakes;

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event YieldClaimed(address indexed user, uint256 amount);
    event YieldDistributed(uint256 amount, uint256 newAccPerShare);
    event TreasuryChanged(address indexed previous, address indexed current);
    event MinStakeChanged(uint256 previous, uint256 current);
    event YieldLockupChanged(uint256 previous, uint256 current);

    error NotTreasury();
    error NoStakers();
    error ZeroAmount();
    error BelowMinStake(uint256 amount, uint256 min);
    error InsufficientStake(uint256 have, uint256 want);
    error ZeroAddress();
    error StillLocked(uint256 unlockAt);
    // AboveMax(requested, max) is inherited from Governable.

    constructor(address initialOwner, MercuryToken mrcy_) Governable(initialOwner) {
        if (address(mrcy_) == address(0)) revert ZeroAddress();
        mrcy = mrcy_;
    }

    function setTreasury(address newTreasury) external onlyOwner notFrozen(KEY_TREASURY) {
        if (newTreasury == address(0)) revert ZeroAddress();
        emit TreasuryChanged(treasury, newTreasury);
        treasury = newTreasury;
    }

    /// @notice Set the minimum per-deposit stake. Bounded by MAX_MIN_STAKE.
    function setMinStake(uint256 newMinStake) external onlyOwner notFrozen(KEY_MIN_STAKE) {
        if (newMinStake > MAX_MIN_STAKE) revert AboveMax(newMinStake, MAX_MIN_STAKE);
        emit MinStakeChanged(minStake, newMinStake);
        minStake = newMinStake;
    }

    /// @notice Set the post-deposit yield/withdraw lockup. Bounded by
    ///         MAX_YIELD_LOCKUP (0 disables it). Freezable via KEY_LOCKUP.
    function setYieldLockup(uint256 newLockup) external onlyOwner notFrozen(KEY_LOCKUP) {
        if (newLockup > MAX_YIELD_LOCKUP) revert AboveMax(newLockup, MAX_YIELD_LOCKUP);
        emit YieldLockupChanged(yieldLockup, newLockup);
        yieldLockup = newLockup;
    }

    // ---------------------------------------------------------------
    //                          Stake surface
    // ---------------------------------------------------------------

    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (amount < minStake) revert BelowMinStake(amount, minStake);
        Stake storage s = stakes[msg.sender];
        // Deposit does NOT pay out pending yield (that would re-open the
        // JIT path: deposit → buyback → re-deposit-to-harvest, bypassing the
        // withdraw/claim lock). Instead, preserve existing pending EXACTLY by
        // recomputing rewardDebt from the new principal minus the pending owed
        // before this deposit. A floored `rewardDebt += amount*acc/1e18` would
        // over-credit pending by up to 1 wei per deposit (the floor carry of
        // `floor(x+y) - floor(x) - floor(y)`), which accumulates into a small
        // insolvency that can brick the last claimant's harvest — caught by
        // the staking solvency invariant (test/invariant/StakingInvariant).
        uint256 pendingBefore =
            (uint256(s.amount) * accYieldPerShare) / ACC_PRECISION - s.rewardDebt;
        s.amount += uint128(amount);
        totalStaked += amount;
        s.rewardDebt = (uint256(s.amount) * accYieldPerShare) / ACC_PRECISION - pendingBefore;
        // Re-arm the lockup on every deposit (covers the freshly added principal).
        s.lockedUntil = uint64(block.timestamp + yieldLockup);
        require(mrcy.transferFrom(msg.sender, address(this), amount), "transferFrom failed");
        emit Deposited(msg.sender, amount);
    }

    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Stake storage s = stakes[msg.sender];
        if (s.amount < amount) revert InsufficientStake(s.amount, amount);
        if (block.timestamp < s.lockedUntil) revert StillLocked(s.lockedUntil);
        _harvest(msg.sender);
        s.amount -= uint128(amount);
        totalStaked -= amount;
        s.rewardDebt = (uint256(s.amount) * accYieldPerShare) / ACC_PRECISION;
        require(mrcy.transfer(msg.sender, amount), "transfer failed");
        emit Withdrawn(msg.sender, amount);
    }

    function claimYield() external nonReentrant returns (uint256) {
        uint64 lockedUntil = stakes[msg.sender].lockedUntil;
        if (block.timestamp < lockedUntil) revert StillLocked(lockedUntil);
        return _harvest(msg.sender);
    }

    /// @notice Called by Treasury after it has transferred `amount`
    ///         $MRCY into this contract. Bumps the accumulator.
    function distributeYield(uint256 amount) external {
        if (msg.sender != treasury) revert NotTreasury();
        if (amount == 0) revert ZeroAmount();
        if (totalStaked == 0) revert NoStakers();
        accYieldPerShare += (amount * ACC_PRECISION) / totalStaked;
        emit YieldDistributed(amount, accYieldPerShare);
    }

    // ---------------------------------------------------------------
    //                          Views
    // ---------------------------------------------------------------

    function pendingYield(address user) external view returns (uint256) {
        Stake storage s = stakes[user];
        return (uint256(s.amount) * accYieldPerShare) / ACC_PRECISION - s.rewardDebt;
    }

    function stakeOf(address user) external view returns (uint128 amount, uint256 rewardDebt) {
        Stake storage s = stakes[user];
        return (s.amount, s.rewardDebt);
    }

    // ---------------------------------------------------------------
    //                          Internal
    // ---------------------------------------------------------------

    function _harvest(address u) internal returns (uint256 pending) {
        Stake storage s = stakes[u];
        // Cache the accrued product: it's reused for `rewardDebt` below, and
        // the intervening `balanceOf` external call is an optimization barrier
        // that would otherwise stop the compiler from reusing the SLOADs.
        uint256 accrued = (uint256(s.amount) * accYieldPerShare) / ACC_PRECISION;
        pending = accrued - s.rewardDebt;
        if (pending > 0) {
            // Clamp to the yield actually held (balance in excess of staked
            // principal). The MasterChef accumulator can over-promise by a few
            // wei of floor-carry dust across (stakers × distributions); since
            // yield is PRE-FUNDED (not minted on demand), clamping guarantees
            // harvest — and therefore withdraw, which harvests first — can
            // never revert and that principal stays fully backed. A donor can
            // only raise the ceiling, never fabricate yield (acc is
            // treasury-gated). See test/invariant/StakingInvariant.
            uint256 availableYield = mrcy.balanceOf(address(this)) - totalStaked;
            if (pending > availableYield) pending = availableYield;
            // Debt is brought current before the external transfer so a
            // (non-reentrant) MRCY can't be double-harvested.
            s.rewardDebt = accrued;
            if (pending > 0) {
                require(mrcy.transfer(u, pending), "yield transfer failed");
                emit YieldClaimed(u, pending);
            }
        }
    }
}
