// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PredgeValidatorBond} from "../../../contracts/PredgeValidatorBond.sol";
import {AgentJob} from "../../../contracts/AgentJob.sol";
import {MockJob} from "../mocks/MockJob.sol";
import {ToggleReceiver, Reenterer} from "../utils/Actors.sol";

contract PredgeValidatorBondTest is Test {
    PredgeValidatorBond bond;
    AgentJob job;
    address owner = makeAddr("owner");
    address val = makeAddr("validator");
    address val2 = makeAddr("validator2");
    address client = makeAddr("client");
    address provider = makeAddr("provider");
    address anyone = makeAddr("anyone");
    uint64 constant WINDOW = 1 days;
    bytes32 constant REQ = keccak256("request");
    bytes32 constant GOOD = keccak256("expected deliverable");
    bytes32 constant BAD = keccak256("garbage");
    uint96 constant B = 1 ether;
    uint256 jobId;

    event Committed(bytes32 indexed requestHash, bytes32 expected, uint96 bond, uint64 stakedAt);
    event Scored(bytes32 indexed requestHash, uint8 score, uint64 scoredAt);
    event Slashed(bytes32 indexed requestHash, address indexed challenger, uint96 bond, uint8 recordedScore, bytes32 deliveredHash);
    event Reclaimed(bytes32 indexed requestHash, uint96 bond);
    event ValidatorUpdated(address indexed previousValidator, address indexed newValidator);

    function setUp() public {
        vm.warp(1_700_000_000);
        job = new AgentJob();
        vm.prank(owner);
        bond = new PredgeValidatorBond(val, address(job), WINDOW);
        vm.deal(val, 1_000 ether);
        vm.deal(client, 1_000 ether);
        jobId = _newJob(REQ, val);
    }

    function _newJob(bytes32 spec, address evaluator) internal returns (uint256 id) {
        vm.prank(client);
        id = job.createJob{value: 1 ether}(provider, evaluator, spec);
    }

    function _stake() internal {
        vm.prank(val);
        bond.stakeAndCommit{value: B}(REQ, GOOD, jobId);
    }

    function _submit(bytes32 d) internal {
        vm.prank(provider);
        job.submit(jobId, d, "");
    }

    function _score(uint8 s) internal {
        vm.prank(val);
        bond.recordScore(REQ, s);
    }

    function _stakeSubmitScore(bytes32 d, uint8 s) internal {
        _stake();
        _submit(d);
        _score(s);
    }

    function _stake_() internal view returns (PredgeValidatorBond.Stake memory st) {
        (st.expected, st.bond, st.stakedAt, st.score, st.scored, st.closed, st.jobId, st.scoredAt) = bond.stakes(REQ);
    }

    // ───────────── constructor / admin ─────────────
    function test_constructor() public view {
        assertEq(bond.owner(), owner);
        assertEq(bond.validator(), val);
        assertEq(address(bond.job()), address(job));
        assertEq(bond.disputeWindow(), WINDOW);
        assertEq(bond.totalBonded(), 0);
    }

    function test_constructor_revert_zeroValidator() public {
        vm.expectRevert(PredgeValidatorBond.ZeroAddress.selector);
        new PredgeValidatorBond(address(0), address(job), WINDOW);
    }

    function test_constructor_revert_zeroJob() public {
        vm.expectRevert(PredgeValidatorBond.ZeroAddress.selector);
        new PredgeValidatorBond(val, address(0), WINDOW);
    }

    function test_setValidator() public {
        vm.expectEmit(true, true, false, false, address(bond));
        emit ValidatorUpdated(val, val2);
        vm.prank(owner);
        bond.setValidator(val2);
        assertEq(bond.validator(), val2);
    }

    function test_setValidator_revert_notOwner() public {
        vm.prank(val);
        vm.expectRevert(PredgeValidatorBond.NotOwner.selector);
        bond.setValidator(val2);
    }

    function test_setValidator_revert_zero() public {
        vm.prank(owner);
        vm.expectRevert(PredgeValidatorBond.ZeroAddress.selector);
        bond.setValidator(address(0));
    }

    // ───────────── stakeAndCommit ─────────────
    function test_stake_records() public {
        vm.expectEmit(true, false, false, true, address(bond));
        emit Committed(REQ, GOOD, B, uint64(block.timestamp));
        _stake();
        PredgeValidatorBond.Stake memory s = _stake_();
        assertEq(s.expected, GOOD);
        assertEq(s.bond, B);
        assertEq(s.stakedAt, block.timestamp);
        assertEq(s.jobId, jobId);
        assertFalse(s.scored);
        assertFalse(s.closed);
        assertEq(bond.totalBonded(), B);
        assertEq(address(bond).balance, B);
    }

    function test_stake_revert_notValidator() public {
        vm.deal(anyone, 1 ether);
        vm.prank(anyone);
        vm.expectRevert(PredgeValidatorBond.NotValidator.selector);
        bond.stakeAndCommit{value: B}(REQ, GOOD, jobId);
    }

    function test_stake_revert_zeroExpected() public {
        vm.prank(val);
        vm.expectRevert(PredgeValidatorBond.ZeroHash.selector);
        bond.stakeAndCommit{value: B}(REQ, bytes32(0), jobId);
    }

    function test_stake_revert_zeroBond() public {
        vm.prank(val);
        vm.expectRevert(PredgeValidatorBond.ZeroBond.selector);
        bond.stakeAndCommit(REQ, GOOD, jobId);
    }

    function test_stake_revert_alreadyCommitted() public {
        _stake();
        vm.prank(val);
        vm.expectRevert(PredgeValidatorBond.AlreadyCommitted.selector);
        bond.stakeAndCommit{value: B}(REQ, GOOD, jobId);
    }

    function test_stake_revert_specMismatch() public {
        uint256 other = _newJob(keccak256("other spec"), val);
        vm.prank(val);
        vm.expectRevert(PredgeValidatorBond.JobNotBound.selector);
        bond.stakeAndCommit{value: B}(REQ, GOOD, other);
    }

    function test_stake_revert_evaluatorMismatch() public {
        uint256 other = _newJob(REQ, anyone);
        vm.prank(val);
        vm.expectRevert(PredgeValidatorBond.JobNotBound.selector);
        bond.stakeAndCommit{value: B}(REQ, GOOD, other);
    }

    function test_stake_revert_nonexistentJob() public {
        vm.prank(val);
        vm.expectRevert(PredgeValidatorBond.JobNotBound.selector);
        bond.stakeAndCommit{value: B}(REQ, GOOD, 999);
    }

    function test_stake_revert_providerIsValidator() public {
        vm.prank(client);
        uint256 id = job.createJob{value: 1}(val, val, keccak256("self"));
        vm.prank(val);
        vm.expectRevert(PredgeValidatorBond.ProviderIsValidator.selector);
        bond.stakeAndCommit{value: B}(keccak256("self"), GOOD, id);
    }

    /// BUG (VB-01): the contract's own model is "commits the acceptance test BEFORE the work
    /// exists", but stakeAndCommit never checks the job state. A validator can wait until the
    /// provider has submitted, read the deliverable, and set `expected` = that deliverable with
    /// score 100: the verdict is then unslashable whatever was delivered, so the bond proves
    /// nothing about commit-before-outcome. Expected: stake must revert once the job is Submitted.
    function test_BUG_stake_allowedAfterDeliverableIsPublic() public {
        _submit(BAD); // provider delivers garbage; it is now on-chain
        vm.prank(val);
        vm.expectRevert(); // should revert: work already delivered
        bond.stakeAndCommit{value: B}(REQ, BAD, jobId);
    }

    /// Same as VB-01, end-to-end: the dishonest pass is unslashable and the bond comes back.
    function test_finding_postHocCommitMakesFalsePassUnslashable() public {
        _submit(BAD);
        vm.prank(val);
        bond.stakeAndCommit{value: B}(REQ, BAD, jobId);
        _score(100);
        assertFalse(bond.wouldSlash(REQ));
        vm.expectRevert(PredgeValidatorBond.VerdictHonest.selector);
        bond.challenge(REQ);
        vm.warp(block.timestamp + WINDOW);
        vm.prank(val);
        bond.reclaim(REQ);
    }

    /// BUG (VB-02): bond stored as uint96(msg.value) and totalBonded += uint96(msg.value):
    /// values >= 2^96 are truncated and the excess is locked forever.
    function test_BUG_stake_truncatesBondAbove2pow96() public {
        uint256 v = uint256(type(uint96).max) + 1 + B;
        vm.deal(val, v);
        vm.prank(val);
        bond.stakeAndCommit{value: v}(REQ, GOOD, jobId);
        assertEq(uint256(_stake_().bond), v, "bond truncated");
    }

    // ───────────── recordScore ─────────────
    function test_score_records() public {
        _stake();
        vm.warp(block.timestamp + 10);
        vm.expectEmit(true, false, false, true, address(bond));
        emit Scored(REQ, 100, uint64(block.timestamp));
        _score(100);
        PredgeValidatorBond.Stake memory s = _stake_();
        assertTrue(s.scored);
        assertEq(s.score, 100);
        assertEq(s.scoredAt, block.timestamp);
    }

    function test_score_zeroAllowed() public {
        _stake();
        _score(0);
        assertTrue(_stake_().scored);
    }

    function testFuzz_score_revert_badScore(uint8 s) public {
        vm.assume(s != 0 && s != 100);
        _stake();
        vm.prank(val);
        vm.expectRevert(PredgeValidatorBond.BadScore.selector);
        bond.recordScore(REQ, s);
    }

    function test_score_revert_notValidator() public {
        _stake();
        vm.prank(anyone);
        vm.expectRevert(PredgeValidatorBond.NotValidator.selector);
        bond.recordScore(REQ, 100);
    }

    function test_score_revert_notCommitted() public {
        vm.prank(val);
        vm.expectRevert(PredgeValidatorBond.NotCommitted.selector);
        bond.recordScore(REQ, 100);
    }

    function test_score_revert_alreadyScored() public {
        _stake();
        _score(100);
        vm.prank(val);
        vm.expectRevert(PredgeValidatorBond.AlreadyScored.selector);
        bond.recordScore(REQ, 0);
    }

    // ───────────── challenge ─────────────
    function test_challenge_revert_notCommitted() public {
        vm.expectRevert(PredgeValidatorBond.NotCommitted.selector);
        bond.challenge(REQ);
    }

    function test_challenge_revert_notScored() public {
        _stake();
        _submit(BAD);
        vm.expectRevert(PredgeValidatorBond.NotScored.selector);
        bond.challenge(REQ);
    }

    function test_challenge_revert_notSubmitted() public {
        _stake();
        _score(100);
        vm.expectRevert(PredgeValidatorBond.NotSubmitted.selector);
        bond.challenge(REQ);
    }

    function test_challenge_revert_honestPass() public {
        _stakeSubmitScore(GOOD, 100);
        vm.expectRevert(PredgeValidatorBond.VerdictHonest.selector);
        bond.challenge(REQ);
    }

    function test_challenge_revert_honestFail() public {
        _stakeSubmitScore(BAD, 0);
        vm.expectRevert(PredgeValidatorBond.VerdictHonest.selector);
        bond.challenge(REQ);
    }

    function test_challenge_slashesFalsePass() public {
        _stakeSubmitScore(BAD, 100);
        assertTrue(bond.wouldSlash(REQ));
        vm.expectEmit(true, true, false, true, address(bond));
        emit Slashed(REQ, anyone, B, 100, BAD);
        vm.prank(anyone);
        bond.challenge(REQ);
        assertEq(anyone.balance, B);
        assertEq(bond.totalBonded(), 0);
        assertEq(bond.slashCount(), 1);
        assertEq(address(bond).balance, 0);
        PredgeValidatorBond.Stake memory s = _stake_();
        assertTrue(s.closed);
        assertEq(s.bond, 0);
        assertFalse(bond.wouldSlash(REQ));
    }

    function test_challenge_slashesFalseFail() public {
        _stakeSubmitScore(GOOD, 0);
        vm.prank(anyone);
        bond.challenge(REQ);
        assertEq(anyone.balance, B);
    }

    function test_challenge_worksAfterCompleteAndReject() public {
        _stakeSubmitScore(BAD, 100);
        vm.prank(val);
        job.complete(jobId, keccak256("r"), ""); // state 3
        assertTrue(bond.wouldSlash(REQ));
        vm.prank(anyone);
        bond.challenge(REQ);
        assertEq(anyone.balance, B);
    }

    function test_challenge_revert_twice_noDoubleSlash() public {
        _stakeSubmitScore(BAD, 100);
        vm.prank(anyone);
        bond.challenge(REQ);
        vm.expectRevert(PredgeValidatorBond.Closed.selector);
        bond.challenge(REQ);
        assertEq(anyone.balance, B);
    }

    function test_challenge_revert_challengerCannotReceive() public {
        _stakeSubmitScore(BAD, 100);
        ToggleReceiver c = new ToggleReceiver();
        c.setAccept(false);
        vm.expectRevert(PredgeValidatorBond.TransferFailed.selector);
        c.exec(address(bond), 0, abi.encodeCall(PredgeValidatorBond.challenge, (REQ)));
        assertEq(bond.totalBonded(), B, "rolled back");
    }

    function test_challenge_reentrancyBlocked() public {
        _stakeSubmitScore(BAD, 100);
        Reenterer r = new Reenterer();
        r.arm(address(bond), abi.encodeCall(PredgeValidatorBond.challenge, (REQ)));
        r.exec(address(bond), 0, abi.encodeCall(PredgeValidatorBond.challenge, (REQ)));
        assertTrue(r.reentered());
        assertFalse(r.reentrySucceeded());
        assertEq(address(r).balance, B);
    }

    /// Note: there is no challenge deadline. A lie stays slashable after the window until the
    /// validator reclaims; that is a race the challenger can win. (Safe direction; informational.)
    function test_challenge_stillPossibleAfterWindowUntilReclaim() public {
        _stakeSubmitScore(BAD, 100);
        vm.warp(block.timestamp + WINDOW * 10);
        vm.prank(anyone);
        bond.challenge(REQ);
        vm.prank(val);
        vm.expectRevert(PredgeValidatorBond.Closed.selector);
        bond.reclaim(REQ);
    }

    // ───────────── reclaim ─────────────
    function test_reclaim_afterWindowFromScore() public {
        _stake();
        vm.warp(block.timestamp + WINDOW * 5); // long after stake
        _submit(GOOD);
        _score(100);
        vm.prank(val);
        vm.expectRevert(PredgeValidatorBond.WindowOpen.selector);
        bond.reclaim(REQ); // window runs from the score, not the stake (audit fix F1)
        vm.warp(block.timestamp + WINDOW - 1);
        vm.prank(val);
        vm.expectRevert(PredgeValidatorBond.WindowOpen.selector);
        bond.reclaim(REQ);
        vm.warp(block.timestamp + 1);
        uint256 before = val.balance;
        vm.expectEmit(true, false, false, true, address(bond));
        emit Reclaimed(REQ, B);
        vm.prank(val);
        bond.reclaim(REQ);
        assertEq(val.balance, before + B);
        assertEq(bond.totalBonded(), 0);
        assertTrue(_stake_().closed);
        vm.expectRevert(PredgeValidatorBond.Closed.selector);
        bond.challenge(REQ);
    }

    function test_reclaim_revert_notValidator() public {
        _stakeSubmitScore(GOOD, 100);
        vm.warp(block.timestamp + WINDOW);
        vm.prank(anyone);
        vm.expectRevert(PredgeValidatorBond.NotValidator.selector);
        bond.reclaim(REQ);
    }

    function test_reclaim_revert_notCommitted() public {
        vm.prank(val);
        vm.expectRevert(PredgeValidatorBond.NotCommitted.selector);
        bond.reclaim(REQ);
    }

    function test_reclaim_revert_notScored() public {
        _stake();
        vm.warp(block.timestamp + WINDOW * 2);
        vm.prank(val);
        vm.expectRevert(PredgeValidatorBond.NotScored.selector);
        bond.reclaim(REQ);
    }

    function test_reclaim_revert_closed() public {
        _stakeSubmitScore(GOOD, 100);
        vm.warp(block.timestamp + WINDOW);
        vm.startPrank(val);
        bond.reclaim(REQ);
        vm.expectRevert(PredgeValidatorBond.Closed.selector);
        bond.reclaim(REQ);
        vm.stopPrank();
    }

    function test_reclaim_revert_validatorCannotReceive() public {
        ToggleReceiver v = new ToggleReceiver();
        vm.deal(address(v), 10 ether);
        vm.prank(owner);
        bond.setValidator(address(v));
        uint256 id = _newJob(keccak256("t"), address(v));
        v.exec(address(bond), B, abi.encodeCall(PredgeValidatorBond.stakeAndCommit, (keccak256("t"), GOOD, id)));
        v.exec(address(bond), 0, abi.encodeCall(PredgeValidatorBond.recordScore, (keccak256("t"), 0)));
        vm.warp(block.timestamp + WINDOW);
        v.setAccept(false);
        vm.expectRevert(PredgeValidatorBond.TransferFailed.selector);
        v.exec(address(bond), 0, abi.encodeCall(PredgeValidatorBond.reclaim, (keccak256("t"))));
    }

    // ───────────── wouldSlash ─────────────
    function test_wouldSlash_branches() public {
        assertFalse(bond.wouldSlash(REQ), "no stake");
        _stake();
        assertFalse(bond.wouldSlash(REQ), "not scored");
        _score(100);
        assertFalse(bond.wouldSlash(REQ), "not submitted");
        _submit(GOOD);
        assertFalse(bond.wouldSlash(REQ), "honest pass");
    }

    function test_wouldSlash_scoreZeroBranches() public {
        _stakeSubmitScore(BAD, 0);
        assertFalse(bond.wouldSlash(REQ), "honest fail");
    }

    function test_wouldSlash_scoreZeroLie() public {
        _stakeSubmitScore(GOOD, 0);
        assertTrue(bond.wouldSlash(REQ));
    }

    // ───────────── MockJob-driven edge cases ─────────────
    function test_mockJob_stateBoundaries() public {
        MockJob mj = new MockJob();
        vm.prank(owner);
        PredgeValidatorBond b2 = new PredgeValidatorBond(val, address(mj), WINDOW);
        mj.set(1, provider, val, REQ, BAD, 0);
        vm.startPrank(val);
        b2.stakeAndCommit{value: B}(REQ, GOOD, 1);
        b2.recordScore(REQ, 100);
        vm.stopPrank();
        // state 0 and 1 -> nothing to compare yet
        assertFalse(b2.wouldSlash(REQ));
        vm.expectRevert(PredgeValidatorBond.NotSubmitted.selector);
        b2.challenge(REQ);
        mj.set(1, provider, val, REQ, BAD, 1);
        vm.expectRevert(PredgeValidatorBond.NotSubmitted.selector);
        b2.challenge(REQ);
        // state 2 is the first comparable state
        mj.set(1, provider, val, REQ, BAD, 2);
        assertTrue(b2.wouldSlash(REQ));
        // the job contract is trusted: a mutable job could flip the deliverable after the fact
        mj.set(1, provider, val, REQ, GOOD, 4);
        assertFalse(b2.wouldSlash(REQ));
    }

    /// Kills Gambit mutant VB#33 (`s.jobId = jobId` -> `s.jobId = 1`): a stake bound to a job
    /// other than #1 must read THAT job's deliverable on challenge.
    function test_stake_bindsTheGivenJobId() public {
        bytes32 req2 = keccak256("request 2");
        uint256 id2 = _newJob(req2, val);
        assertEq(id2, 2);
        _submit(GOOD); // job #1 delivers GOOD
        vm.prank(provider);
        job.submit(id2, BAD, ""); // job #2 delivers BAD
        vm.startPrank(val);
        bond.stakeAndCommit{value: B}(req2, GOOD, id2);
        bond.recordScore(req2, 100);
        vm.stopPrank();
        (, , , , , , uint256 bound_, ) = bond.stakes(req2);
        assertEq(bound_, id2);
        assertTrue(bond.wouldSlash(req2), "must compare against job #2, not job #1");
        vm.prank(anyone);
        bond.challenge(req2);
        assertEq(anyone.balance, B);
    }

    // ───────────── documented findings ─────────────

    /// VB-03 (design): recordScore does not require the job to be Submitted. If the validator
    /// scores before delivery and the provider never submits (or submits after reclaim), the
    /// bond comes back with no challenge ever possible.
    function test_finding_scoreBeforeDeliveryThenReclaim() public {
        _stake();
        _score(100);
        vm.warp(block.timestamp + WINDOW);
        vm.expectRevert(PredgeValidatorBond.NotSubmitted.selector);
        bond.challenge(REQ);
        vm.prank(val);
        bond.reclaim(REQ);
        _submit(BAD); // later delivery contradicts the verdict, but the bond is gone
        assertFalse(bond.wouldSlash(REQ));
    }

    /// VB-04 (operational): setValidator hands every open stake to the new key: it can score
    /// stakes the old key committed, and reclaim pays the CURRENT validator. ProviderIsValidator
    /// is only checked at stake time, so rotating to the job's provider re-opens the
    /// "writes both sides" hole the check was meant to close.
    function test_finding_rotationInheritsStakesAndBypassesProviderCheck() public {
        _stake();
        vm.prank(owner);
        bond.setValidator(provider);
        vm.prank(provider);
        bond.recordScore(REQ, 100);
        _submit(GOOD); // provider now writes both sides
        vm.warp(block.timestamp + WINDOW);
        uint256 before = provider.balance;
        vm.prank(provider);
        bond.reclaim(REQ);
        assertEq(provider.balance, before + B, "old validator's bond paid to new validator");
    }

    /// VB-05 (doc mismatch): NatSpec says the test is `sha256(deliverable) == expected`, but the
    /// code compares the bytes32 `deliverable` directly with `expected`; no sha256 is computed.
    function test_finding_comparisonIsRawEquality() public {
        _stake();
        _submit(sha256(abi.encodePacked(GOOD)));
        _score(100);
        assertTrue(bond.wouldSlash(REQ), "sha256(expected) is not accepted; raw equality only");
    }

    // ───────────── fuzz ─────────────
    function testFuzz_verdictSlashableIffLie(bytes32 expected, bytes32 delivered, bool pass) public {
        vm.assume(expected != bytes32(0));
        vm.prank(val);
        bond.stakeAndCommit{value: B}(REQ, expected, jobId);
        _submit(delivered);
        _score(pass ? 100 : 0);
        bool lie = pass ? delivered != expected : delivered == expected;
        assertEq(bond.wouldSlash(REQ), lie);
        vm.prank(anyone);
        if (lie) {
            bond.challenge(REQ);
            assertEq(anyone.balance, B);
        } else {
            vm.expectRevert(PredgeValidatorBond.VerdictHonest.selector);
            bond.challenge(REQ);
        }
    }

    function testFuzz_reclaimWindow(uint32 dt) public {
        _stakeSubmitScore(GOOD, 100);
        vm.warp(block.timestamp + dt);
        vm.prank(val);
        if (dt < WINDOW) {
            vm.expectRevert(PredgeValidatorBond.WindowOpen.selector);
            bond.reclaim(REQ);
        } else {
            bond.reclaim(REQ);
            assertEq(bond.totalBonded(), 0);
        }
    }

    function testFuzz_onlyValidator(address caller) public {
        vm.assume(caller != val);
        vm.deal(caller, 1 ether);
        vm.startPrank(caller);
        vm.expectRevert(PredgeValidatorBond.NotValidator.selector);
        bond.stakeAndCommit{value: 1}(REQ, GOOD, jobId);
        vm.expectRevert(PredgeValidatorBond.NotValidator.selector);
        bond.recordScore(REQ, 100);
        vm.expectRevert(PredgeValidatorBond.NotValidator.selector);
        bond.reclaim(REQ);
        vm.stopPrank();
    }

    function testFuzz_stakeBondAccounting(uint96 amt) public {
        amt = uint96(bound(amt, 1, 500 ether));
        vm.prank(val);
        bond.stakeAndCommit{value: amt}(REQ, GOOD, jobId);
        assertEq(bond.totalBonded(), amt);
        assertEq(address(bond).balance, amt);
    }
}
