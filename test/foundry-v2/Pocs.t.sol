// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "./Base.sol";
import {ArbiterBase} from "./PredgeRefundArbiterV2.t.sol";
import {PredgeValidatorBondV2} from "../../contracts/v2/PredgeValidatorBondV2.sol";
import {PredgeRefundArbiterV2} from "../../contracts/v2/PredgeRefundArbiterV2.sol";
import {IAgentJobV2} from "../../contracts/v2/interfaces/IAgentJobV2.sol";
import {AgentJob as AgentJobV1} from "../../contracts/AgentJob.sol";
import {PredgeValidatorBond as BondV1} from "../../contracts/PredgeValidatorBond.sol";
import {PredgeRefundArbiter as ArbiterV1} from "../../contracts/PredgeRefundArbiter.sol";
import {MockRefundProtocol as MockRPV1} from "../../contracts/MockRefundProtocol.sol";

/// @notice Proof-of-concept tests for the self-audit findings. Each finding has two tests: the exact
///         v1 attack sequence run against the v1 contracts (it SUCCEEDS there, which proves the PoC
///         is a real exploit) and the same sequence against v2 (it reverts or is harmless).
contract PocsBondTest is Base {
    bytes32 constant E = keccak256("expected");
    bytes32 constant SALT = keccak256("salt");
    bytes32 constant X = keccak256("not the expected thing");

    function setUp() public {
        _deployJobAndBond();
    }

    // ------------------------------------------------------------------ H-01

    /// @dev v1: score a verdict BEFORE the provider submits, wait out the window, reclaim, then let
    ///      the provider submit something that contradicts the verdict. The lie is provable but closed.
    function test_v1_H01_verdictBeforeSubmissionIsReclaimedUnchallengeable() public {
        AgentJobV1 j1 = new AgentJobV1();
        BondV1 b1 = new BondV1(op, address(j1), 1 days);
        bytes32 spec = keccak256("spec");
        vm.prank(client);
        uint256 id = j1.createJob{value: 1 ether}(provider, op, spec);
        vm.startPrank(op);
        b1.stakeAndCommit{value: 1 ether}(spec, E, id);
        b1.recordScore(spec, 100); // verdict recorded with NO deliverable in existence
        vm.warp(block.timestamp + 1 days);
        b1.reclaim(spec); // bond back, nothing was ever challengeable
        vm.stopPrank();
        vm.prank(provider);
        j1.submit(id, X, ""); // the deliverable now contradicts the verdict
        vm.expectRevert(BondV1.Closed.selector);
        b1.challenge(spec); // provably false, permanently closed
    }

    /// @dev v2: the same sequence cannot even start. Scoring needs a submission, so nothing can be
    ///      scored or reclaimed before the deliverable exists, and the window starts at the score.
    function test_v2_H01_verdictBeforeSubmissionReverts() public {
        (uint256 id, bytes32 spec) = _newJob(1, 1 ether);
        _stake(spec, E, SALT, id, 1 ether);
        vm.prank(op);
        vm.expectRevert(PredgeValidatorBondV2.NotSubmitted.selector);
        bond.recordScore(spec, 100, E, SALT, 0);
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(PredgeValidatorBondV2.NotScored.selector);
        bond.reclaim(spec); // nothing to reclaim without a verdict
        // The only exit is the job expiring with NO verdict ever given, which lies about nothing.
        vm.warp(block.timestamp + 7 days);
        job.claimRefund(id);
        bond.release(spec);
        assertEq(job.credit(client), 1 ether, "client got the escrow back");
    }

    /// @dev v2: a submission that lands after the score attempt is judged inside a full window.
    function test_v2_H01_windowStartsAtOrAfterSubmission() public {
        (uint256 id, bytes32 spec) = _newJob(1, 1 ether);
        _stake(spec, E, SALT, id, 1 ether);
        vm.warp(block.timestamp + 2 days);
        _submit(id, X);
        _score(spec, 100, E, SALT); // a lie
        (,,,, uint64 scoredAt,,,,,) = bond.stakes(spec);
        assertGe(scoredAt, job.getJob(id).submittedAt);
        vm.warp(block.timestamp + 1 days - 1);
        bond.challenge(spec); // still inside its own full window, however long ago the stake was made
        assertEq(bond.credit(client), 1 ether);
    }

    // ------------------------------------------------------------------ H-02

    /// @dev v1: `expected` is public from the moment of the stake. The provider submits it with no work;
    ///      an honest score of 0 is then slashable. (And committing after submission, as the v1 smoke test
    ///      does, lets the validator copy the deliverable.)
    function test_v1_H02_providerCopiesPublicExpectedAndHonestFailBecomesSlashable() public {
        AgentJobV1 j1 = new AgentJobV1();
        BondV1 b1 = new BondV1(op, address(j1), 1 days);
        bytes32 spec = keccak256("spec");
        vm.prank(client);
        uint256 id = j1.createJob{value: 1 ether}(provider, op, spec);
        vm.prank(op);
        b1.stakeAndCommit{value: 1 ether}(spec, E, id);
        (bytes32 leaked,,,,,,,) = b1.stakes(spec); // anyone can read it
        assertEq(leaked, E);
        vm.prank(provider);
        j1.submit(id, leaked, ""); // no work, just the copied answer
        vm.prank(op);
        b1.recordScore(spec, 0); // the validator's honest view: nothing was really produced
        assertTrue(b1.wouldSlash(spec), "an honest-by-intent verdict is now slashable");
        vm.prank(stranger);
        b1.challenge(spec); // and the bond is taken
    }

    /// @dev v2: the committed value is a hash, so there is nothing to copy.
    function test_v2_H02_expectedIsHiddenSoItCannotBeCopied() public {
        (uint256 id, bytes32 spec) = _newJob(1, 1 ether);
        _stake(spec, E, SALT, id, 1 ether);
        (,,,,,,,, bytes32 commitment, bytes32 expected) = bond.stakes(spec);
        assertEq(expected, bytes32(0));
        assertEq(commitment, keccak256(abi.encode(E, SALT)));
        // The best the provider can do with public data is submit the commitment itself.
        _submit(id, commitment);
        _score(spec, 0, E, SALT); // honest: the deliverable is not the expected hash
        assertFalse(bond.wouldSlash(spec));
        vm.expectRevert(PredgeValidatorBondV2.VerdictHonest.selector);
        bond.challenge(spec);
    }

    /// @dev v2: the operator cannot choose `expected` after seeing the deliverable.
    function test_v2_H02_cannotCommitAfterSubmission() public {
        (uint256 id, bytes32 spec) = _newJob(1, 1 ether);
        _submit(id, X);
        vm.prank(op);
        vm.expectRevert(PredgeValidatorBondV2.NotOpen.selector);
        bond.stakeAndCommit{value: 1 ether}(spec, keccak256(abi.encode(X, SALT)), id);
    }

    /// @dev v2: a reveal that does not match the commitment is rejected, so `expected` cannot be swapped.
    function test_v2_H02_cannotSwapExpectedAtReveal() public {
        (uint256 id, bytes32 spec) = _newJob(1, 1 ether);
        _stake(spec, E, SALT, id, 1 ether);
        _submit(id, X);
        vm.prank(op);
        vm.expectRevert(PredgeValidatorBondV2.BadReveal.selector);
        bond.recordScore(spec, 100, X, SALT, 0); // would make the false pass look honest
    }

    // ------------------------------------------------------------------ M-02 / M-04

    /// @dev M-02: the bond is paid to the harmed party; a self-challenge by the operator gains nothing.
    function test_v2_M02_selfChallengeIsNotProfitable() public {
        (uint256 id, bytes32 spec) = _newJob(1, 5 ether);
        _stake(spec, E, SALT, id, 5 ether);
        _submit(id, X);
        _score(spec, 100, E, SALT); // false pass, provider gets 5
        uint256 opBefore = op.balance;
        vm.prank(op);
        bond.challenge(spec);
        assertEq(bond.credit(op), 0);
        assertEq(op.balance, opBefore);
        assertEq(bond.credit(client), 5 ether, "the cheated client is made whole");
    }

    /// @dev M-04: the verdict IS the settlement; there is no way to record a verdict that does not move the job.
    function test_v2_M04_verdictMovesTheMoney() public {
        (uint256 id, bytes32 spec) = _newJob(1, 2 ether);
        _stake(spec, E, SALT, id, 2 ether);
        _submit(id, E);
        _score(spec, 100, E, SALT);
        assertEq(uint8(job.getJob(id).state), uint8(IAgentJobV2.State.Completed));
        // No other party can settle this job: the bond contract is the only evaluator.
        vm.prank(op);
        vm.expectRevert();
        job.reject(id, 0, "");
    }

    /// @dev A colluding operator and provider cannot profit from a false pass at the default 100% bond ratio.
    function testFuzz_collusionNeverProfitsAtFullBond(uint96 escrow) public {
        escrow = uint96(bound(escrow, 1, 100 ether));
        (uint256 id, bytes32 spec) = _newJob(9, escrow);
        uint256 b = bond.requiredBond(escrow);
        _stake(spec, E, SALT, id, b);
        _submit(id, X);
        _score(spec, 100, E, SALT);
        bond.challenge(spec);
        uint256 colludersGain = job.credit(provider); // the escrow they extracted
        uint256 colludersLoss = b; // the bond they lost to the client
        assertGe(colludersLoss, colludersGain);
        assertGe(bond.credit(client), escrow, "client is made whole");
    }
}

contract PocsArbiterTest is ArbiterBase {
    PredgeRefundArbiterV2.Direction constant REFUND = PredgeRefundArbiterV2.Direction.Refund;
    PredgeRefundArbiterV2.Direction constant RELEASE = PredgeRefundArbiterV2.Direction.Release;
    bytes32 constant EV = keccak256("fabricated evidence");

    function setUp() public {
        _deployArbiter();
    }

    /// @dev v1 (a): any key can file "evidence" for any payment id, and the operator can cite it.
    ///      (b) the refund executes inside rule(), before any window. (c) challenge can never succeed.
    function test_v1_H03_arbitraryRefundAtGasCostAndUnslashable() public {
        // arbiter v1 is deployed with owner = this contract; the mock needs the arbiter address.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        MockRPV1 rp1 = new MockRPV1(predicted);
        ArbiterV1 a1 = new ArbiterV1(address(rp1), op, 1 days, 1e15);
        assertEq(address(a1), predicted);
        uint256 victimPayment = 4242;
        vm.prank(stranger); // not a party to anything
        a1.fileEvidence(victimPayment, EV);
        vm.prank(op);
        a1.rule{value: 1e15}(victimPayment, stranger, EV, ArbiterV1.Direction.Refund);
        assertTrue(rp1.refunded(victimPayment), "refund executed immediately, on a stranger's say-so");
        assertFalse(a1.wouldSlash(victimPayment));
        vm.expectRevert();
        a1.challenge(victimPayment); // RulingHonest, always
        vm.warp(block.timestamp + 1 days);
        vm.prank(op);
        a1.reclaim(victimPayment); // bond returned: the whole thing cost gas
    }

    /// @dev v2 (a): a stranger cannot file evidence for someone else's payment, and cannot be cited.
    function test_v2_H03_evidenceBoundToPaymentParties() public {
        uint256 pid = _pay(1 ether);
        vm.prank(stranger);
        vm.expectRevert(PredgeRefundArbiterV2.NotAParty.selector);
        arb.fileEvidence(pid, EV);
        vm.prank(op);
        vm.expectRevert(PredgeRefundArbiterV2.NotAParty.selector);
        arb.rule{value: 1 ether}(pid, stranger, EV, REFUND);
        // and a payment id that does not exist cannot be ruled on at all
        vm.prank(op);
        vm.expectRevert(PredgeRefundArbiterV2.UnknownPayment.selector);
        arb.rule{value: 1 ether}(4242, stranger, EV, REFUND);
    }

    /// @dev v2 (b): nothing executes inside rule(); the refund only happens after the window.
    function test_v2_H03_noRefundInsideRule() public {
        uint256 pid = _pay(1 ether);
        _file(pid);
        _rule(pid, payer, EV_PAYER, REFUND, arb.requiredBond(1 ether));
        assertEq(rp.refundCount(), 0);
        vm.warp(block.timestamp + WINDOW - 1);
        vm.expectRevert(PredgeRefundArbiterV2.WindowOpen.selector);
        arb.finalize(pid);
        assertEq(rp.refundCount(), 0);
    }

    /// @dev v2 (c): a reachable challenge path. The harmed payee freezes a wrongful refund; the Safe
    ///      overturns; the refund never executes and the operator's bond goes to the payee.
    function test_v2_H03_wrongfulRefundIsStoppedAndSlashed() public {
        uint256 pid = _pay(10 ether);
        _file(pid);
        uint256 bondAmt = arb.requiredBond(10 ether);
        _rule(pid, payer, EV_PAYER, REFUND, bondAmt);
        vm.prank(payee);
        arb.dispute(pid, EV_COUNTER);
        vm.prank(safe);
        arb.resolve(pid, RELEASE);
        assertEq(rp.refundCount(), 0, "the wrongful refund never executed");
        assertEq(arb.credit(payee), bondAmt, "operator's bond paid to the harmed payee");
        assertEq(arb.credit(op), 0);
    }

    /// @dev v2: a refund cannot be forced inside the window by anyone, in any order of calls.
    function testFuzz_v2_refundOnlyAfterWindowOrOwnerDecision(uint32 dt) public {
        uint256 pid = _pay(1 ether);
        _file(pid);
        _rule(pid, payer, EV_PAYER, REFUND, arb.requiredBond(1 ether));
        dt = uint32(bound(dt, 0, WINDOW - 1));
        vm.warp(block.timestamp + dt);
        vm.expectRevert(PredgeRefundArbiterV2.WindowOpen.selector);
        arb.finalize(pid);
        vm.prank(op);
        vm.expectRevert();
        arb.expire(pid);
        assertEq(rp.refundCount(), 0);
    }
}
