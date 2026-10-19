// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Operated} from "./access/PredgeAccess.sol";
import {PullCredit} from "./access/PullCredit.sol";

/// @notice What the arbiter needs from a Refund Protocol. `paymentInfo` is the parties-and-amount
///         view the arbiter binds evidence and bond size to. Circle's production contract is not
///         known to expose exactly this function: against it, a thin read-only adapter that
///         implements `paymentInfo` and forwards the two write calls is required, and must be
///         reviewed before use. On our chains only `MockRefundProtocolV2` exists.
interface IRefundProtocolV2 {
    /// @return payer            the party refunded by `refundByArbiter`
    /// @return payee            the recipient of the payment
    /// @return amount           the payment amount, in the same native wei the bond is sized in
    /// @return releaseTimestamp when the payee may withdraw; a refund is impossible after it
    function paymentInfo(uint256 paymentID)
        external
        view
        returns (address payer, address payee, uint256 amount, uint256 releaseTimestamp);
    function refundByArbiter(uint256 paymentID) external;
    function setLockupSeconds(address recipient, uint256 recipientLockupSeconds) external;
}

/// @title  PredgeRefundArbiterV2
/// @notice A bonded, OPTIMISTIC arbiter for a Refund Protocol. The operator rules; nothing moves
///         until a challenge window has passed; the harmed party can freeze the ruling and escalate
///         it to the owner (a Safe); and a ruling the owner overturns costs the operator its bond.
///
///         Flow, per payment:
///           1. `fileEvidence`: the PAYER or the PAYEE (read from the Refund Protocol, not
///              chosen by the caller) files the hash of its own evidence. Write-once per party, and
///              only before a ruling exists.
///           2. `rule` (operator): cites one party's filed evidence, picks Refund or Release, and
///              posts a bond of at least `max(minBond, ceil(amount * bondBps / 10000))`. The
///              operator may not itself be a party. Nothing executes yet.
///           3. Within `window` seconds of the ruling, the party the ruling HARMS (the payee on a
///              Refund, the payer on a Release) may call `dispute` with counter-evidence. That
///              freezes the ruling and starts the owner's `RESOLUTION_TIMEOUT`.
///           4a. Undisputed: after the window anyone calls `finalize`. The bond is credited back to
///               the staker and, for a Refund, `refundByArbiter` is called on the Refund Protocol.
///           4b. Disputed: the owner calls `resolve(paymentID, finalDirection)`. If it equals the
///               ruling, the ruling is upheld exactly as in 4a. If not, the ruling is overturned:
///               the bond is credited to the harmed party (the disputer), and the owner's
///               direction is executed (a Refund is sent to the Refund Protocol).
///           4c. If neither happens before `expiresAt` (owner silent, or the Refund Protocol keeps
///               reverting), anyone calls `expire`: the ruling is voided, NOTHING is executed, and
///               the bond returns to the staker.
///
///         Trust, stated plainly: for disputed rulings the owner Safe is the court of last
///         resort. An operator that rules wrongly is only punished if the harmed party notices and
///         disputes inside the window, and the owner then agrees. The window must close before the
///         Refund Protocol's lockup ends, which `rule` enforces for a Refund.
///
/// @dev    Native value only, in the chain's native wei. The contract holds `totalBonded +
///         totalCredit` and never user payments. Parameters are bounded and not retroactive: the
///         window is snapshotted into each ruling, and the bond is fixed when posted.
contract PredgeRefundArbiterV2 is Operated, PullCredit {
    enum Direction {
        None,
        Refund,
        Release
    }

    enum Status {
        None,
        Ruled, // window running, or elapsed and not yet finalized
        Disputed, // frozen, waiting for the owner
        Finalized, // upheld; bond returned; refund executed if Refund (final)
        Overturned, // owner disagreed; bond paid to the harmed party (final)
        Voided // expired without a decision; nothing executed; bond returned (final)
    }

    struct Ruling {
        address staker; // the operator key that ruled; the only address its bond is ever returned to
        Status status;
        Direction direction;
        uint64 ruledAt;
        uint64 window; // snapshot of `challengeWindow`
        uint64 expiresAt; // after this, `expire` voids the ruling
        address evidenceFrom;
        address payer;
        address payee;
        uint256 bond;
        bytes32 evidenceHash;
        bytes32 counterEvidence;
    }

    uint64 public constant MIN_WINDOW = 1 hours;
    uint64 public constant MAX_WINDOW = 30 days;
    uint64 public constant RESOLUTION_TIMEOUT = 14 days;
    uint16 public constant MAX_BPS = 10_000;

    IRefundProtocolV2 public immutable refundProtocol;

    uint64 public challengeWindow;
    uint256 public minBond;
    uint16 public bondBps;

    uint256 public totalBonded;
    uint64 public rulingCount;
    uint64 public overturnCount;

    mapping(uint256 => Ruling) private _rulings;
    /// @notice paymentID => party => hash of the evidence that party filed. Write-once.
    mapping(uint256 => mapping(address => bytes32)) public filedEvidence;

    event EvidenceFiled(uint256 indexed paymentID, address indexed party, bytes32 evidenceHash);
    event Ruled(
        uint256 indexed paymentID,
        address indexed staker,
        address indexed evidenceFrom,
        bytes32 evidenceHash,
        Direction direction,
        uint256 bond,
        uint64 windowEnd
    );
    event Disputed(uint256 indexed paymentID, address indexed disputer, bytes32 counterEvidence, uint64 expiresAt);
    event Finalized(uint256 indexed paymentID, address indexed staker, Direction direction, uint256 bond);
    event Overturned(uint256 indexed paymentID, address indexed harmed, Direction finalDirection, uint256 bond);
    event Voided(uint256 indexed paymentID, address indexed staker, uint256 bond);
    event ParamsUpdated(uint64 challengeWindow, uint256 minBond, uint16 bondBps);

    error ZeroHash();
    error BadParams();
    error BadDirection();
    error UnknownPayment();
    error NotAParty();
    error OperatorIsParty();
    error EvidenceClosed();
    error EvidenceAlreadyFiled(uint256 paymentID, address party);
    error NoEvidenceFiled(uint256 paymentID, address party);
    error AlreadyRuled(uint256 paymentID);
    error BondTooSmall(uint256 required);
    error LockupTooShort();
    error BadStatus();
    error WindowOpen();
    error WindowClosed();
    error NotHarmedParty();
    error NotExpired();
    error ResolutionExpired();

    /// @param owner_            the Safe: resolves disputes, sets bounded parameters, rotates the operator
    /// @param operator_         the hot key that rules
    /// @param refundProtocol_   the Refund Protocol (or adapter) this arbiter drives; immutable
    /// @param challengeWindow_  seconds a ruling stays disputable, within [MIN_WINDOW, MAX_WINDOW]
    /// @param minBond_          absolute bond floor in native wei, non-zero
    /// @param bondBps_          bond as basis points of the payment amount, at most 10000
    constructor(address owner_, address operator_, address refundProtocol_, uint64 challengeWindow_, uint256 minBond_, uint16 bondBps_)
        Operated(owner_, operator_)
    {
        if (refundProtocol_ == address(0)) revert ZeroAddress();
        refundProtocol = IRefundProtocolV2(refundProtocol_);
        _setParams(challengeWindow_, minBond_, bondBps_);
    }

    /// @notice Owner-only, bounded, not retroactive: existing rulings keep their window and bond.
    function setParams(uint64 challengeWindow_, uint256 minBond_, uint16 bondBps_) external onlyOwner {
        _setParams(challengeWindow_, minBond_, bondBps_);
    }

    /// @notice Pass a recipient lockup change through to the Refund Protocol (owner only).
    function setLockupSeconds(address recipient, uint256 recipientLockupSeconds) external onlyOwner {
        refundProtocol.setLockupSeconds(recipient, recipientLockupSeconds);
    }

    /// @notice The bond a ruling on a payment of `amount` must post right now.
    function requiredBond(uint256 amount) public view returns (uint256) {
        uint256 scaled = (amount * bondBps + MAX_BPS - 1) / MAX_BPS;
        return scaled > minBond ? scaled : minBond;
    }

    /// @notice A party to the payment files the hash of its own evidence. Write-once, and only
    ///         before the ruling. The caller must be the payer or the payee per the Refund Protocol.
    function fileEvidence(uint256 paymentID, bytes32 evidenceHash) external {
        if (evidenceHash == bytes32(0)) revert ZeroHash();
        if (_rulings[paymentID].status != Status.None) revert EvidenceClosed();
        (address payer, address payee,,) = refundProtocol.paymentInfo(paymentID);
        if (msg.sender != payer && msg.sender != payee) revert NotAParty();
        if (filedEvidence[paymentID][msg.sender] != bytes32(0)) revert EvidenceAlreadyFiled(paymentID, msg.sender);
        filedEvidence[paymentID][msg.sender] = evidenceHash;
        emit EvidenceFiled(paymentID, msg.sender, evidenceHash);
    }

    /// @notice Rule on a payment: cite a party's filed evidence, choose a direction, post the bond.
    ///         Nothing executes until `finalize` or `resolve`.
    /// @param evidenceFrom the payer or payee whose filed evidence the ruling rests on
    function rule(uint256 paymentID, address evidenceFrom, bytes32 evidenceHash, Direction direction)
        external
        payable
        onlyOperator
    {
        if (evidenceHash == bytes32(0)) revert ZeroHash();
        if (direction == Direction.None) revert BadDirection();
        Ruling storage r = _rulings[paymentID];
        if (r.status != Status.None) revert AlreadyRuled(paymentID);

        (address payer, address payee, uint256 amount, uint256 releaseTimestamp) = refundProtocol.paymentInfo(paymentID);
        if (payee == address(0)) revert UnknownPayment();
        if (msg.sender == payer || msg.sender == payee) revert OperatorIsParty();
        if (evidenceFrom != payer && evidenceFrom != payee) revert NotAParty();
        if (filedEvidence[paymentID][evidenceFrom] != evidenceHash) revert NoEvidenceFiled(paymentID, evidenceFrom);
        uint256 required = requiredBond(amount);
        if (msg.value < required) revert BondTooSmall(required);
        uint64 window = challengeWindow;
        // A refund must still be possible when the window closes, with room for finalize.
        if (direction == Direction.Refund && releaseTimestamp <= block.timestamp + window) revert LockupTooShort();

        r.staker = msg.sender;
        r.status = Status.Ruled;
        r.direction = direction;
        r.ruledAt = uint64(block.timestamp);
        r.window = window;
        r.expiresAt = uint64(block.timestamp) + window + RESOLUTION_TIMEOUT;
        r.evidenceFrom = evidenceFrom;
        r.payer = payer;
        r.payee = payee;
        r.bond = msg.value;
        r.evidenceHash = evidenceHash;
        totalBonded += msg.value;
        rulingCount += 1;
        emit Ruled(paymentID, msg.sender, evidenceFrom, evidenceHash, direction, msg.value, uint64(block.timestamp) + window);
    }

    /// @notice The harmed party (payee on a Refund, payer on a Release) files counter-evidence
    ///         inside the window. This freezes the ruling and hands it to the owner.
    function dispute(uint256 paymentID, bytes32 counterEvidence) external {
        if (counterEvidence == bytes32(0)) revert ZeroHash();
        Ruling storage r = _rulings[paymentID];
        if (r.status != Status.Ruled) revert BadStatus();
        if (block.timestamp >= uint256(r.ruledAt) + r.window) revert WindowClosed();
        if (msg.sender != _harmed(r)) revert NotHarmedParty();
        r.status = Status.Disputed;
        r.counterEvidence = counterEvidence;
        r.expiresAt = uint64(block.timestamp) + RESOLUTION_TIMEOUT;
        emit Disputed(paymentID, msg.sender, counterEvidence, r.expiresAt);
    }

    /// @notice After an undisputed window, return the bond to the staker and execute a Refund.
    ///         Anyone may call. If the Refund Protocol reverts, this reverts too and the ruling
    ///         can only be voided via `expire`.
    function finalize(uint256 paymentID) external {
        Ruling storage r = _rulings[paymentID];
        if (r.status != Status.Ruled) revert BadStatus();
        if (block.timestamp < uint256(r.ruledAt) + r.window) revert WindowOpen();
        _uphold(paymentID, r);
    }

    /// @notice Owner decides a disputed ruling. `finalDirection` equal to the ruling upholds it;
    ///         any other direction overturns it and slashes the bond to the harmed party. The
    ///         final direction is executed either way (a Refund calls the Refund Protocol).
    function resolve(uint256 paymentID, Direction finalDirection) external onlyOwner {
        if (finalDirection == Direction.None) revert BadDirection();
        Ruling storage r = _rulings[paymentID];
        if (r.status != Status.Disputed) revert BadStatus();
        if (block.timestamp >= r.expiresAt) revert ResolutionExpired();
        if (finalDirection == r.direction) {
            _uphold(paymentID, r);
            return;
        }
        address harmed = _harmed(r);
        uint256 bond = r.bond;
        r.status = Status.Overturned;
        r.bond = 0;
        totalBonded -= bond;
        overturnCount += 1;
        _addCredit(harmed, bond);
        emit Overturned(paymentID, harmed, finalDirection, bond);
        if (finalDirection == Direction.Refund) refundProtocol.refundByArbiter(paymentID);
    }

    /// @notice Void a ruling nobody decided in time. Nothing is executed; the bond returns to the
    ///         staker. Anyone may call once `expiresAt` has passed.
    function expire(uint256 paymentID) external {
        Ruling storage r = _rulings[paymentID];
        if (r.status != Status.Ruled && r.status != Status.Disputed) revert BadStatus();
        if (block.timestamp < r.expiresAt) revert NotExpired();
        uint256 bond = r.bond;
        r.status = Status.Voided;
        r.bond = 0;
        totalBonded -= bond;
        _addCredit(r.staker, bond);
        emit Voided(paymentID, r.staker, bond);
    }

    /// @notice The full ruling record for a payment (all-zero if none).
    function rulings(uint256 paymentID) external view returns (Ruling memory) {
        return _rulings[paymentID];
    }

    /// @notice The party the ruling in `paymentID` would harm, or zero if there is no ruling.
    function harmedParty(uint256 paymentID) external view returns (address) {
        Ruling storage r = _rulings[paymentID];
        return r.status == Status.None ? address(0) : _harmed(r);
    }

    function _uphold(uint256 paymentID, Ruling storage r) private {
        uint256 bond = r.bond;
        r.status = Status.Finalized;
        r.bond = 0;
        totalBonded -= bond;
        _addCredit(r.staker, bond);
        emit Finalized(paymentID, r.staker, r.direction, bond);
        if (r.direction == Direction.Refund) refundProtocol.refundByArbiter(paymentID);
    }

    function _harmed(Ruling storage r) private view returns (address) {
        return r.direction == Direction.Refund ? r.payee : r.payer;
    }

    function _setParams(uint64 challengeWindow_, uint256 minBond_, uint16 bondBps_) private {
        if (challengeWindow_ < MIN_WINDOW || challengeWindow_ > MAX_WINDOW || minBond_ == 0 || bondBps_ > MAX_BPS)
            revert BadParams();
        challengeWindow = challengeWindow_;
        minBond = minBond_;
        bondBps = bondBps_;
        emit ParamsUpdated(challengeWindow_, minBond_, bondBps_);
    }
}
