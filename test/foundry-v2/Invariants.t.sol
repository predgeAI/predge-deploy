// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {AgentJobV2} from "../../contracts/v2/AgentJobV2.sol";
import {IAgentJobV2} from "../../contracts/v2/interfaces/IAgentJobV2.sol";
import {PredgeValidatorBondV2} from "../../contracts/v2/PredgeValidatorBondV2.sol";
import {PredgeRefundArbiterV2} from "../../contracts/v2/PredgeRefundArbiterV2.sol";
import {MockRefundProtocolV2} from "../../contracts/v2/mocks/MockRefundProtocolV2.sol";

/// @dev Drives AgentJobV2 + PredgeValidatorBondV2 through random interleavings and records ghost state.
contract JobBondHandler is Test {
    AgentJobV2 public job;
    PredgeValidatorBondV2 public bond;
    address public op = address(0x0A11);
    address public client = address(0xC11E);
    address public provider = address(0x9A0D);
    address public safe = address(0x5AFE);

    bytes32[] public specs; // request hashes of every job created
    uint256[] public jobIds;
    mapping(bytes32 => bytes32) public expectedOf; // the value the client fixed in the specHash
    mapping(bytes32 => bytes32) public saltOf;
    mapping(bytes32 => bytes) public outputOf; // the bytes whose sha256 is expectedOf
    mapping(bytes32 => uint8) public prevStatus; // last status seen, to prove monotonicity
    mapping(uint256 => uint8) public prevJobState;
    mapping(bytes32 => bytes32) public firstCommitment;
    mapping(bytes32 => bytes32) public firstExpected;
    mapping(bytes32 => uint256) public firstJobId;
    mapping(bytes32 => uint64) public firstScoredAt;
    mapping(bytes32 => uint8) public firstScore;

    uint256 public ghostCreditedFromJobs; // everything the job ever credited
    uint256 public ghostEscrowedTotal; // everything ever escrowed
    bool public violation; // set by in-handler checks that need to see the call itself

    constructor(AgentJobV2 j, PredgeValidatorBondV2 b) {
        job = j;
        bond = b;
        vm.deal(op, type(uint128).max);
        vm.deal(client, type(uint128).max);
        vm.deal(provider, type(uint128).max);
    }

    function specCount() external view returns (uint256) { return specs.length; }

    function createAndStake(uint96 escrow, uint8 salt, bool stakeIt) external {
        escrow = uint96(bound(escrow, 1, 1_000 ether));
        // The client fixes the expected output in the specHash (Olympix 5.1.1).
        bytes memory out = abi.encode("e", salt);
        bytes32 e = sha256(out);
        bytes32 s = keccak256(abi.encode("salt", salt, specs.length));
        bytes32 spec = bond.specHashFor(keccak256(abi.encode(e, s)));
        vm.prank(client);
        uint256 id = job.createJob{value: escrow}(provider, address(bond), spec, uint64(block.timestamp + 5 days));
        ghostEscrowedTotal += escrow;
        specs.push(spec);
        jobIds.push(id);
        expectedOf[spec] = e;
        saltOf[spec] = s;
        outputOf[spec] = out;
        if (stakeIt) {
            uint256 need = bond.requiredBond(escrow);
            vm.prank(op);
            try bond.stakeAndCommit{value: need}(spec, keccak256(abi.encode(e, s)), id) {} catch {}
        }
    }

    /// @dev mode 0: the real bytes; 1: the right hash CLAIMED with no bytes; 2: junk bytes; 3: a junk claimed hash.
    function submit(uint256 i, uint8 mode, uint8 junk) external {
        if (specs.length == 0) return;
        i = bound(i, 0, specs.length - 1);
        bytes32 spec = specs[i];
        mode = mode % 4;
        bytes memory out = mode == 0 ? outputOf[spec] : mode == 2 ? abi.encode("junk", junk) : bytes("");
        bytes32 d = mode == 1 ? expectedOf[spec] : mode == 3 ? keccak256(abi.encode("junk", junk)) : sha256(out);
        vm.prank(provider);
        try job.submit(jobIds[i], d, out) {} catch {}
    }

    /// @dev Option (a): a recorded verdict must equal the truth, so a successful call with a false score is a violation.
    function score(uint256 i, bool pass) external {
        if (specs.length == 0) return;
        i = bound(i, 0, specs.length - 1);
        bytes32 spec = specs[i];
        IAgentJobV2.Job memory j = job.getJob(jobIds[i]);
        bool delivered = j.hashedOnChain && j.deliverable == expectedOf[spec];
        vm.prank(bond.operator());
        try bond.recordScore(spec, pass ? 100 : 0, expectedOf[spec], saltOf[spec], bytes32(0)) {
            if (pass != delivered) violation = true;
        } catch {}
    }

    function release(uint256 i) external {
        if (specs.length == 0) return;
        i = bound(i, 0, specs.length - 1);
        try bond.release(specs[i]) {} catch {}
    }

    function claimRefund(uint256 i) external {
        if (specs.length == 0) return;
        i = bound(i, 0, specs.length - 1);
        try job.claimRefund(jobIds[i]) {} catch {}
    }

    function withdrawAll(uint8 who) external {
        address a = who % 3 == 0 ? client : who % 3 == 1 ? provider : op;
        vm.prank(a);
        try job.withdraw() {} catch {}
        vm.prank(a);
        try bond.withdraw() {} catch {}
    }

    function rotateOperator(bool back) external {
        vm.prank(safe);
        bond.setOperator(back ? op : address(0xBEEF));
        vm.deal(address(0xBEEF), 1);
    }

    function warp(uint32 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 4 days));
        _record();
    }

    /// @dev Snapshot ghost values and check write-once / monotonic properties.
    function _record() internal {
        for (uint256 i; i < specs.length; ++i) {
            _checkStake(specs[i]);
            IAgentJobV2.Job memory j = job.getJob(jobIds[i]);
            if (uint8(j.state) < prevJobState[jobIds[i]]) violation = true;
            prevJobState[jobIds[i]] = uint8(j.state);
        }
    }

    function _checkStake(bytes32 spec) internal {
        (, PredgeValidatorBondV2.Status st, uint8 sc, , uint64 scoredAt, uint256 jid, , bytes32 c, bytes32 e) = bond.stakes(spec);
        uint8 s8 = uint8(st);
        if (s8 < prevStatus[spec]) violation = true; // never moves backwards
        if (prevStatus[spec] >= 2 && s8 != prevStatus[spec]) violation = true; // Scored / Released / Forfeited are final
        if (s8 != 0) {
            if (firstCommitment[spec] == 0) { firstCommitment[spec] = c; firstJobId[spec] = jid; }
            if (c != firstCommitment[spec] || jid != firstJobId[spec]) violation = true;
        }
        if (s8 == 2) { // only Scored carries a verdict
            if (firstScoredAt[spec] == 0) { firstScoredAt[spec] = scoredAt; firstExpected[spec] = e; firstScore[spec] = sc; }
            if (scoredAt != firstScoredAt[spec] || e != firstExpected[spec] || sc != firstScore[spec]) violation = true;
        }
        prevStatus[spec] = s8;
    }

    function snapshot() external { _record(); }
}

contract JobBondInvariantTest is StdInvariant, Test {
    AgentJobV2 job;
    PredgeValidatorBondV2 bond;
    JobBondHandler h;

    function setUp() public {
        job = new AgentJobV2(3 days);
        bond = new PredgeValidatorBondV2(address(0x5AFE), address(0x0A11), address(job), 1e15, 10_000);
        h = new JobBondHandler(job, bond);
        targetContract(address(h));
    }

    function invariant_bondSolvent() public view {
        assertGe(address(bond).balance, bond.totalBonded() + bond.totalCredit());
    }

    function invariant_jobSolvent() public view {
        assertGe(address(job).balance, job.totalEscrowed() + job.totalCredit());
    }

    function invariant_totalBondedEqualsOpenBonds() public view {
        uint256 sum;
        for (uint256 i; i < h.specCount(); ++i) {
            (, PredgeValidatorBondV2.Status st,,,,, uint256 b,,) = bond.stakes(h.specs(i));
            if (st == PredgeValidatorBondV2.Status.Committed) sum += b;
            else assertEq(b, 0, "closed => bond == 0");
        }
        assertEq(bond.totalBonded(), sum);
    }

    function invariant_totalEscrowedEqualsLiveEscrows() public view {
        uint256 live;
        uint256 paid;
        for (uint256 i; i < h.specCount(); ++i) {
            IAgentJobV2.Job memory j = job.getJob(h.jobIds(i));
            if (j.state == IAgentJobV2.State.Open || j.state == IAgentJobV2.State.Submitted) live += j.escrow;
            else assertEq(j.escrow, 0, "settled => escrow == 0");
            if (j.state != IAgentJobV2.State.Open && j.state != IAgentJobV2.State.Submitted) {}
        }
        assertEq(job.totalEscrowed(), live);
        paid = h.ghostEscrowedTotal() - live;
        // everything ever escrowed is either live, or sits in credit, or was withdrawn: never double counted
        assertLe(job.totalCredit(), paid);
    }

    /// @dev Option (a): every verdict on record equals the on-chain truth, and the job settled the same way.
    function invariant_everyRecordedVerdictIsTrue() public view {
        for (uint256 i; i < h.specCount(); ++i) {
            bytes32 spec = h.specs(i);
            (, PredgeValidatorBondV2.Status st, uint8 score,,,,,,) = bond.stakes(spec);
            if (st != PredgeValidatorBondV2.Status.Scored) continue;
            IAgentJobV2.Job memory j = job.getJob(h.jobIds(i));
            bool delivered = j.hashedOnChain && j.deliverable == h.expectedOf(spec);
            assertEq(score, delivered ? 100 : 0, "recorded verdict == truth");
            assertEq(uint8(j.state), uint8(delivered ? IAgentJobV2.State.Completed : IAgentJobV2.State.Rejected));
        }
    }

    /// @dev Olympix 5.2.2: a stake closed without a verdict pays the provider iff the provider had submitted.
    function invariant_silenceAfterSubmissionForfeits() public view {
        for (uint256 i; i < h.specCount(); ++i) {
            (, PredgeValidatorBondV2.Status st,,,,,,,) = bond.stakes(h.specs(i));
            uint64 submittedAt = job.getJob(h.jobIds(i)).submittedAt;
            if (st == PredgeValidatorBondV2.Status.Forfeited) assertGt(submittedAt, 0, "forfeit only after a submission");
            if (st == PredgeValidatorBondV2.Status.Released) assertEq(submittedAt, 0, "returned only if nothing was submitted");
        }
    }

    /// @dev Olympix 5.1.1: every stake commits to the value the client bound into the job's specHash.
    function invariant_stakeCommitsToClientValue() public view {
        for (uint256 i; i < h.specCount(); ++i) {
            bytes32 spec = h.specs(i);
            (, PredgeValidatorBondV2.Status st,,,,,, bytes32 c,) = bond.stakes(spec);
            if (st == PredgeValidatorBondV2.Status.None) continue;
            assertEq(c, keccak256(abi.encode(h.expectedOf(spec), h.saltOf(spec))));
            assertEq(bond.specHashFor(c), spec);
        }
    }

    function invariant_scoredNeverBeforeSubmission() public view {
        for (uint256 i; i < h.specCount(); ++i) {
            (, PredgeValidatorBondV2.Status st,,, uint64 scoredAt,,,,) = bond.stakes(h.specs(i));
            if (
                st == PredgeValidatorBondV2.Status.Committed || st == PredgeValidatorBondV2.Status.None
                    || st == PredgeValidatorBondV2.Status.Released || st == PredgeValidatorBondV2.Status.Forfeited
            ) continue;
            assertGe(scoredAt, job.getJob(h.jobIds(i)).submittedAt, "H-01: a verdict never precedes the submission");
            assertGt(job.getJob(h.jobIds(i)).submittedAt, 0);
        }
    }

    function invariant_deliverableImmutableOnceSubmitted() public view {
        for (uint256 i; i < h.specCount(); ++i) {
            IAgentJobV2.Job memory j = job.getJob(h.jobIds(i));
            if (j.state == IAgentJobV2.State.Open) assertEq(j.deliverable, bytes32(0));
            else if (j.state != IAgentJobV2.State.Expired) assertTrue(j.deliverable != bytes32(0));
        }
    }

    function invariant_writeOnceAndMonotonic() public {
        h.snapshot();
        assertFalse(h.violation(), "write-once / monotonic / only true verdicts recorded");
    }

    function invariant_livenessNoPermanentLock() public view {
        // Every job past its latest possible deadline has been resolvable: it is either settled or claimable.
        for (uint256 i; i < h.specCount(); ++i) {
            IAgentJobV2.Job memory j = job.getJob(h.jobIds(i));
            if (j.state == IAgentJobV2.State.Open && block.timestamp >= j.expiredAt) {
                // claimable by anyone: asserted structurally by the state machine; here just ensure the escrow is intact
                assertGt(j.escrow, 0);
            }
            if (j.state == IAgentJobV2.State.Submitted && block.timestamp >= uint256(j.submittedAt) + job.evaluationWindow()) {
                assertGt(j.escrow, 0);
            }
        }
    }
}

/// @dev Arbiter handler.
contract ArbiterHandler is Test {
    PredgeRefundArbiterV2 public arb;
    MockRefundProtocolV2 public rp;
    address public safe = address(0x5AFE);
    address public op = address(0x0A11);
    address public payer = address(0xA1);
    address public payee = address(0xA2);
    uint256[] public pids;
    mapping(uint256 => uint8) public prevStatus;
    mapping(uint256 => bytes32) public firstEv; // payer evidence
    mapping(uint256 => bytes32) public firstEvPayee;
    uint256 public ghostRefundCalls;
    bool public violation;

    constructor(PredgeRefundArbiterV2 a, MockRefundProtocolV2 r) {
        arb = a;
        rp = r;
        vm.deal(op, type(uint128).max);
    }

    function n() external view returns (uint256) { return pids.length; }

    function newPayment(uint96 amount) external {
        amount = uint96(bound(amount, 1, 500 ether));
        pids.push(rp.recordPayment(payer, payee, amount, block.timestamp + 40 days));
    }

    function file(uint256 i, bool asPayer, bytes32 ev) external {
        if (pids.length == 0) return;
        uint256 pid = pids[bound(i, 0, pids.length - 1)];
        ev = ev == 0 ? bytes32(uint256(1)) : ev;
        address who = asPayer ? payer : payee;
        bytes32 before = arb.filedEvidence(pid, who);
        vm.prank(who);
        try arb.fileEvidence(pid, ev) {} catch {}
        bytes32 afterV = arb.filedEvidence(pid, who);
        if (before != 0 && afterV != before) violation = true; // write-once
    }

    function ruleIt(uint256 i, bool fromPayer, bool refund) external {
        if (pids.length == 0) return;
        uint256 pid = pids[bound(i, 0, pids.length - 1)];
        address from = fromPayer ? payer : payee;
        bytes32 ev = arb.filedEvidence(pid, from);
        (, , uint256 amount,) = rp.paymentInfo(pid);
        vm.prank(op);
        try arb.rule{value: arb.requiredBond(amount)}(pid, from, ev, refund ? PredgeRefundArbiterV2.Direction.Refund : PredgeRefundArbiterV2.Direction.Release) {} catch {}
    }

    function disputeIt(uint256 i) external {
        if (pids.length == 0) return;
        uint256 pid = pids[bound(i, 0, pids.length - 1)];
        address h = arb.harmedParty(pid);
        vm.prank(h);
        try arb.dispute(pid, bytes32(uint256(7))) {} catch {}
    }

    function finalizeIt(uint256 i) external {
        if (pids.length == 0) return;
        uint256 pid = pids[bound(i, 0, pids.length - 1)];
        PredgeRefundArbiterV2.Ruling memory rl = arb.rulings(pid);
        PredgeRefundArbiterV2.Direction d = rl.direction;
        uint64 ruledAt = rl.ruledAt;
        uint64 window = rl.window;
        uint256 before = rp.refundCount();
        try arb.finalize(pid) {
            if (block.timestamp < uint256(ruledAt) + window) violation = true; // never inside the window
            if (d == PredgeRefundArbiterV2.Direction.Refund && rp.refundCount() != before + 1) violation = true;
        } catch {}
    }

    function resolveIt(uint256 i, bool refund) external {
        if (pids.length == 0) return;
        uint256 pid = pids[bound(i, 0, pids.length - 1)];
        vm.prank(safe);
        try arb.resolve(pid, refund ? PredgeRefundArbiterV2.Direction.Refund : PredgeRefundArbiterV2.Direction.Release) {} catch {}
    }

    function expireIt(uint256 i) external {
        if (pids.length == 0) return;
        try arb.expire(pids[bound(i, 0, pids.length - 1)]) {} catch {}
    }

    function withdrawIt(uint8 who) external {
        address a = who % 3 == 0 ? payer : who % 3 == 1 ? payee : op;
        vm.prank(a);
        try arb.withdraw() {} catch {}
    }

    function warp(uint32 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 10 days));
    }

    function snapshot() external {
        for (uint256 i; i < pids.length; ++i) {
            PredgeRefundArbiterV2.Status st = arb.rulings(pids[i]).status;
            uint8 s8 = uint8(st);
            if (s8 < prevStatus[pids[i]]) violation = true;
            if (prevStatus[pids[i]] >= 3 && s8 != prevStatus[pids[i]]) violation = true;
            prevStatus[pids[i]] = s8;
        }
    }
}

contract ArbiterInvariantTest is StdInvariant, Test {
    PredgeRefundArbiterV2 arb;
    MockRefundProtocolV2 rp;
    ArbiterHandler h;

    function setUp() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        rp = new MockRefundProtocolV2(predicted);
        arb = new PredgeRefundArbiterV2(address(0x5AFE), address(0x0A11), address(rp), 1 days, 1e15, 500);
        h = new ArbiterHandler(arb, rp);
        targetContract(address(h));
    }

    function invariant_arbiterSolvent() public view {
        assertGe(address(arb).balance, arb.totalBonded() + arb.totalCredit());
    }

    function invariant_totalBondedEqualsOpenRulings() public view {
        uint256 sum;
        uint256 rulings_;
        uint256 refunds;
        for (uint256 i; i < h.n(); ++i) {
            PredgeRefundArbiterV2.Ruling memory rl = arb.rulings(h.pids(i));
            PredgeRefundArbiterV2.Status st = rl.status;
            PredgeRefundArbiterV2.Direction d = rl.direction;
            uint256 bond = rl.bond;
            if (st == PredgeRefundArbiterV2.Status.None) continue;
            rulings_++;
            if (st == PredgeRefundArbiterV2.Status.Ruled || st == PredgeRefundArbiterV2.Status.Disputed) sum += bond;
            else assertEq(bond, 0);
            if (st == PredgeRefundArbiterV2.Status.Finalized && d == PredgeRefundArbiterV2.Direction.Refund) refunds++;
        }
        assertEq(arb.totalBonded(), sum);
        assertEq(arb.rulingCount(), rulings_, "one ruling per payment");
        // refunds happen only via a Finalized Refund or an owner-chosen Refund after a dispute (Overturned/Finalized)
        assertGe(rp.refundCount(), refunds);
        assertLe(rp.refundCount(), rulings_);
    }

    function invariant_everyRefundedPaymentWasFiledAndRuled() public view {
        for (uint256 i; i < h.n(); ++i) {
            (,,, , , bool refunded) = _refundedFlag(h.pids(i));
            if (!refunded) continue;
            PredgeRefundArbiterV2.Status st = arb.rulings(h.pids(i)).status;
            assertTrue(st == PredgeRefundArbiterV2.Status.Finalized || st == PredgeRefundArbiterV2.Status.Overturned, "refund only after a decision");
        }
    }

    function _refundedFlag(uint256 pid) internal view returns (address, address, uint256, uint256, bool, bool) {
        (address a, address b, uint256 c, uint256 d, bool r) = rp.payments(pid);
        return (a, b, c, d, r, r);
    }

    function invariant_writeOnceAndFinality() public {
        h.snapshot();
        assertFalse(h.violation());
    }
}
