// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IRefundProtocolV2, PredgeRefundArbiterV2} from "../PredgeRefundArbiterV2.sol";

interface IERC20Decimals {
    function decimals() external view returns (uint8);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title  PredgeJobEscrow
/// @notice DEMO ONLY. UNAUDITED. TESTNET ONLY. Holds USDC for one agent job until a Predge ruling, a
///         deadline or a backstop decides where it goes. The constructor refuses every chain except
///         a local anvil and Arc testnet. Do not put real funds through it.
///
///         It is the "Refund Protocol" side of an unchanged `PredgeRefundArbiterV2`, and adds what the
///         arbiter alone does not have: automatic release to the seller.
///
///           1. `pay`             buyer agent locks USDC, naming the seller, the refund address, the
///                                hash of the job spec and a delivery deadline.
///           2. `markDelivered`   optional for a ruling, required for the backstop: the seller states
///                                that it delivered, before the deadline.
///           3. `fileEvidence`    on the arbiter, by a party.
///           4. `recordVerdict`   the operator stores the hash of the signed verdict. One verdict, one
///                                job, once: this is the on-chain replay guard.
///           5. `rule`            on the arbiter, by the operator, with a bond. Nothing moves yet.
///           6. Challenge window. The harmed party may `dispute` on the arbiter; the owner `resolve`s.
///           7. `settle`          anyone. Finalizes the ruling if needed and moves the money at once.
///
///         Without a ruling:
///           - No delivery by `deliverBy`: anyone may `refundAfterDeadline`. The seller can never take
///             money for a job it did not claim to deliver.
///           - Delivered, but never ruled or the ruling was voided: anyone may `releaseAfterBackstop`
///             once `releaseAt` has passed. The seller is the default winner, as in a Refund Protocol.
///
///         Trust, stated plainly. The verdict's ed25519 signature is checked OFF chain by the relayer;
///         this contract cannot verify it. On chain, trust rests on the operator key, its bond and
///         the dispute path. `recordVerdict` is an audit trail and a replay guard; it does not prove
///         the verdict was genuine, and the arbiter does not require it before `rule`.
///
/// @dev    Decimals. USDC is 6dp as an ERC-20, while the arbiter sizes bonds in native wei, 18dp (on
///         Arc gas is USDC too). Everything stored here is in token units; only `paymentInfo` is
///         multiplied by `amountScale`. An amount written in 18dp is refused by `maxAmount`.
///
///         Timing. `rule` needs `releaseAt > now + window + 14 days`. With the default 16-day lockup
///         and a 1-hour window, a ruling must come within about 47 hours of payment, so `deliverBy`
///         is capped at 1 day. A job not ruled by then falls through to the two paths above.
contract PredgeJobEscrow is IRefundProtocolV2 {
    enum State {
        None,
        Funded,
        Released,
        Refunded
    }

    struct Job {
        address buyer;
        address seller;
        address refundTo; // the arbiter's "payer": the party that files evidence, disputes and is refunded
        uint64 paidAt;
        uint64 deliverBy;
        uint64 releaseAt; // backstop; also the last moment a refund is possible
        State state;
        bool delivered;
        uint256 amount; // token units (6dp for USDC)
        bytes32 specHash; // sha256 of the canonical job spec: the `job_sha256` of a Predge verdict
        bytes32 deliveryHash;
    }

    struct VerdictRecord {
        bytes32 attestationHash; // sha256 of the verdict's `canonical`: its `content_hash`
        PredgeRefundArbiterV2.Direction direction;
        uint64 recordedAt;
    }

    string public constant DEMO_NOTICE = "DEMO ONLY. UNAUDITED. TESTNET ONLY. Not for real funds.";

    uint256 public constant ANVIL_CHAIN_ID = 31337;
    uint256 public constant ARC_TESTNET_CHAIN_ID = 5042002;

    uint8 public constant NATIVE_DECIMALS = 18;
    uint256 public constant MAX_WHOLE_TOKENS = 1_000;
    uint64 public constant MAX_DELIVERY_WINDOW = 1 days;
    uint64 public constant DEFAULT_LOCKUP = 16 days;

    IERC20Decimals public immutable usdc;
    /// @notice Multiplier from token units to native wei: 1e12 for 6dp USDC.
    uint256 public immutable amountScale;
    /// @notice Largest single payment in token units. Testnet cap; also catches an amount written in 18dp.
    uint256 public immutable maxAmount;
    address public immutable deployer;

    PredgeRefundArbiterV2 public arbiter;

    uint256 public nextJobId = 1;
    /// @notice Token units held for jobs still Funded. Equals the token balance, barring direct donations.
    uint256 public totalHeld;

    mapping(uint256 => Job) private _jobs;
    mapping(address => uint256) public lockupOf;
    mapping(uint256 => VerdictRecord) private _verdicts;
    /// @notice attestation hash => job it was used for (0 if unused).
    mapping(bytes32 => uint256) public attestationJob;

    event Bound(address indexed arbiter);
    event JobPaid(
        uint256 indexed id,
        address indexed buyer,
        address indexed seller,
        address refundTo,
        uint256 amount,
        bytes32 specHash,
        uint64 deliverBy,
        uint64 releaseAt
    );
    event JobDelivered(uint256 indexed id, bytes32 deliveryHash);
    event VerdictRecorded(uint256 indexed id, bytes32 indexed attestationHash, PredgeRefundArbiterV2.Direction direction);
    event JobReleased(uint256 indexed id, address indexed seller, uint256 amount);
    event JobRefunded(uint256 indexed id, address indexed refundTo, uint256 amount);
    event LockupSet(address indexed recipient, uint256 lockupSeconds);

    error ChainNotAllowed(uint256 chainId);
    error ZeroAddress();
    error ZeroHash();
    error ZeroAmount();
    error BadDecimals(uint8 decimals);
    error NotDeployer();
    error AlreadyBound();
    error NotBound();
    error ArbiterNotWired();
    error LockupTooShort();
    error NotArbiter();
    error NotOperator();
    error NotSeller();
    error BadParties();
    error AmountTooLarge(uint256 max);
    error BadDeadline();
    error TransferFailed();
    error NotActive(uint256 id);
    error DeadlinePassed();
    error DeadlineNotPassed();
    error AlreadyDelivered();
    error NotDelivered();
    error BadDirection();
    error AlreadyRuled(uint256 id);
    error VerdictAlreadyRecorded(uint256 id);
    error VerdictReplayed(bytes32 attestationHash, uint256 usedForJob);
    error NotSettleable(uint256 id);
    error RulingPending(uint256 id);
    error BackstopNotReached();
    error RefundTooLate();

    constructor(address usdc_) {
        if (block.chainid != ANVIL_CHAIN_ID && block.chainid != ARC_TESTNET_CHAIN_ID) {
            revert ChainNotAllowed(block.chainid);
        }
        if (usdc_ == address(0)) revert ZeroAddress();
        uint8 d = IERC20Decimals(usdc_).decimals();
        if (d > NATIVE_DECIMALS) revert BadDecimals(d);
        usdc = IERC20Decimals(usdc_);
        amountScale = 10 ** (NATIVE_DECIMALS - d);
        maxAmount = MAX_WHOLE_TOKENS * 10 ** d;
        deployer = msg.sender;
    }

    /// @notice One-time wiring, deployer only. The arbiter's `refundProtocol` is immutable and must already
    ///         be this contract, and a ruling must fit inside the default lockup.
    function bind(address arbiter_) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (address(arbiter) != address(0)) revert AlreadyBound();
        if (arbiter_ == address(0)) revert ZeroAddress();
        PredgeRefundArbiterV2 a = PredgeRefundArbiterV2(arbiter_);
        if (address(a.refundProtocol()) != address(this)) revert ArbiterNotWired();
        if (DEFAULT_LOCKUP <= uint256(a.challengeWindow()) + a.RESOLUTION_TIMEOUT()) revert LockupTooShort();
        arbiter = a;
        emit Bound(arbiter_);
    }

    // ---------- job life ----------

    /// @notice Lock `amount` (token units) for a job. The caller must have approved this contract.
    /// @param refundTo  where a refund goes. It is the arbiter's "payer": this address, not the caller,
    ///                  files evidence and disputes.
    /// @param specHash  sha256 of the canonical job spec, so a verdict can be tied to this job
    /// @param deliverBy unix time; within (now, now + MAX_DELIVERY_WINDOW]
    function pay(address seller, uint256 amount, address refundTo, bytes32 specHash, uint64 deliverBy)
        external
        returns (uint256 id)
    {
        if (address(arbiter) == address(0)) revert NotBound();
        if (seller == address(0) || refundTo == address(0)) revert ZeroAddress();
        // Both are refused because the arbiter could never rule: it reverts OperatorIsParty.
        address op = arbiter.operator();
        if (seller == msg.sender || seller == refundTo || seller == op || refundTo == op) revert BadParties();
        if (amount == 0) revert ZeroAmount();
        if (amount > maxAmount) revert AmountTooLarge(maxAmount);
        if (specHash == bytes32(0)) revert ZeroHash();
        if (deliverBy <= block.timestamp || deliverBy > block.timestamp + MAX_DELIVERY_WINDOW) revert BadDeadline();

        uint256 lockup = lockupOf[seller];
        if (lockup == 0) lockup = DEFAULT_LOCKUP;
        uint64 releaseAt = uint64(block.timestamp + lockup);

        id = nextJobId++;
        Job storage j = _jobs[id];
        j.buyer = msg.sender;
        j.seller = seller;
        j.refundTo = refundTo;
        j.paidAt = uint64(block.timestamp);
        j.deliverBy = deliverBy;
        j.releaseAt = releaseAt;
        j.state = State.Funded;
        j.amount = amount;
        j.specHash = specHash;
        totalHeld += amount;
        emit JobPaid(id, msg.sender, seller, refundTo, amount, specHash, deliverBy, releaseAt);
        if (!usdc.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
    }

    /// @notice The seller states it delivered, before the deadline and before any ruling. A claim, not
    ///         proof: its only effects are to close `refundAfterDeadline` and open the backstop.
    function markDelivered(uint256 id, bytes32 deliveryHash) external {
        Job storage j = _active(id);
        if (msg.sender != j.seller) revert NotSeller();
        if (deliveryHash == bytes32(0)) revert ZeroHash();
        if (block.timestamp > j.deliverBy) revert DeadlinePassed();
        if (j.delivered) revert AlreadyDelivered();
        if (arbiter.rulings(id).status != PredgeRefundArbiterV2.Status.None) revert AlreadyRuled(id);
        j.delivered = true;
        j.deliveryHash = deliveryHash;
        emit JobDelivered(id, deliveryHash);
    }

    /// @notice The arbiter's operator stores the hash of the signed verdict it is about to rule on. Each
    ///         job takes one verdict and each verdict serves one job, so a replay reverts here, before `rule`.
    function recordVerdict(uint256 id, bytes32 attestationHash, PredgeRefundArbiterV2.Direction direction) external {
        if (msg.sender != arbiter.operator()) revert NotOperator();
        _active(id);
        if (attestationHash == bytes32(0)) revert ZeroHash();
        if (direction == PredgeRefundArbiterV2.Direction.None) revert BadDirection();
        if (attestationJob[attestationHash] != 0) revert VerdictReplayed(attestationHash, attestationJob[attestationHash]);
        if (_verdicts[id].attestationHash != bytes32(0)) revert VerdictAlreadyRecorded(id);
        if (arbiter.rulings(id).status != PredgeRefundArbiterV2.Status.None) revert AlreadyRuled(id);
        attestationJob[attestationHash] = id;
        _verdicts[id] = VerdictRecord(attestationHash, direction, uint64(block.timestamp));
        emit VerdictRecorded(id, attestationHash, direction);
    }

    /// @notice Carry out a decided ruling. Anyone may call. Finalizes an undisputed ruling once its window
    ///         has closed (reverts `WindowOpen` before that), then pays the seller if the final direction is
    ///         Release. A final Refund is paid by the arbiter calling `refundByArbiter`.
    function settle(uint256 id) external {
        Job storage j = _active(id);
        PredgeRefundArbiterV2.Ruling memory r = arbiter.rulings(id);
        if (r.status == PredgeRefundArbiterV2.Status.Ruled) {
            arbiter.finalize(id);
            if (j.state != State.Funded) return; // the ruling was a Refund and has just been paid
            r = arbiter.rulings(id);
        }
        if (!_finalDirectionIsRelease(r)) revert NotSettleable(id);
        _release(id, j);
    }

    /// @notice No delivery claimed by the deadline, and no live ruling: back to `refundTo`. Anyone may call.
    function refundAfterDeadline(uint256 id) external {
        Job storage j = _active(id);
        if (block.timestamp <= j.deliverBy) revert DeadlineNotPassed();
        if (j.delivered) revert AlreadyDelivered();
        _requireNoLiveRuling(id);
        _refund(id, j);
    }

    /// @notice Delivered, lockup over, never ruled or ruling voided: to the seller. Anyone may call. A ruling
    ///         left open past its `expiresAt` must first be voided with `arbiter.expire`.
    function releaseAfterBackstop(uint256 id) external {
        Job storage j = _active(id);
        if (block.timestamp < j.releaseAt) revert BackstopNotReached();
        if (!j.delivered) revert NotDelivered();
        _requireNoLiveRuling(id);
        _release(id, j);
    }

    // ---------- IRefundProtocolV2, the arbiter's view of this contract ----------

    /// @inheritdoc IRefundProtocolV2
    /// @dev `amount` is in native wei (token units * amountScale), as the bond is. A job that is unknown or
    ///      no longer Funded reads as all-zero, so no evidence can be filed and no ruling made on it.
    function paymentInfo(uint256 paymentID)
        external
        view
        returns (address payer, address payee, uint256 amount, uint256 releaseTimestamp)
    {
        Job storage j = _jobs[paymentID];
        if (j.state != State.Funded) return (address(0), address(0), 0, 0);
        return (j.refundTo, j.seller, j.amount * amountScale, j.releaseAt);
    }

    /// @inheritdoc IRefundProtocolV2
    function refundByArbiter(uint256 paymentID) external {
        if (msg.sender != address(arbiter)) revert NotArbiter();
        Job storage j = _active(paymentID);
        if (block.timestamp >= j.releaseAt) revert RefundTooLate();
        _refund(paymentID, j);
    }

    /// @inheritdoc IRefundProtocolV2
    /// @dev Applies to later payments only. The arbiter bounds the value.
    function setLockupSeconds(address recipient, uint256 recipientLockupSeconds) external {
        if (msg.sender != address(arbiter)) revert NotArbiter();
        lockupOf[recipient] = recipientLockupSeconds;
        emit LockupSet(recipient, recipientLockupSeconds);
    }

    // ---------- views ----------

    function jobs(uint256 id) external view returns (Job memory) {
        return _jobs[id];
    }

    function verdicts(uint256 id) external view returns (VerdictRecord memory) {
        return _verdicts[id];
    }

    // ---------- internals ----------

    /// @dev The trap in this contract. An overturn does not store the final direction, and the stored
    ///      direction stays the ORIGINAL ruling, so a final Release is either an upheld Release or an
    ///      overturned Refund. An overturned Release is a final Refund, and it has already been paid.
    function _finalDirectionIsRelease(PredgeRefundArbiterV2.Ruling memory r) private pure returns (bool) {
        return (r.status == PredgeRefundArbiterV2.Status.Finalized && r.direction == PredgeRefundArbiterV2.Direction.Release)
            || (r.status == PredgeRefundArbiterV2.Status.Overturned && r.direction == PredgeRefundArbiterV2.Direction.Refund);
    }

    function _requireNoLiveRuling(uint256 id) private view {
        PredgeRefundArbiterV2.Status s = arbiter.rulings(id).status;
        if (s != PredgeRefundArbiterV2.Status.None && s != PredgeRefundArbiterV2.Status.Voided) revert RulingPending(id);
    }

    function _active(uint256 id) private view returns (Job storage j) {
        j = _jobs[id];
        if (j.state != State.Funded) revert NotActive(id);
    }

    function _release(uint256 id, Job storage j) private {
        j.state = State.Released;
        totalHeld -= j.amount;
        emit JobReleased(id, j.seller, j.amount);
        if (!usdc.transfer(j.seller, j.amount)) revert TransferFailed();
    }

    function _refund(uint256 id, Job storage j) private {
        j.state = State.Refunded;
        totalHeld -= j.amount;
        emit JobRefunded(id, j.refundTo, j.amount);
        if (!usdc.transfer(j.refundTo, j.amount)) revert TransferFailed();
    }
}
