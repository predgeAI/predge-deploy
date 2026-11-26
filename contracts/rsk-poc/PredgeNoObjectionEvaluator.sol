// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAgentJobV2} from "../v2/interfaces/IAgentJobV2.sol";

interface IAgentJobV2Window {
    function evaluationWindow() external view returns (uint64);
}

/// @title  PredgeNoObjectionEvaluator
/// @notice TESTNET PoC ONLY (Rootstock testnet, IBUKI / Re.RISE). A minimal evaluator for an unchanged
///         `AgentJobV2` that expresses one contract rule: "no written objection within N days after the
///         completion package is submitted => the payment is released to the contractor; a written
///         objection in time => the payment is held for human review".
///
///         Why an adapter: `AgentJobV2`'s own timeout refunds the CLIENT when the evaluator is silent.
///         The client's silence paying the CONTRACTOR has to be an evaluator decision, taken inside the
///         job's `evaluationWindow`. This contract is that evaluator. It holds no funds; the escrow stays in
///         `AgentJobV2`, and every payout is a pull credit there.
///
///         Per job (the job must name this contract as its evaluator):
///           1. Client: `createJob(provider, evaluator = this, specHash = specHashFor(checklistDocHash, n), expiry)`,
///              escrowing the milestone amount. `checklistDocHash` is the hash of the agreed evidence checklist
///              (n required items). Only hashes go on-chain.
///           2. Contractor: `submit(jobId, sha256(manifest), manifest)` before the expiry, where
///              `manifest = manifestFor(checklistDocHash, fileHashes)` and `fileHashes` has one non-zero hash per
///              checklist item. `AgentJobV2` hashes the bytes on-chain.
///           3a. No objection: once `objectionPeriod` has passed since the submission, ANYONE calls
///               `releaseOnSilence` with the preimage. It checks the package deterministically (bound to the
///               committed checklist, n items, no empty item, hashed on-chain) and completes the job: the
///               contractor is credited.
///           3b. Objection: the client calls `object(jobId, objectionHash)` before `objectionPeriod` ends
///               (the objection text stays off-chain; its hash is recorded). The job is on hold: nobody can
///               release it on silence. Only `reviewer` can then decide (`resolve`), pay or refund.
///           4. If nobody decides before `AgentJobV2`'s `submittedAt + evaluationWindow` (an incomplete package
///              that cannot be released, or a reviewer that stays silent), anyone calls
///              `AgentJobV2.claimRefund`: the CLIENT is refunded (the unchanged AgentJobV2 default).
///
///         Out of scope by design (PoC agreed on the Rootstock forum, #30/#31): no judgement of photos or
///         volumes, no staged/multi-milestone logic (one milestone = one job), no bond, no slashing.
///         The reviewer is trusted for objected jobs only and cannot touch a job without an objection.
contract PredgeNoObjectionEvaluator {
    bytes32 public constant CHECKLIST_TAG = keccak256("predge.rsk-poc.evidence-checklist.v1");
    bytes32 public constant RELEASE_TAG = keccak256("predge.rsk-poc.release-on-silence.v1");

    IAgentJobV2 public immutable job;
    /// @notice The human reviewer (PoC: a test wallet; in production a Safe or an arbitration service).
    address public immutable reviewer;
    /// @notice Seconds after the submission during which the client may object (IBUKI annex: 10 days).
    uint64 public immutable objectionPeriod;
    /// @notice Snapshot of the job contract's evaluation window; the reviewer must decide before it ends.
    uint64 public immutable evaluationWindow;

    struct Objection {
        bytes32 hash; // hash of the written objection (off-chain document)
        uint64 at; // block time it was filed
        bool resolved;
    }

    mapping(uint256 => Objection) private _objections;

    event Objected(uint256 indexed jobId, address indexed client, bytes32 objectionHash);
    event ReleasedOnSilence(uint256 indexed jobId, address indexed caller, bytes32 checklistDocHash, uint256 items);
    event Resolved(uint256 indexed jobId, address indexed reviewer, bool paidProvider, bytes32 decisionHash);

    error ZeroAddress();
    error BadPeriod();
    error NotOurJob();
    error BadState();
    error NotClient();
    error NotReviewer();
    error ReviewerIsParty();
    error ZeroHash();
    error AlreadyObjected();
    error NoObjection();
    error AlreadyResolved();
    error ObjectionPeriodOver();
    error ObjectionPeriodRunning();
    error OnHold();
    error IncompletePackage();

    constructor(address job_, address reviewer_, uint64 objectionPeriod_) {
        if (job_ == address(0) || reviewer_ == address(0)) revert ZeroAddress();
        uint64 w = IAgentJobV2Window(job_).evaluationWindow();
        // The release after silence and the reviewer's decision must both fit inside the job's window.
        if (objectionPeriod_ == 0 || objectionPeriod_ >= w) revert BadPeriod();
        job = IAgentJobV2(job_);
        reviewer = reviewer_;
        objectionPeriod = objectionPeriod_;
        evaluationWindow = w;
    }

    // ---------------------------------------------------------------- helpers (pure / view)

    /// @notice The `specHash` a client must commit in `createJob` for a checklist of `items` entries.
    ///         Domain-separated by chain and by this evaluator.
    function specHashFor(bytes32 checklistDocHash, uint256 items) public view returns (bytes32) {
        return keccak256(abi.encode(CHECKLIST_TAG, block.chainid, address(this), checklistDocHash, items));
    }

    /// @notice The bytes the contractor submits as the job output (their sha256 is the deliverable).
    function manifestFor(bytes32 checklistDocHash, bytes32[] calldata fileHashes) external pure returns (bytes memory) {
        return abi.encode(checklistDocHash, fileHashes);
    }

    /// @notice Deterministic package check for a submitted job: the manifest was hashed on-chain, it is
    ///         bound to the committed checklist, it has exactly the committed number of items and none is empty.
    function packageComplete(uint256 jobId, bytes32 checklistDocHash, bytes32[] calldata fileHashes)
        public
        view
        returns (bool)
    {
        IAgentJobV2.Job memory j = job.getJob(jobId);
        if (j.evaluator != address(this) || j.state != IAgentJobV2.State.Submitted || !j.hashedOnChain) return false;
        if (j.specHash != specHashFor(checklistDocHash, fileHashes.length)) return false;
        if (sha256(abi.encode(checklistDocHash, fileHashes)) != j.deliverable) return false;
        for (uint256 i; i < fileHashes.length; ++i) {
            if (fileHashes[i] == bytes32(0)) return false;
        }
        return fileHashes.length != 0;
    }

    function objectionOf(uint256 jobId) external view returns (Objection memory) {
        return _objections[jobId];
    }

    /// @notice End of the objection period for a submitted job (0 if not submitted).
    function objectionDeadline(uint256 jobId) public view returns (uint256) {
        IAgentJobV2.Job memory j = job.getJob(jobId);
        return j.submittedAt == 0 ? 0 : uint256(j.submittedAt) + objectionPeriod;
    }

    // ---------------------------------------------------------------- actions

    /// @notice Client files a written objection (its hash) inside the objection period. Puts the job on hold.
    function object(uint256 jobId, bytes32 objectionHash) external {
        if (objectionHash == bytes32(0)) revert ZeroHash();
        IAgentJobV2.Job memory j = _submitted(jobId);
        if (msg.sender != j.client) revert NotClient();
        if (block.timestamp >= uint256(j.submittedAt) + objectionPeriod) revert ObjectionPeriodOver();
        Objection storage o = _objections[jobId];
        if (o.hash != bytes32(0)) revert AlreadyObjected();
        o.hash = objectionHash;
        o.at = uint64(block.timestamp);
        emit Objected(jobId, msg.sender, objectionHash);
    }

    /// @notice After an objection period without objection, release a complete package to the contractor.
    ///         Anyone may call (the credit always goes to the job's provider).
    function releaseOnSilence(uint256 jobId, bytes32 checklistDocHash, bytes32[] calldata fileHashes) external {
        IAgentJobV2.Job memory j = _submitted(jobId);
        if (_objections[jobId].hash != bytes32(0)) revert OnHold();
        if (block.timestamp < uint256(j.submittedAt) + objectionPeriod) revert ObjectionPeriodRunning();
        if (!packageComplete(jobId, checklistDocHash, fileHashes)) revert IncompletePackage();
        emit ReleasedOnSilence(jobId, msg.sender, checklistDocHash, fileHashes.length);
        job.complete(jobId, keccak256(abi.encode(RELEASE_TAG, jobId, j.deliverable)), "");
    }

    /// @notice The reviewer decides an objected job: pay the contractor or refund the client. Must happen
    ///         before the job's evaluation window ends (AgentJobV2 enforces it); after that the client is refunded.
    function resolve(uint256 jobId, bool payProvider, bytes32 decisionHash) external {
        if (msg.sender != reviewer) revert NotReviewer();
        if (decisionHash == bytes32(0)) revert ZeroHash();
        IAgentJobV2.Job memory j = _submitted(jobId);
        if (msg.sender == j.client || msg.sender == j.provider) revert ReviewerIsParty();
        Objection storage o = _objections[jobId];
        if (o.hash == bytes32(0)) revert NoObjection();
        if (o.resolved) revert AlreadyResolved();
        o.resolved = true;
        emit Resolved(jobId, msg.sender, payProvider, decisionHash);
        if (payProvider) job.complete(jobId, decisionHash, "");
        else job.reject(jobId, decisionHash, "");
    }

    function _submitted(uint256 jobId) private view returns (IAgentJobV2.Job memory j) {
        j = job.getJob(jobId);
        if (j.evaluator != address(this)) revert NotOurJob();
        if (j.state != IAgentJobV2.State.Submitted) revert BadState();
    }
}
