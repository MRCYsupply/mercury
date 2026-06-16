// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Governable} from "./Governable.sol";
import {IGridMiningRef} from "./interfaces/IGridMiningRef.sol";
import {IAffiliateRegistry} from "./interfaces/IAffiliateRegistry.sol";

/// @title AffiliateRegistry — Mercury affiliate/referral v1
/// @notice Code-based referrals: any user who has played ≥1 round can create
///         one custom affiliate code, share it via a `/r/<code>` link, and
///         earn HYPE from the vault-cut slice of every loser-deploy by
///         users referred via their code. Skim is taken AT SETTLE TIME by
///         GridMining (see GridMining._maybeAffiliateSkim) — winners are
///         economically untouched.
///
/// @dev    Trust model:
///         - **GridMining is the only authorised caller of `accrueFor` and
///           `claimCode`.** Set once via `setGridMining` at deploy.
///         - **All accruals are pull-pattern** — referrers claim via
///           `claim()`. No external HYPE transfer on the deploy hot path.
///         - **Binding is immutable** — once a referee → referrer is set
///           (via either path), it cannot be re-set.
///         - **Binding has an acquisition window** — a referee can only
///           bind while they have played ≤ `bindWindowRounds` rounds
///           (default 5). Closes the retroactive self-attribution /
///           collusion vector (an established player binding to an
///           accomplice's code to route skim to them forever).
///         - **Anti-abuse**: self-affiliate blocked, ≥1 round-played gate
///           on code creation, codes validated for safe shape on-chain.
contract AffiliateRegistry is IAffiliateRegistry, Governable, ReentrancyGuard {
    // ---------------------------------------------------------------
    //                          Constants
    // ---------------------------------------------------------------

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint16 public constant MAX_AFFILIATE_BPS = 100; // 1% hard cap

    /// @dev Freeze keys (see Governable).
    bytes32 public constant KEY_AFFILIATE_BPS = keccak256("AFFILIATE_BPS");
    bytes32 public constant KEY_GRIDMINING = keccak256("AFFILIATE_GRIDMINING");
    bytes32 public constant KEY_BIND_WINDOW = keccak256("AFFILIATE_BIND_WINDOW");
    /// @dev One custom code per wallet. Referrals per code are unlimited —
    ///      the binding window + anti-self-affiliate are the abuse guards,
    ///      not a referee cap (a cap would throttle legit high-volume
    ///      referrers for ~no security gain).
    uint8 public constant MAX_CODES_PER_USER = 1;
    uint8 public constant MIN_CODE_LEN = 3;
    uint8 public constant MAX_CODE_LEN = 32;

    // ---------------------------------------------------------------
    //                          External refs
    // ---------------------------------------------------------------

    IGridMiningRef public gridMining;
    uint16 public override affiliateBps = 50; // 0.5% of each loser's vault cut

    /// @notice Acquisition window. A referee can only bind to a referrer
    ///         while they have played ≤ `bindWindowRounds` rounds. Closes
    ///         the retroactive self-attribution / collusion vector — an
    ///         established player binding to an accomplice's code to route
    ///         skim to them forever. The cookie auto-bind fires on the
    ///         first deploy (rounds played = 0), so legit acquisition is
    ///         well within the window; only late manual binding is gated.
    ///         Settable + freezable via KEY_BIND_WINDOW.
    uint256 public bindWindowRounds = 5;

    // ---------------------------------------------------------------
    //                          Code storage
    // ---------------------------------------------------------------

    /// @notice code hash → owner address. address(0) if not registered.
    mapping(bytes32 => address) public ownerOfCode;
    /// @notice For UX: code hash → original code string (for indexer / UI lookup).
    mapping(bytes32 => string) public codeStringOf;
    /// @notice owner → list of their code hashes (max MAX_CODES_PER_USER).
    mapping(address => bytes32[]) internal _codesOf;

    /// @notice referee → code hash they were bound to. bytes32(0) if none.
    ///         IMMUTABLE once set.
    mapping(address => bytes32) public claimedCodeBy;

    // ---------------------------------------------------------------
    //                          Accruals
    // ---------------------------------------------------------------

    /// @notice owner → claimable HYPE.
    mapping(address => uint256) public accrued;
    /// @notice owner → cumulative HYPE ever earned (claimed + still accrued).
    mapping(address => uint256) public lifetimeEarned;
    /// @notice owner → cumulative number of unique referees they brought.
    mapping(address => uint256) public refereeCount;

    // ---------------------------------------------------------------
    //                          Events
    // ---------------------------------------------------------------

    event GridMiningSet(address indexed previous, address indexed current);
    event AffiliateBpsChanged(uint16 previous, uint16 current);
    event BindWindowRoundsChanged(uint256 previous, uint256 current);
    event CodeCreated(address indexed owner, string code, bytes32 indexed codeHash);
    event MyReferrerSet(address indexed referee, string code, address indexed owner);
    event AffiliateAccrued(address indexed owner, address indexed referee, uint256 amount);
    event AffiliateClaimed(address indexed owner, uint256 amount);

    // ---------------------------------------------------------------
    //                          Errors
    // ---------------------------------------------------------------

    error NotGridMining();
    error ZeroAddress();
    error BpsTooHigh(uint16 requested, uint16 max);
    error CodeAlreadyExists(bytes32 codeHash);
    error CodeNotFound();
    error AlreadyBound();
    error SelfReferral();
    error NotPlayedYet();
    error BindingWindowClosed();
    error BadCodeFormat();
    error TooManyCodes();
    error NothingToClaim();
    error TransferFailed();

    // ---------------------------------------------------------------
    //                          Constructor
    // ---------------------------------------------------------------

    constructor(address initialOwner, IGridMiningRef gridMining_) Governable(initialOwner) {
        if (address(gridMining_) == address(0)) revert ZeroAddress();
        gridMining = gridMining_;
    }

    // ---------------------------------------------------------------
    //                          Admin
    // ---------------------------------------------------------------

    function setGridMining(IGridMiningRef newGridMining) external onlyOwner notFrozen(KEY_GRIDMINING) {
        if (address(newGridMining) == address(0)) revert ZeroAddress();
        emit GridMiningSet(address(gridMining), address(newGridMining));
        gridMining = newGridMining;
    }

    function setAffiliateBps(uint16 newBps) external onlyOwner notFrozen(KEY_AFFILIATE_BPS) {
        if (newBps > MAX_AFFILIATE_BPS) revert BpsTooHigh(newBps, MAX_AFFILIATE_BPS);
        emit AffiliateBpsChanged(affiliateBps, newBps);
        affiliateBps = newBps;
    }

    /// @notice Set the acquisition window (max rounds played for a referee to
    ///         still bind to a referrer). 0 = only truly fresh addresses
    ///         (auto-bind on first deploy) can bind.
    function setBindWindowRounds(uint256 newWindow) external onlyOwner notFrozen(KEY_BIND_WINDOW) {
        emit BindWindowRoundsChanged(bindWindowRounds, newWindow);
        bindWindowRounds = newWindow;
    }

    // ---------------------------------------------------------------
    //                          User: create code
    // ---------------------------------------------------------------

    /// @notice Create the caller's single affiliate code. Requires the caller
    ///         to have played ≥1 round on GridMining (anti-squatting per the
    ///         ZINC reference UX) and to not already own a code
    ///         (MAX_CODES_PER_USER = 1). The code string is caller-chosen and
    ///         must be globally unique.
    function createCode(string calldata code) external returns (bytes32 codeHash) {
        if (gridMining.roundsPlayedOf(msg.sender) == 0) revert NotPlayedYet();
        if (_codesOf[msg.sender].length >= MAX_CODES_PER_USER) revert TooManyCodes();
        codeHash = _validateAndHash(code);
        if (ownerOfCode[codeHash] != address(0)) revert CodeAlreadyExists(codeHash);
        ownerOfCode[codeHash] = msg.sender;
        codeStringOf[codeHash] = code;
        _codesOf[msg.sender].push(codeHash);
        emit CodeCreated(msg.sender, code, codeHash);
    }

    // ---------------------------------------------------------------
    //                          User: bind a referrer (manual entry)
    // ---------------------------------------------------------------

    /// @notice Manually bind `msg.sender` as the referee of `code`'s owner.
    ///         Used by the /affiliate page "I was referred by X" input,
    ///         and as a fallback if the cookie+auto-bind on first deploy
    ///         didn't fire. Immutable once set. Only callable while the
    ///         caller is still within the acquisition window (rounds played
    ///         ≤ `bindWindowRounds`); reverts BindingWindowClosed after.
    function setMyReferrer(string calldata code) external {
        if (claimedCodeBy[msg.sender] != bytes32(0)) revert AlreadyBound();
        if (gridMining.roundsPlayedOf(msg.sender) > bindWindowRounds) revert BindingWindowClosed();
        bytes32 codeHash = keccak256(bytes(code));
        address owner = ownerOfCode[codeHash];
        if (owner == address(0)) revert CodeNotFound();
        if (owner == msg.sender) revert SelfReferral();
        claimedCodeBy[msg.sender] = codeHash;
        refereeCount[owner] += 1;
        emit MyReferrerSet(msg.sender, code, owner);
    }

    // ---------------------------------------------------------------
    //                          GridMining-only: auto-bind on first deploy
    // ---------------------------------------------------------------

    /// @inheritdoc IAffiliateRegistry
    /// @dev Called by GridMining.deployWithCode in try/catch. MUST be
    ///      idempotent and silent on all "no-op" conditions (already
    ///      bound, code unknown, self-affiliate) so a bad code on
    ///      deploy never bricks the deploy itself.
    function claimCode(address referee, string calldata code) external override {
        if (msg.sender != address(gridMining)) revert NotGridMining();
        if (claimedCodeBy[referee] != bytes32(0)) return; // already bound
        if (gridMining.roundsPlayedOf(referee) > bindWindowRounds) return; // acquisition window closed
        bytes32 codeHash = keccak256(bytes(code));
        address owner = ownerOfCode[codeHash];
        if (owner == address(0)) return; // unknown code
        if (owner == referee) return; // self-affiliate
        claimedCodeBy[referee] = codeHash;
        refereeCount[owner] += 1;
        emit MyReferrerSet(referee, code, owner);
    }

    // ---------------------------------------------------------------
    //                          GridMining-only: accrue at settle
    // ---------------------------------------------------------------

    /// @inheritdoc IAffiliateRegistry
    /// @dev Called by GridMining._maybeAffiliateSkim per loser-miner at
    ///      settle. If the referee has no binding, the registry MUST
    ///      refund the value so GridMining can fold it back into the
    ///      Treasury vault deposit.
    function accrueFor(address referee) external payable override nonReentrant {
        if (msg.sender != address(gridMining)) revert NotGridMining();
        bytes32 codeHash = claimedCodeBy[referee];
        if (codeHash == bytes32(0) || msg.value == 0) {
            // No referrer → refund. GridMining absorbs the refund via balance-delta.
            if (msg.value > 0) {
                (bool ok,) = msg.sender.call{value: msg.value}("");
                if (!ok) revert TransferFailed();
            }
            return;
        }
        address owner = ownerOfCode[codeHash];
        accrued[owner] += msg.value;
        lifetimeEarned[owner] += msg.value;
        emit AffiliateAccrued(owner, referee, msg.value);
    }

    // ---------------------------------------------------------------
    //                          User: claim accrued
    // ---------------------------------------------------------------

    function claim() external nonReentrant returns (uint256 amount) {
        amount = accrued[msg.sender];
        if (amount == 0) revert NothingToClaim();
        accrued[msg.sender] = 0;
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit AffiliateClaimed(msg.sender, amount);
    }

    // ---------------------------------------------------------------
    //                          Views
    // ---------------------------------------------------------------

    function referrerOf(address referee) external view returns (address) {
        bytes32 h = claimedCodeBy[referee];
        return h == bytes32(0) ? address(0) : ownerOfCode[h];
    }

    function codeOf(address referee) external view returns (string memory) {
        bytes32 h = claimedCodeBy[referee];
        return h == bytes32(0) ? "" : codeStringOf[h];
    }

    function codesOf(address user) external view returns (bytes32[] memory) {
        return _codesOf[user];
    }

    function codesOfCount(address user) external view returns (uint256) {
        return _codesOf[user].length;
    }

    /// @notice Resolved string variant of `codesOf` — saves the FE an N+1
    ///         fanout when rendering an owner's code list. Cheap on registry
    ///         because string-storage reads are O(1) and
    ///         N ≤ MAX_CODES_PER_USER = 1.
    function codeStringsOf(address user) external view returns (string[] memory codes) {
        bytes32[] storage hashes = _codesOf[user];
        codes = new string[](hashes.length);
        for (uint256 i = 0; i < hashes.length; i++) {
            codes[i] = codeStringOf[hashes[i]];
        }
    }

    function codeExists(string calldata code) external view returns (bool) {
        return ownerOfCode[keccak256(bytes(code))] != address(0);
    }

    // ---------------------------------------------------------------
    //                          Internal — code validation
    // ---------------------------------------------------------------

    /// @dev Validates the code format: [a-z0-9-]+, no leading/trailing/
    ///      double hyphens, length in [MIN_CODE_LEN, MAX_CODE_LEN].
    ///      Reverts BadCodeFormat on any violation. Returns the keccak256
    ///      hash of the validated bytes.
    function _validateAndHash(string calldata code) internal pure returns (bytes32) {
        bytes calldata b = bytes(code);
        uint256 n = b.length;
        if (n < MIN_CODE_LEN || n > MAX_CODE_LEN) revert BadCodeFormat();
        if (b[0] == 0x2d || b[n - 1] == 0x2d) revert BadCodeFormat(); // '-' at edge
        for (uint256 i = 0; i < n; i++) {
            bytes1 c = b[i];
            bool isLower = (c >= 0x61 && c <= 0x7a); // a-z
            bool isDigit = (c >= 0x30 && c <= 0x39); // 0-9
            bool isDash = (c == 0x2d); // '-'
            if (!isLower && !isDigit && !isDash) revert BadCodeFormat();
            if (isDash && i > 0 && b[i - 1] == 0x2d) revert BadCodeFormat(); // no '--'
        }
        return keccak256(b);
    }
}
