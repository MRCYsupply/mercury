// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Minimal surface of Hyperswap's NonfungiblePositionManager (a Uniswap
///      V3 periphery fork) needed to hold and harvest a locked LP position.
///      `collect` only withdraws ACCRUED FEES (tokensOwed) — it can never
///      touch principal, because principal only becomes withdrawable through
///      `decreaseLiquidity`, which this contract deliberately does not expose.
interface INonfungiblePositionManagerMinimal {
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);

    /// @dev Plain `transferFrom` on purpose — see `withdraw`.
    function transferFrom(address from, address to, uint256 tokenId) external;

    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @title LpTimelock — Mercury's initial-liquidity lock
/// @notice Holds the MRCY/WHYPE Hyperswap V3 position NFT (the 1% LP-only
///         premine paired with the founder HYPE) until `unlockTime`. Nothing
///         — not even the beneficiary multisig — can move the position out
///         before then. This contract is what makes the public "1% LP-only,
///         6-month lock" claim true and verifiable on-chain.
///
///         While locked, the beneficiary can only:
///         - `collectFees` — harvest the position's accrued swap fees
///           (earnings, never principal; see the interface note), and
///         - `extend` — push `unlockTime` FURTHER out (never closer).
///
/// @dev    Trust model: no owner, no admin, no upgrade path, no
///         `decreaseLiquidity`. `positionManager` and `beneficiary` are
///         immutable; `unlockTime` is monotonically non-decreasing. The only
///         way the position leaves is `withdraw` → `beneficiary`, at or
///         after `unlockTime`.
contract LpTimelock {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------
    //                          Immutables
    // ---------------------------------------------------------------

    /// @notice Hyperswap's NonfungiblePositionManager — the only collection
    ///         this contract accepts and custodies.
    INonfungiblePositionManagerMinimal public immutable positionManager;

    /// @notice Recipient of the position after unlock and of all collected
    ///         fees (the Mercury team multisig).
    address public immutable beneficiary;

    // ---------------------------------------------------------------
    //                            State
    // ---------------------------------------------------------------

    /// @notice Earliest timestamp at which `withdraw` succeeds. Can only
    ///         ever move forward (`extend`).
    uint256 public unlockTime;

    // ---------------------------------------------------------------
    //                       Errors / events
    // ---------------------------------------------------------------

    error NotBeneficiary();
    error StillLocked(uint256 unlockTime_);
    error NotExtension();
    error ZeroAddress();
    error UnlockNotInFuture();
    error WrongCollection();

    event PositionLocked(uint256 indexed tokenId, uint256 unlockTime);
    event PositionWithdrawn(uint256 indexed tokenId, address indexed to);
    event LockExtended(uint256 previousUnlockTime, uint256 newUnlockTime);
    event FeesCollected(uint256 indexed tokenId, uint256 amount0, uint256 amount1);
    event ERC20Swept(address indexed token, uint256 amount);

    // ---------------------------------------------------------------
    //                          Modifiers
    // ---------------------------------------------------------------

    modifier onlyBeneficiary() {
        if (msg.sender != beneficiary) revert NotBeneficiary();
        _;
    }

    // ---------------------------------------------------------------
    //                         Constructor
    // ---------------------------------------------------------------

    /// @param positionManager_ Hyperswap NonfungiblePositionManager.
    /// @param beneficiary_     The team multisig (post-unlock recipient).
    /// @param unlockTime_      Lock expiry (must be in the future).
    constructor(INonfungiblePositionManagerMinimal positionManager_, address beneficiary_, uint256 unlockTime_) {
        if (address(positionManager_) == address(0) || beneficiary_ == address(0)) revert ZeroAddress();
        if (unlockTime_ <= block.timestamp) revert UnlockNotInFuture();
        positionManager = positionManager_;
        beneficiary = beneficiary_;
        unlockTime = unlockTime_;
    }

    // ---------------------------------------------------------------
    //                       ERC721 receiver
    // ---------------------------------------------------------------

    /// @notice Accepts position NFTs from the pinned position manager only —
    ///         locking happens by `safeTransferFrom`-ing the position here.
    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        if (msg.sender != address(positionManager)) revert WrongCollection();
        emit PositionLocked(tokenId, unlockTime);
        return this.onERC721Received.selector;
    }

    // ---------------------------------------------------------------
    //                       Beneficiary ops
    // ---------------------------------------------------------------

    /// @notice Releases the position to the beneficiary, at or after
    ///         `unlockTime`.
    /// @dev    Plain `transferFrom` on purpose: a `safeTransferFrom` would
    ///         call `onERC721Received` on the beneficiary — a Safe multisig
    ///         without its ERC721-aware fallback handler would revert that
    ///         hook and the position would be wedged here FOREVER (this
    ///         contract has no other exit). `transferFrom` cannot wedge.
    function withdraw(uint256 tokenId) external onlyBeneficiary {
        if (block.timestamp < unlockTime) revert StillLocked(unlockTime);
        emit PositionWithdrawn(tokenId, beneficiary);
        positionManager.transferFrom(address(this), beneficiary, tokenId);
    }

    /// @notice Pushes the unlock further out (re-lock). Never shortens.
    function extend(uint256 newUnlockTime) external onlyBeneficiary {
        if (newUnlockTime <= unlockTime) revert NotExtension();
        emit LockExtended(unlockTime, newUnlockTime);
        unlockTime = newUnlockTime;
    }

    /// @notice Harvests the position's accrued swap fees straight to the
    ///         beneficiary. Fees only — principal cannot move (no
    ///         `decreaseLiquidity` on this contract).
    function collectFees(uint256 tokenId) external onlyBeneficiary returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = positionManager.collect(
            INonfungiblePositionManagerMinimal.CollectParams({
                tokenId: tokenId,
                recipient: beneficiary,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        emit FeesCollected(tokenId, amount0, amount1);
    }

    /// @notice Rescue for ERC20s mistakenly sent here (this contract never
    ///         holds ERC20s by design — `collectFees` pays the beneficiary
    ///         directly). Cannot touch the position NFT.
    function sweepERC20(IERC20 token) external onlyBeneficiary {
        uint256 balance = token.balanceOf(address(this));
        emit ERC20Swept(address(token), balance);
        token.safeTransfer(beneficiary, balance);
    }
}
