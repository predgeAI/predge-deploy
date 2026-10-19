// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAgentJobV2} from "./interfaces/IAgentJobV2.sol";
import {PullCredit} from "./access/PullCredit.sol";

/// @title  AgentJobV2
/// @notice A minimal ERC-8183-style agent job with escrowed native value and an INDEPENDENT
///         evaluator named at creation. In Predge's deployment the evaluator is the
///         `PredgeValidatorBondV2` contract, so the evaluator's verdict is backed by a bond and
///         moves the money in the same transaction.
///
///         Lifecycle:
///           createJob  (client escrows value, names provider, evaluator, spec and an expiry)
///           submit     (provider, strictly before `expiredAt`)
///           complete / reject (evaluator, strictly before `submittedAt + evaluationWindow`)
///           claimRefund (anyone may trigger; the CLIENT is credited) when
///                         - the job is still Open at or after `expiredAt`, or
///                         - the job is Submitted and the evaluator stayed silent until
///                           `submittedAt + evaluationWindow`.
///
///         Timeout policy (documented choice): if the evaluator never decides, the CLIENT is
///         refunded, as ERC-8183 does on expiry. The alternative (pay the provider by default)
///         would let a silent or bribed evaluator pay out unverified work. The cost of this
///         choice is borne by the provider, who did the work; providers should only work for
///         evaluators they trust to answer inside the window.
///
///         Money never leaves by push. Every payout, whether to provider or client, is credited
///         to `credit[account]` and pulled with `withdraw` / `withdrawTo`, so a reverting or
///         blocklisted recipient can neither force an outcome nor lock another party's funds.
///
/// @dev    Native value only; amounts are in the chain's native wei. There is no owner, no
///         admin, no upgrade path and no mutable parameter: `evaluationWindow` is immutable.
///         Deliverable hashing: `sha256`. When the provider supplies the output bytes, the hash is
///         computed on-chain with the sha256 precompile (so the stored hash provably belongs to
///         those bytes); otherwise the provider's claimed hash is stored as given.
contract AgentJobV2 is IAgentJobV2, PullCredit {
    /// @notice Seconds the evaluator has to decide after a submission. Immutable, so it cannot
    ///         be changed under a job that is already running.
    uint64 public immutable evaluationWindow;

    uint256 public jobCount;
    /// @notice Sum of every job's escrow that has not been credited yet (Open or Submitted).
    uint256 public totalEscrowed;

    mapping(uint256 => Job) private _jobs;

    event JobCreated(
        uint256 indexed jobId,
        address indexed client,
        address indexed evaluator,
        address provider,
        uint256 escrow,
        uint64 expiredAt,
        bytes32 specHash
    );
    event Submitted(uint256 indexed jobId, address indexed provider, bytes32 deliverable, bool hashedOnChain);
    event Completed(uint256 indexed jobId, address indexed evaluator, address indexed recipient, uint256 amount, bytes32 reason);
    event Rejected(uint256 indexed jobId, address indexed evaluator, address indexed recipient, uint256 amount, bytes32 reason);
    event Refunded(uint256 indexed jobId, address indexed caller, address indexed recipient, uint256 amount);

    error ZeroAddress();
    error ZeroEscrow();
    error BadExpiry();
    error BadWindow();
    error NotProvider();
    error NotEvaluator();
    error BadState();
    error PastDeadline();
    error NotExpired();
    error HashMismatch();
    error ZeroDeliverable();

    /// @param evaluationWindow_ seconds the evaluator has after a submission; must be non-zero.
    constructor(uint64 evaluationWindow_) {
        if (evaluationWindow_ == 0) revert BadWindow();
        evaluationWindow = evaluationWindow_;
    }

    /// @notice Client opens a job, escrows `msg.value`, and names the provider, the independent
    ///         evaluator, the acceptance-test commitment and the expiry.
    /// @param provider  the worker; paid on `complete`
    /// @param evaluator the only address that can complete or reject
    /// @param specHash  the acceptance test commitment (the Predge `requestHash`)
    /// @param expiredAt unix time; the provider must submit strictly before it, after it the
    ///                  client can reclaim the escrow of a job that was never submitted
    function createJob(address provider, address evaluator, bytes32 specHash, uint64 expiredAt)
        external
        payable
        returns (uint256 jobId)
    {
        if (provider == address(0) || evaluator == address(0)) revert ZeroAddress();
        if (msg.value == 0) revert ZeroEscrow();
        if (expiredAt <= block.timestamp) revert BadExpiry();
        jobId = ++jobCount;
        totalEscrowed += msg.value;
        Job storage j = _jobs[jobId];
        j.client = msg.sender;
        j.provider = provider;
        j.evaluator = evaluator;
        j.escrow = msg.value;
        j.expiredAt = expiredAt;
        j.state = State.Open;
        j.specHash = specHash;
        emit JobCreated(jobId, msg.sender, evaluator, provider, msg.value, expiredAt, specHash);
    }

    /// @notice Provider submits the deliverable, strictly before `expiredAt`.
    /// @param deliverable sha256 of the output. Must be non-zero.
    /// @param output      optional output bytes. If non-empty, `sha256(output)` must equal
    ///                    `deliverable` (reverts `HashMismatch` otherwise) and the job records that
    ///                    the hash was verified on-chain. If empty, the claimed hash is stored.
    function submit(uint256 jobId, bytes32 deliverable, bytes calldata output) external {
        Job storage j = _jobs[jobId];
        if (j.state != State.Open) revert BadState();
        if (msg.sender != j.provider) revert NotProvider();
        if (block.timestamp >= j.expiredAt) revert PastDeadline();
        if (deliverable == bytes32(0)) revert ZeroDeliverable();
        bool onChain = output.length != 0;
        if (onChain && sha256(output) != deliverable) revert HashMismatch();
        j.deliverable = deliverable;
        j.hashedOnChain = onChain;
        j.submittedAt = uint64(block.timestamp);
        j.state = State.Submitted;
        emit Submitted(jobId, msg.sender, deliverable, onChain);
    }

    /// @notice ERC-8183 `complete`. Evaluator only, while the job is Submitted and the
    ///         evaluation window is still running. Credits the provider.
    /// @param reason the evaluator's attestation commitment (Predge: keccak256 of the signed verdict)
    function complete(uint256 jobId, bytes32 reason, bytes calldata) external {
        Job storage j = _decide(jobId, reason);
        j.state = State.Completed;
        uint256 amt = _release(j, j.provider);
        emit Completed(jobId, msg.sender, j.provider, amt, reason);
    }

    /// @notice ERC-8183 `reject`. Evaluator only, same timing as `complete`. Credits the client.
    function reject(uint256 jobId, bytes32 reason, bytes calldata) external {
        Job storage j = _decide(jobId, reason);
        j.state = State.Rejected;
        uint256 amt = _release(j, j.client);
        emit Rejected(jobId, msg.sender, j.client, amt, reason);
    }

    /// @notice Refund the client of a job that ran out of time. Callable by anyone (the credit
    ///         always goes to the client): see the contract notes for the two cases.
    function claimRefund(uint256 jobId) external {
        Job storage j = _jobs[jobId];
        State s = j.state;
        if (s == State.Open) {
            if (block.timestamp < j.expiredAt) revert NotExpired();
        } else if (s == State.Submitted) {
            if (block.timestamp < uint256(j.submittedAt) + evaluationWindow) revert NotExpired();
        } else {
            revert BadState();
        }
        j.state = State.Expired;
        uint256 amt = _release(j, j.client);
        emit Refunded(jobId, msg.sender, j.client, amt);
    }

    /// @inheritdoc IAgentJobV2
    function getJob(uint256 jobId) external view returns (Job memory) {
        return _jobs[jobId];
    }

    function _decide(uint256 jobId, bytes32 reason) private returns (Job storage j) {
        j = _jobs[jobId];
        if (msg.sender != j.evaluator) revert NotEvaluator();
        if (j.state != State.Submitted) revert BadState();
        if (block.timestamp >= uint256(j.submittedAt) + evaluationWindow) revert PastDeadline();
        j.reason = reason;
    }

    function _release(Job storage j, address to) private returns (uint256 amt) {
        amt = j.escrow;
        j.escrow = 0;
        totalEscrowed -= amt;
        _addCredit(to, amt);
    }
}
