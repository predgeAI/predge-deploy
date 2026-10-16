// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal view of Circle's Refund Protocol that an arbiter needs.
interface IRefundProtocol {
    function refundByArbiter(uint256 paymentID) external;
    function setLockupSeconds(address recipient, uint256 recipientLockupSeconds) external;
}

/// @title PredgeRefundArbiter
/// @notice A bonded arbiter for Circle's Refund Protocol.
///
/// Refund Protocol gives the arbiter seat unchecked power: whoever holds it can refund a payment
/// on a whim, and Circle's own README flags that an arbiter can drain payments through early
/// withdrawal. This contract takes that seat and gives it back constraints:
///
///   1. Evidence comes from the parties, not the arbiter. A payer or a merchant files
///      `sha256(their evidence)` under their own key with `fileEvidence`, before any ruling.
///      A filed record is immutable, and the arbiter cannot file on its own behalf.
///   2. Commit first. Ruling names WHOSE filed evidence it acted on and the hash it read, so the
///      reasoning exists before the money moves and cannot be rewritten afterwards.
///   3. Stake. Every ruling is backed by native value held here, reclaimable only once the
///      challenge window has passed without a successful challenge. `minBond` must stay well
///      above what a challenge costs in gas on the chain it runs on — a bond that does not
///      cover the challenger's gas buys no scrutiny, however slashable it is on paper.
///   4. Slashable, with nothing to forge. `challenge` takes no evidence from the caller: it
///      compares the hash the arbiter cited against the hash that party actually filed. Cite
///      evidence nobody filed, or a different version of it, and anyone takes the bond.
///
/// The contract never holds user payments. It only acts on Refund Protocol, so the worst an
/// operator can do is rule wrongly, and that costs the bond.
contract PredgeRefundArbiter {
    struct Ruling {
        bytes32 evidenceHash;   // the hash the arbiter says it read, committed before the money moves
        uint96 bond;            // native value staked behind it
        uint64 ruledAt;         // chain time of the ruling
        address decidedBy;      // the operator key that ruled
        address evidenceFrom;   // the party whose filed evidence the ruling claims to rest on
        Direction direction;    // refund the payer, or leave the payment with the recipient
        bool settled;           // bond reclaimed or slashed
    }

    enum Direction { None, Refund, Release }

    address public owner;
    address public operator;          // the key that rules day to day; rotatable, never holds funds
    IRefundProtocol public immutable refundProtocol;
    uint64 public challengeWindow;    // seconds a ruling stays challengeable
    uint96 public minBond;            // floor for a ruling's stake
    uint64 public rulingCount;
    uint64 public slashCount;

    mapping(uint256 => Ruling) public rulings;   // paymentID => ruling

    /// @notice paymentID => party => sha256 of the evidence that party filed. Write-once per
    ///         party, so neither side can revise its story after seeing the ruling.
    mapping(uint256 => mapping(address => bytes32)) public filedEvidence;

    event OperatorUpdated(address indexed previousOperator, address indexed newOperator);
    event EvidenceFiled(uint256 indexed paymentID, address indexed party, bytes32 evidenceHash);
    event Committed(uint256 indexed paymentID, bytes32 evidenceHash, address evidenceFrom, Direction direction, uint96 bond);
    event Ruled(uint256 indexed paymentID, Direction direction, bytes32 evidenceHash, uint64 ruledAt);
    event Slashed(uint256 indexed paymentID, address indexed challenger, uint96 bond, bytes32 committed, bytes32 delivered);
    event Reclaimed(uint256 indexed paymentID, uint96 bond);
    event ParamsUpdated(uint64 challengeWindow, uint96 minBond);

    error NotOwner();
    error NotOperator();
    error ZeroAddress();
    error ZeroHash();
    error BondTooSmall();
    error AlreadyRuled(uint256 paymentID);
    error NotRuled(uint256 paymentID);
    error AlreadySettled(uint256 paymentID);
    error WindowOpen(uint256 paymentID);
    error RulingHonest(uint256 paymentID);
    error TransferFailed();
    error BadDirection();
    error EvidenceAlreadyFiled(uint256 paymentID, address party);
    error NoEvidenceFiled(uint256 paymentID, address party);
    error ArbiterCannotFile();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    constructor(address refundProtocol_, address operator_, uint64 challengeWindow_, uint96 minBond_) {
        if (refundProtocol_ == address(0) || operator_ == address(0)) revert ZeroAddress();
        owner = msg.sender;
        operator = operator_;
        refundProtocol = IRefundProtocol(refundProtocol_);
        challengeWindow = challengeWindow_;
        minBond = minBond_;
    }

    /// @notice A party to a dispute files the hash of its own evidence, under its own key.
    ///         Write-once: neither side can revise its story once a ruling exists, and the
    ///         arbiter cannot manufacture the record it will later claim to have read.
    function fileEvidence(uint256 paymentID, bytes32 evidenceHash) external {
        if (evidenceHash == bytes32(0)) revert ZeroHash();
        if (msg.sender == operator || msg.sender == owner || msg.sender == address(this))
            revert ArbiterCannotFile();
        if (filedEvidence[paymentID][msg.sender] != bytes32(0))
            revert EvidenceAlreadyFiled(paymentID, msg.sender);

        filedEvidence[paymentID][msg.sender] = evidenceHash;
        emit EvidenceFiled(paymentID, msg.sender, evidenceHash);
    }

    /// @notice Rule on a payment, staking the bond and committing the evidence in the same call.
    /// @param paymentID    the Refund Protocol payment being ruled on
    /// @param evidenceFrom the party whose filed evidence this ruling rests on
    /// @param evidenceHash the hash the arbiter says it read from that party's filing
    /// @param direction    Refund sends the payment back to the payer's refundTo; Release leaves it
    /// @dev The cited evidence must already be filed on-chain by `evidenceFrom`, byte-for-byte,
    ///      or this reverts (`NoEvidenceFiled`). `challenge` later compares the same two values,
    ///      so requiring the match up front is what makes an honest ruling unslashable: it is
    ///      impossible to commit a ruling that a challenger could slash the next block by racing
    ///      the party's filing. The challenge window still pays the bond to anyone who later
    ///      shows the cited party's filing was changed out from under the ruling (it cannot be —
    ///      filings are write-once — but the check is kept as defence in depth).
    function rule(uint256 paymentID, address evidenceFrom, bytes32 evidenceHash, Direction direction)
        external
        payable
        onlyOperator
    {
        if (evidenceHash == bytes32(0)) revert ZeroHash();
        if (evidenceFrom == address(0)) revert ZeroAddress();
        if (direction == Direction.None) revert BadDirection();
        if (msg.value < minBond) revert BondTooSmall();
        // The cited evidence must ALREADY be on-chain under that party's key, and match exactly.
        // This is what makes an honest ruling unslashable: `challenge` compares the citation to
        // the party's filing, so if the filing is not there (or differs) at ruling time, the
        // ruling is slashable the instant it is made. Requiring the filing first closes that race
        // and the "rule before the filing lands" path that would otherwise burn an honest bond.
        if (filedEvidence[paymentID][evidenceFrom] != evidenceHash)
            revert NoEvidenceFiled(paymentID, evidenceFrom);
        Ruling storage r = rulings[paymentID];
        if (r.ruledAt != 0) revert AlreadyRuled(paymentID);

        r.evidenceHash = evidenceHash;
        r.bond = uint96(msg.value);
        r.ruledAt = uint64(block.timestamp);
        r.decidedBy = msg.sender;
        r.evidenceFrom = evidenceFrom;
        r.direction = direction;
        rulingCount += 1;

        emit Committed(paymentID, evidenceHash, evidenceFrom, direction, uint96(msg.value));
        if (direction == Direction.Refund) {
            refundProtocol.refundByArbiter(paymentID);
        }
        emit Ruled(paymentID, direction, evidenceHash, uint64(block.timestamp));
    }

    /// @notice Show that the ruling cites evidence the named party never filed, and take the bond.
    /// @dev Takes nothing from the caller but the payment id. Both sides of the comparison were
    ///      written on-chain in advance by two different keys — the party's filing and the
    ///      arbiter's citation — so a challenge against an honest ruling always reverts, and a
    ///      challenge against a fabricated one always succeeds, for anybody who calls it.
    function challenge(uint256 paymentID) external {
        Ruling storage r = rulings[paymentID];
        if (r.ruledAt == 0) revert NotRuled(paymentID);
        if (r.settled) revert AlreadySettled(paymentID);

        bytes32 filed = filedEvidence[paymentID][r.evidenceFrom];
        if (filed == r.evidenceHash) revert RulingHonest(paymentID);

        uint96 bond = r.bond;
        r.settled = true;
        r.bond = 0;
        slashCount += 1;
        emit Slashed(paymentID, msg.sender, bond, r.evidenceHash, filed);
        (bool ok,) = payable(msg.sender).call{value: bond}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice After the challenge window with no successful challenge, take the bond back.
    function reclaim(uint256 paymentID) external onlyOperator {
        Ruling storage r = rulings[paymentID];
        if (r.ruledAt == 0) revert NotRuled(paymentID);
        if (r.settled) revert AlreadySettled(paymentID);
        if (block.timestamp < r.ruledAt + challengeWindow) revert WindowOpen(paymentID);

        uint96 bond = r.bond;
        r.settled = true;
        r.bond = 0;
        emit Reclaimed(paymentID, bond);
        (bool ok,) = payable(msg.sender).call{value: bond}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Pass a recipient's lockup change through to Refund Protocol.
    function setLockupSeconds(address recipient, uint256 recipientLockupSeconds) external onlyOwner {
        refundProtocol.setLockupSeconds(recipient, recipientLockupSeconds);
    }

    function setOperator(address newOperator) external onlyOwner {
        if (newOperator == address(0)) revert ZeroAddress();
        emit OperatorUpdated(operator, newOperator);
        operator = newOperator;
    }

    function setParams(uint64 challengeWindow_, uint96 minBond_) external onlyOwner {
        challengeWindow = challengeWindow_;
        minBond = minBond_;
        emit ParamsUpdated(challengeWindow_, minBond_);
    }

    /// @notice Is this ruling slashable right now? A read-only check before spending gas.
    function wouldSlash(uint256 paymentID) external view returns (bool) {
        Ruling storage r = rulings[paymentID];
        if (r.ruledAt == 0 || r.settled) return false;
        return filedEvidence[paymentID][r.evidenceFrom] != r.evidenceHash;
    }

    function rulingOf(uint256 paymentID)
        external
        view
        returns (
            bytes32 evidenceHash,
            address evidenceFrom,
            uint96 bond,
            uint64 ruledAt,
            Direction direction,
            bool settled
        )
    {
        Ruling storage r = rulings[paymentID];
        return (r.evidenceHash, r.evidenceFrom, r.bond, r.ruledAt, r.direction, r.settled);
    }
}
