// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Governable} from "./Governable.sol";
import {MercuryToken} from "./MercuryToken.sol";
import {Staking} from "./Staking.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";

/// @notice Minimal Hyperswap/Uniswap V3 surfaces used by the buyback.
interface IWETH {
    function deposit() external payable;
    function approve(address, uint256) external returns (bool);
}

interface IV3SwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata) external payable returns (uint256);
}

interface IV3Pool {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory);

    function increaseObservationCardinalityNext(uint16) external;
}

/// @title TreasuryV3 — batched buyback + true burn + staker yield, on Hyperswap V3
/// @notice V3 port of `Treasury`. Receives HYPE from GridMining (admin fee +
///         per-round vault cut), batches to a threshold, then swaps HYPE→$MRCY
///         on Hyperswap **V3** (`exactInputSingle`) with a flash-loan guard that
///         bounds the pool's CURRENT tick to its time-weighted-average tick
///         (the pool's own `observe` oracle), burns 90% (true burn) and routes
///         10% to stakers.
///
///         WHY V3: live HyperEVM-mainnet Hyperswap V2 has no usable swap router;
///         V3 is the only working swap venue (see docs/HYPERSWAP-INTEGRATION.md).
///         This replaces the V2 `swapExactETHForTokens` + the `MercuryToken`
///         `getReserves` 5-snapshot TWAP with V3 `exactInputSingle` + the V3
///         pool oracle.
///
///         Manipulation model: a sandwich can only move spot up to
///         `maxTickDeviation` ticks from the TWAP before `executeBuyback`
///         reverts; `amountOutMin` (computed off-chain by the keeper from a
///         quote) is the additional output floor enforced by the router. The
///         TWAP is read from the pool oracle, which a single-block manipulation
///         cannot move materially over the configured window.
contract TreasuryV3 is ITreasury, Governable, ReentrancyGuard {
    uint256 public constant BPS_DENOMINATOR = 10_000;

    bytes32 public constant KEY_SPLIT = keccak256("TREASURY_SPLIT");
    bytes32 public constant KEY_THRESHOLD = keccak256("TREASURY_THRESHOLD");
    bytes32 public constant KEY_GUARD = keccak256("TREASURY_GUARD");
    bytes32 public constant KEY_ROUTER = keccak256("TREASURY_ROUTER");
    bytes32 public constant KEY_POOL = keccak256("TREASURY_POOL");
    bytes32 public constant KEY_GRIDMINING = keccak256("TREASURY_GRIDMINING");
    bytes32 public constant KEY_KEEPER = keccak256("TREASURY_KEEPER");

    /// @notice Hard cap on `maxTickDeviation` so the manipulation guard can never
    ///         be widened into a no-op by the owner. ~20% in ticks.
    int24 public constant MAX_TICK_DEVIATION_CAP = 2_000;

    uint256 public BURN_BPS = 9_000;
    uint256 public STAKER_BPS = 1_000;

    MercuryToken public immutable mrcy;
    Staking public immutable staking;
    address public immutable weth; // WHYPE

    IV3SwapRouter public router; // Hyperswap V3 SwapRouter
    IV3Pool public pool; // MRCY/WHYPE V3 pool (oracle source)
    uint24 public poolFee; // V3 fee tier of the MRCY/WHYPE pool
    address public gridMining;

    /// @notice Allowlisted keepers permitted to call `executeBuyback`. A fully
    ///         permissionless buyback let ANY caller pass `amountOutMin = 0` and
    ///         sandwich the swap within the tick band; gating to a
    ///         trusted keeper removes that vector while the lockup in `Staking`
    ///         still defends against JIT yield-sniping.
    mapping(address => bool) public keeperAllowed;

    // 0.8 HYPE: small, frequent buybacks keep the burn visibly alive from day 1
    // and stay slippage-safe on the launch LP depth. Admin-tunable at runtime via
    // setBuybackThreshold (owner, freezable KEY_THRESHOLD) — raise it if buyback
    // tx cadence ever needs throttling. (TOKENOMICS.md §2; was 8e18 pre-launch.)
    uint256 public buybackThreshold = 0.8e18;
    /// @notice TWAP window (seconds) for the oracle guard.
    uint32 public twapWindow = 1800; // 30 min
    /// @notice Max allowed |currentTick - meanTick| (ticks ≈ bps). 800 ≈ ~8%.
    int24 public maxTickDeviation = 800;

    uint256 public vaultedHYPE;
    uint256 public totalBurned;
    uint256 public totalBuybacks;
    uint256 public totalDistributedToStakers;

    event ReceivedVault(uint256 amount, uint256 newVaulted);
    event BuybackExecuted(
        uint256 hypeSpent, uint256 mrcyReceived, uint256 mrcyBurned, uint256 mrcyToStakers
    );
    event ThresholdChanged(uint256 previous, uint256 current);
    event GuardChanged(uint32 twapWindow, int24 maxTickDeviation);
    event RouterChanged(address indexed previous, address indexed current);
    event PoolChanged(address indexed previous, address indexed current, uint24 fee);
    event GridMiningChanged(address indexed previous, address indexed current);
    event SplitChanged(uint256 burnBps, uint256 stakerBps);
    event KeeperAllowedSet(address indexed keeper, bool allowed);

    error NotGridMining();
    error NotKeeper();
    error BadSplit(uint256 burnBps);
    error BelowThreshold(uint256 vaulted, uint256 threshold);
    error PoolNotSet();
    error PriceDeviationTooHigh(int24 deviation, int24 cap);
    error ZeroAddress();

    constructor(
        address initialOwner,
        MercuryToken mrcy_,
        Staking staking_,
        IV3SwapRouter router_,
        address weth_
    ) Governable(initialOwner) {
        if (
            address(mrcy_) == address(0) || address(staking_) == address(0)
                || address(router_) == address(0) || weth_ == address(0)
        ) {
            revert ZeroAddress();
        }
        mrcy = mrcy_;
        staking = staking_;
        router = router_;
        weth = weth_;
    }

    receive() external payable {}

    // ------------------------------------------------------------------
    //                            Vault intake
    // ------------------------------------------------------------------

    /// @inheritdoc ITreasury
    function receiveVault() external payable {
        if (msg.sender != gridMining) revert NotGridMining();
        vaultedHYPE += msg.value;
        emit ReceivedVault(msg.value, vaultedHYPE);
    }

    // ------------------------------------------------------------------
    //                            Buyback
    // ------------------------------------------------------------------

    /// @notice Current |spot tick - TWAP tick| from the pool oracle (ticks).
    function tickDeviation() public view returns (int24 deviation, int24 meanTick, int24 spotTick) {
        if (address(pool) == address(0)) revert PoolNotSet();
        (, spotTick,,,,,) = pool.slot0();
        uint32[] memory ago = new uint32[](2);
        ago[0] = twapWindow;
        ago[1] = 0;
        (int56[] memory tc,) = pool.observe(ago);
        meanTick = int24((tc[1] - tc[0]) / int56(uint56(twapWindow)));
        deviation = spotTick > meanTick ? spotTick - meanTick : meanTick - spotTick;
    }

    function canExecuteBuyback() external view returns (bool ok, string memory reason) {
        if (vaultedHYPE < buybackThreshold) return (false, "below threshold");
        if (address(pool) == address(0)) return (false, "pool not set");
        (int24 dev,,) = tickDeviation();
        if (dev > maxTickDeviation) return (false, "price deviation too high");
        return (true, "");
    }

    /// @notice Swap vaulted HYPE for $MRCY on V3, burn 90%, 10% to stakers.
    ///         `amountOutMin` is the keeper-supplied output floor (computed
    ///         off-chain from a V3 quote); the on-chain oracle guard bounds spot
    ///         to the TWAP so a manipulated price reverts before the swap.
    function executeBuyback(uint256 amountOutMin)
        external
        nonReentrant
        returns (uint256 mrcyBought)
    {
        if (!keeperAllowed[msg.sender]) revert NotKeeper();
        uint256 spend = vaultedHYPE;
        if (spend < buybackThreshold) revert BelowThreshold(spend, buybackThreshold);

        // Flash-loan / manipulation guard via the pool's own oracle.
        (int24 dev,,) = tickDeviation();
        if (dev > maxTickDeviation) revert PriceDeviationTooHigh(dev, maxTickDeviation);

        // Effects before interaction.
        vaultedHYPE = 0;

        // Wrap HYPE -> WHYPE and swap WHYPE -> MRCY on V3.
        IWETH(weth).deposit{value: spend}();
        require(IWETH(weth).approve(address(router), spend), "approve failed");
        uint256 balBefore = mrcy.balanceOf(address(this));
        router.exactInputSingle(
            IV3SwapRouter.ExactInputSingleParams({
                tokenIn: weth,
                tokenOut: address(mrcy),
                fee: poolFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: spend,
                amountOutMinimum: amountOutMin,
                sqrtPriceLimitX96: 0
            })
        );
        // Defense-in-depth: leave no lingering WHYPE allowance to the router.
        require(IWETH(weth).approve(address(router), 0), "approve reset failed");
        mrcyBought = mrcy.balanceOf(address(this)) - balBefore;
        require(mrcyBought > 0, "no mrcy bought");

        uint256 burnAmount = (mrcyBought * BURN_BPS) / BPS_DENOMINATOR;
        uint256 stakerAmount = mrcyBought - burnAmount;

        if (stakerAmount > 0 && staking.totalStaked() > 0) {
            // Pay stakers via an atomic self-call (transfer + notify). If either leg
            // reverts (totalStaked raced to 0, or Staking re-pointed its treasury),
            // the sub-call rolls back wholesale — nothing is stranded in Staking — and
            // we fall through to burning the slice so the buyback can never be bricked
            // by the staking leg.
            try this.payStakers(stakerAmount) {
                totalDistributedToStakers += stakerAmount;
            } catch {
                burnAmount += stakerAmount;
                stakerAmount = 0;
            }
        } else {
            burnAmount += stakerAmount;
            stakerAmount = 0;
        }

        mrcy.burn(burnAmount);
        totalBurned += burnAmount;
        totalBuybacks += 1;

        emit BuybackExecuted(spend, mrcyBought, burnAmount, stakerAmount);
    }

    /// @notice Atomic staker payout (transfer + notify), callable only by this
    ///         contract from `executeBuyback`'s try/catch. Kept external so a
    ///         failure in either leg reverts as a unit without bricking the buyback.
    function payStakers(uint256 amount) external {
        if (msg.sender != address(this)) revert NotKeeper();
        require(mrcy.transfer(address(staking), amount), "staker transfer failed");
        staking.distributeYield(amount);
    }

    // ------------------------------------------------------------------
    //                              Admin
    // ------------------------------------------------------------------

    /// @notice Allow/deny a keeper to call `executeBuyback`.
    function setKeeperAllowed(address keeper, bool allowed)
        external
        onlyOwner
        notFrozen(KEY_KEEPER)
    {
        if (keeper == address(0)) revert ZeroAddress();
        keeperAllowed[keeper] = allowed;
        emit KeeperAllowedSet(keeper, allowed);
    }

    function setGridMining(address newGridMining) external onlyOwner notFrozen(KEY_GRIDMINING) {
        if (newGridMining == address(0)) revert ZeroAddress();
        emit GridMiningChanged(gridMining, newGridMining);
        gridMining = newGridMining;
    }

    function setPool(IV3Pool newPool, uint24 fee) external onlyOwner notFrozen(KEY_POOL) {
        if (address(newPool) == address(0)) revert ZeroAddress();
        emit PoolChanged(address(pool), address(newPool), fee);
        pool = newPool;
        poolFee = fee;
    }

    function setRouter(IV3SwapRouter newRouter) external onlyOwner notFrozen(KEY_ROUTER) {
        if (address(newRouter) == address(0)) revert ZeroAddress();
        emit RouterChanged(address(router), address(newRouter));
        router = newRouter;
    }

    function setBuybackThreshold(uint256 newThreshold) external onlyOwner notFrozen(KEY_THRESHOLD) {
        emit ThresholdChanged(buybackThreshold, newThreshold);
        buybackThreshold = newThreshold;
    }

    function setGuard(uint32 newTwapWindow, int24 newMaxTickDeviation)
        external
        onlyOwner
        notFrozen(KEY_GUARD)
    {
        require(newTwapWindow > 0 && newMaxTickDeviation > 0, "bad guard");
        require(newMaxTickDeviation <= MAX_TICK_DEVIATION_CAP, "deviation over cap");
        twapWindow = newTwapWindow;
        maxTickDeviation = newMaxTickDeviation;
        emit GuardChanged(newTwapWindow, newMaxTickDeviation);
    }

    /// @notice Grow the pool's oracle so `observe` over `twapWindow` is available.
    function growPoolCardinality(uint16 next) external onlyOwner {
        pool.increaseObservationCardinalityNext(next);
    }

    function setBuybackSplit(uint256 burnBps_) external onlyOwner notFrozen(KEY_SPLIT) {
        if (burnBps_ > BPS_DENOMINATOR) revert BadSplit(burnBps_);
        BURN_BPS = burnBps_;
        STAKER_BPS = BPS_DENOMINATOR - burnBps_;
        emit SplitChanged(BURN_BPS, STAKER_BPS);
    }
}
