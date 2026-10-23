// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Operated} from "./access/PredgeAccess.sol";
import {PullCredit} from "./access/PullCredit.sol";
import {IAgentJobV2} from "./interfaces/IAgentJobV2.sol";

/// @title  PredgeValidatorBondV2
/// @notice Capital behind a verdict, and the EVALUATOR of an `AgentJobV2`. The job names this
///         contract as its evaluator, so the verdict recorded here is the thing that moves the
///         escrow.
///
///         The acceptance test is deterministic: the job's deliverable counts as DELIVERED only if the
///         provider submitted the output bytes (so the job computed `sha256(output)` on-chain,
///         `hashedOnChain == true`) and that hash equals, by RAW EQUALITY, the `expected` value the
///         CLIENT fixed when it created the job. A hash the provider merely claimed, with no bytes, never
///         counts as delivered. Nothing is hashed again here.
///
///         A FALSE VERDICT CANNOT BE RECORDED (owner decision 23.10.2026, option a). Both sides of the
///         comparison are on-chain at `recordScore`: the hash the chain computed and the `expected` the
///         client committed to. So `recordScore` checks the score against them and reverts
///         `VerdictContradictsEvidence` unless score 100 <=> delivered and score 0 <=> not delivered. This
///         holds for any bond size, including `bondBps = 0`, and needs no challenger, no watcher and no
///         dispute window: there is nothing to challenge, so there is no `challenge` and the bond is
///         credited back to the staker in the same transaction as the verdict.
///
///         Who fixes `expected` (Olympix 5.1.1): the client. A job evaluated by this contract must have
///         `specHash == specHashFor(keccak256(abi.encode(expected, salt)))`, which the client chooses at
///         `createJob`. The operator learns `(expected, salt)` from the client off-chain, checks it against
///         the job before staking, and can only commit to that value.
///
///         Flow:
///           1. `stakeAndCommit(requestHash, commitment, jobId)` (operator). Allowed ONLY while
///              the job is Open, i.e. before any deliverable exists. `commitment` is
///              `keccak256(abi.encode(expected, salt))` and must be the one the client bound into the
///              job's specHash (`requestHash == specHashFor(commitment)`). The bond must be at least
///              `max(minBond, bondBps * escrow / 10000)`.
///           2. The provider submits to the job (with the output bytes, or the job can only fail).
///           3. `recordScore(requestHash, score, expected, salt, reason)` (operator). Requires the
///              job to be Submitted, the reveal to match the commitment, and the score to agree with
///              the on-chain evidence. It then calls `complete` (score 100) or `reject` (score 0) on
///              the job, so the verdict and the money move together, and credits the bond back to the
///              staker.
///           4. `release(requestHash)` (anyone) if the job expired with no verdict. If the provider never
///              submitted, nothing was owed and the bond goes back to the staker. If the provider DID submit
///              and the operator stayed silent until the evaluation window closed (Olympix 5.2.2), the
///              bond is FORFEITED to the provider: silence on submitted work is not free.
///
///         What the bond is for, after option (a): LIVENESS, not correctness. Correctness is enforced by
///         `recordScore`. The bond is what the operator loses if it stays silent on a submitted job.
///
///         Honest limits, stated so they are not mistaken for guarantees:
///           * The client defines `expected`. A provider should obtain `(expected, salt)` from the client
///             and check it against the job's specHash before working; knowing `expected` does not
///             let anyone pass without the real bytes, because only an on-chain hash counts.
///           * A pass needs the output bytes in calldata; large outputs cost the provider gas.
///           * On silence the provider receives the bond, not the escrow: the job's timeout policy
///             still refunds the escrow to the client. With `bondBps = 0` the bond is a flat floor.
///           * The operator's capital is locked until the job ends. A client picks the job's
///             `expiredAt`, so an operator should read it before staking.
///           * Only the deterministic `sha256(deliverable) == expected` test is covered. Subjective
///             or "void" outcomes are not bonded.
///
/// @dev    Native value only, in the chain's native wei. Roles: `owner` (Safe) sets bounded
///         parameters and rotates `operator`; `operator` (hot key) stakes and scores. Parameters
///         are not retroactive: the bond amount is fixed when staked. Payouts are pull-based. The
///         contract holds, at all times, at least `totalBonded + totalCredit`.
contract PredgeValidatorBondV2 is Operated, PullCredit {
    enum Status {
        None,
        Committed, // bond posted, no verdict yet
        Scored, // verdict recorded (it matches the evidence), bond credited back to the staker (final)
        Released, // job expired before any submission, bond credited back to the staker (final)
        Forfeited // job expired after a submission with no verdict, bond credited to the provider (final)
    }

    struct Stake {
        address staker; // the operator key that posted the bond; the only party it is ever paid back to
        Status status;
        uint8 score; // 100 delivered / 0 not delivered, set when scored
        uint64 stakedAt;
        uint64 scoredAt; // set when scored; always >= the job's submittedAt
        uint256 jobId;
        uint256 bond; // the posted bond while Committed; zero once closed
        bytes32 commitment; // keccak256(abi.encode(expected, salt))
        bytes32 expected; // zero until revealed at recordScore
    }

    uint16 public constant MAX_BPS = 10_000;

    IAgentJobV2 public immutable job;

    /// @notice Absolute floor for a bond, in native wei. Applies to stakes made after a change.
    uint256 public minBond;
    /// @notice Bond as basis points of the job escrow (10000 = 100%). Applies to future stakes.
    uint16 public bondBps;

    /// @notice Sum of bonds currently held (Committed).
    uint256 public totalBonded;

    mapping(bytes32 => Stake) public stakes;

    event Committed(bytes32 indexed requestHash, uint256 indexed jobId, address indexed staker, bytes32 commitment, uint256 bond);
    event Scored(bytes32 indexed requestHash, uint256 indexed jobId, uint8 score, bytes32 expected, address staker, uint256 bond);
    event Released(bytes32 indexed requestHash, address indexed staker, uint256 bond);
    event Forfeited(bytes32 indexed requestHash, address indexed provider, uint256 bond);
    event ParamsUpdated(uint256 minBond, uint16 bondBps);

    error ZeroHash();
    error BadParams();
    error AlreadyCommitted();
    error NotCommitted();
    error BadStatus();
    error NotOpen();
    error NotSubmitted();
    error JobNotBound();
    error ProviderIsOperator();
    error ClientIsOperator();
    error CommitmentNotBound();
    error BondTooSmall(uint256 required);
    error BadScore();
    error BadReveal();
    error VerdictContradictsEvidence();
    error JobNotExpired();

    /// @param owner_    the Safe: sets bounded parameters, rotates the operator
    /// @param operator_ the hot key that stakes and scores
    /// @param job_      the `AgentJobV2` this bond evaluates; immutable
    /// @param minBond_  absolute floor for a bond, non-zero
    /// @param bondBps_  bond as basis points of escrow, at most 10000
    constructor(address owner_, address operator_, address job_, uint256 minBond_, uint16 bondBps_)
        Operated(owner_, operator_)
    {
        if (job_ == address(0)) revert ZeroAddress();
        job = IAgentJobV2(job_);
        _setParams(minBond_, bondBps_);
    }

    /// @notice Owner-only parameter change, bounded and NOT retroactive: existing stakes keep
    ///         the bond they were made with.
    function setParams(uint256 minBond_, uint16 bondBps_) external onlyOwner {
        _setParams(minBond_, bondBps_);
    }

    /// @notice The bond a stake against `escrow` must post right now: `max(minBond, ceil(escrow * bondBps / 10000))`.
    function requiredBond(uint256 escrow) public view returns (uint256) {
        uint256 scaled = (escrow * bondBps + MAX_BPS - 1) / MAX_BPS;
        return scaled > minBond ? scaled : minBond;
    }

    /// @notice The specHash a client must give a job evaluated by this contract, for a commitment
    ///         `keccak256(abi.encode(expected, salt))`. Domain separated by chain and by this contract.
    function specHashFor(bytes32 commitment) public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), commitment));
    }

    /// @notice The only verdict `recordScore` accepts for job `jobId` against `expected`: 100 if the
    ///         provider submitted the bytes and their on-chain sha256 equals `expected`, otherwise 0.
    ///         Meaningful once the job is Submitted.
    function verdictFor(uint256 jobId, bytes32 expected) public view returns (uint8) {
        IAgentJobV2.Job memory j = job.getJob(jobId);
        return _delivered(j, expected) ? 100 : 0;
    }

    /// @notice Post the bond and commit the hidden acceptance test, while the job is still Open.
    /// @param requestHash the job's `specHash`; must equal `specHashFor(commitment)`
    /// @param commitment  `keccak256(abi.encode(expected, salt))` as fixed by the client in the specHash
    /// @param jobId       the job this verdict will settle; this contract must be its evaluator
    function stakeAndCommit(bytes32 requestHash, bytes32 commitment, uint256 jobId) external payable onlyOperator {
        if (requestHash == bytes32(0) || commitment == bytes32(0)) revert ZeroHash();
        Stake storage s = stakes[requestHash];
        if (s.status != Status.None) revert AlreadyCommitted();
        // The client fixed `expected` (hidden behind the salt) in the specHash: the operator cannot pick its own.
        if (requestHash != specHashFor(commitment)) revert CommitmentNotBound();

        IAgentJobV2.Job memory j = job.getJob(jobId);
        // Only while Open and unexpired: the stake must exist before the work does.
        if (j.state != IAgentJobV2.State.Open || block.timestamp >= j.expiredAt) revert NotOpen();
        if (j.specHash != requestHash || j.evaluator != address(this)) revert JobNotBound();
        // A provider that is also the operator would decide whether to deliver and when to stay silent.
        if (j.provider == msg.sender) revert ProviderIsOperator();
        // A client that is also the operator would judge its own job (Olympix 5.2.3).
        if (j.client == msg.sender) revert ClientIsOperator();
        uint256 required = requiredBond(j.escrow);
        if (msg.value < required) revert BondTooSmall(required);

        s.staker = msg.sender;
        s.status = Status.Committed;
        s.stakedAt = uint64(block.timestamp);
        s.jobId = jobId;
        s.bond = msg.value;
        s.commitment = commitment;
        totalBonded += msg.value;
        emit Committed(requestHash, jobId, msg.sender, commitment, msg.value);
    }

    /// @notice Reveal the committed test, record the verdict, settle the job with it, and credit the
    ///         bond back to the staker. Reverts `VerdictContradictsEvidence` on a false verdict.
    /// @param score  100 = delivered (job `complete`s, provider is credited), 0 = not delivered
    ///               (job `reject`s, client is credited). Must equal `verdictFor(jobId, expected)`.
    /// @param expected,salt the preimage of the commitment
    /// @param reason the attestation commitment passed to the job (Predge: keccak256 of the signed verdict)
    function recordScore(bytes32 requestHash, uint8 score, bytes32 expected, bytes32 salt, bytes32 reason)
        external
        onlyOperator
    {
        if (score != 0 && score != 100) revert BadScore();
        Stake storage s = stakes[requestHash];
        if (s.status == Status.None) revert NotCommitted();
        if (s.status != Status.Committed) revert BadStatus();
        if (keccak256(abi.encode(expected, salt)) != s.commitment) revert BadReveal();
        // Re-checked here, not only at stake time: after an operator rotation the NEW operator must not be able
        // to score a job it is a party to, while inheriting the old operator's stake.
        IAgentJobV2.Job memory j = job.getJob(s.jobId);
        if (j.provider == msg.sender) revert ProviderIsOperator();
        if (j.client == msg.sender) revert ClientIsOperator();
        // Scoring needs a submission: the verdict is judged against a deliverable that exists.
        if (j.state != IAgentJobV2.State.Submitted) revert NotSubmitted();
        // Option (a): the evidence decides. A pass needs an on-chain hash equal to `expected`; a fail needs the opposite.
        if ((score == 100) != _delivered(j, expected)) revert VerdictContradictsEvidence();

        s.expected = expected;
        s.score = score;
        s.scoredAt = uint64(block.timestamp);
        uint256 bond = _close(s, Status.Scored, s.staker);
        emit Scored(requestHash, s.jobId, score, expected, s.staker, bond);

        if (score == 100) job.complete(s.jobId, reason, "");
        else job.reject(s.jobId, reason, "");
    }

    /// @notice Close a stake whose job expired without a verdict. Anyone may trigger it. If the provider
    ///         never submitted, the bond is credited back to the staker. If the provider submitted and the
    ///         operator let the evaluation window close without scoring, the bond is credited to the
    ///         provider instead.
    function release(bytes32 requestHash) external {
        Stake storage s = stakes[requestHash];
        if (s.status == Status.None) revert NotCommitted();
        if (s.status != Status.Committed) revert BadStatus();
        IAgentJobV2.Job memory j = job.getJob(s.jobId);
        if (j.state != IAgentJobV2.State.Expired) revert JobNotExpired();
        if (j.submittedAt == 0) {
            uint256 bond = _close(s, Status.Released, s.staker);
            emit Released(requestHash, s.staker, bond);
        } else {
            uint256 bond = _close(s, Status.Forfeited, j.provider);
            emit Forfeited(requestHash, j.provider, bond);
        }
    }

    /// @dev Delivered means: the bytes were hashed on-chain AND the hash equals the client's `expected`.
    function _delivered(IAgentJobV2.Job memory j, bytes32 expected) private pure returns (bool) {
        return j.hashedOnChain && j.deliverable == expected;
    }

    function _close(Stake storage s, Status to, address payee) private returns (uint256 bond) {
        bond = s.bond;
        s.status = to;
        s.bond = 0;
        totalBonded -= bond;
        _addCredit(payee, bond);
    }

    function _setParams(uint256 minBond_, uint16 bondBps_) private {
        if (minBond_ == 0 || bondBps_ > MAX_BPS) revert BadParams();
        minBond = minBond_;
        bondBps = bondBps_;
        emit ParamsUpdated(minBond_, bondBps_);
    }
}
