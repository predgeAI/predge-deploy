// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base, NoReceive} from "./Base.sol";
import {PredgeValidatorBondV2} from "../../contracts/v2/PredgeValidatorBondV2.sol";
import {IAgentJobV2} from "../../contracts/v2/interfaces/IAgentJobV2.sol";
import {PullCredit} from "../../contracts/v2/access/PullCredit.sol";
import {Owned2Step, Operated} from "../../contracts/v2/access/PredgeAccess.sol";

contract PredgeValidatorBondV2Test is Base {
    bytes32 internal EXPECTED; // sha256(GOOD), set in setUp (sha256 is not a compile-time constant)
    bytes32 internal constant SALT = keccak256("salt");
    bytes32 internal constant OTHER = keccak256("something else");

    event Committed(bytes32 indexed requestHash, uint256 indexed jobId, address indexed staker, bytes32 commitment, uint256 bond);
    event Scored(bytes32 indexed requestHash, uint256 indexed jobId, uint8 score, bytes32 expected, address staker, uint256 bond);
    event Released(bytes32 indexed requestHash, address indexed staker, uint256 bond);
    event Forfeited(bytes32 indexed requestHash, address indexed provider, uint256 bond);
    event ParamsUpdated(uint256 minBond, uint16 bondBps);

    function setUp() public {
        _deployJobAndBond();
        EXPECTED = _good();
    }

    // ---- construction / params (M-01, L-01) ----

    /// @dev `new` under `vm.expectRevert` ends the test early in forge; deploy through an external call instead.
    function mk(address o, address p, address j, uint256 m, uint16 b) external returns (address) {
        return address(new PredgeValidatorBondV2(o, p, j, m, b));
    }

    function test_constructor() public view {
        assertEq(bond.owner(), safe);
        assertEq(bond.operator(), op);
        assertEq(address(bond.job()), address(job));
        assertEq(bond.minBond(), MIN_BOND);
        assertEq(bond.bondBps(), BPS);
    }

    function test_constructor_reverts() public {
        vm.expectRevert(Owned2Step.ZeroAddress.selector);
        this.mk(address(0), op, address(job), MIN_BOND, BPS);
        vm.expectRevert(Owned2Step.ZeroAddress.selector);
        this.mk(safe, address(0), address(job), MIN_BOND, BPS);
        vm.expectRevert(Owned2Step.ZeroAddress.selector);
        this.mk(safe, op, address(0), MIN_BOND, BPS);
        vm.expectRevert(PredgeValidatorBondV2.BadParams.selector);
        this.mk(safe, op, address(job), 0, BPS);
        vm.expectRevert(PredgeValidatorBondV2.BadParams.selector);
        this.mk(safe, op, address(job), MIN_BOND, 10_001);
        this.mk(safe, op, address(job), 1, 10_000); // both bounds inclusive
    }

    function test_setParams_ownerOnlyAndBounded() public {
        vm.prank(op);
        vm.expectRevert(Owned2Step.NotOwner.selector);
        bond.setParams(1, 5000);
        vm.startPrank(safe);
        vm.expectRevert(PredgeValidatorBondV2.BadParams.selector);
        bond.setParams(0, 5000);
        vm.expectRevert(PredgeValidatorBondV2.BadParams.selector);
        bond.setParams(1, 10_001);
        vm.expectEmit(false, false, false, true);
        emit ParamsUpdated(7, 5000);
        bond.setParams(7, 5000);
        vm.stopPrank();
        assertEq(bond.minBond(), 7);
        assertEq(bond.bondBps(), 5000);
    }

    function test_paramChangeIsNotRetroactive() public {
        (uint256 id, bytes32 spec) = _newJob(10 ether, EXPECTED, SALT);
        _stake(spec, EXPECTED, SALT, id, 10 ether);
        vm.prank(safe);
        bond.setParams(MIN_BOND, 0); // owner drops the bps afterwards
        _deliver(id, GOOD);
        _score(spec, 100, EXPECTED, SALT);
        assertEq(bond.credit(op), 10 ether, "the staker gets back exactly what it posted");
    }

    function test_requiredBond_isMaxOfFloorAndScaled() public {
        assertEq(bond.requiredBond(1), MIN_BOND);
        assertEq(bond.requiredBond(10 ether), 10 ether);
        vm.prank(safe);
        bond.setParams(MIN_BOND, 2500);
        assertEq(bond.requiredBond(10 ether), 2.5 ether);
        assertEq(bond.requiredBond(3), MIN_BOND);
        vm.prank(safe);
        bond.setParams(1, 3333);
        assertEq(bond.requiredBond(10), 4, "rounds up: ceil(3.333)");
    }

    // ---- stakeAndCommit ----

    function test_stake_ok() public {
        (uint256 id, bytes32 spec) = _newJob(2 ether, EXPECTED, SALT);
        vm.expectEmit(true, true, true, true);
        emit Committed(spec, id, op, _commitment(EXPECTED, SALT), 2 ether);
        _stake(spec, EXPECTED, SALT, id, 2 ether);
        (address staker, PredgeValidatorBondV2.Status st,, uint64 stakedAt,, uint256 jobId, uint256 b, bytes32 c, bytes32 e) = bond.stakes(spec);
        assertEq(staker, op);
        assertEq(uint8(st), uint8(PredgeValidatorBondV2.Status.Committed));
        assertEq(stakedAt, block.timestamp);
        assertEq(jobId, id);
        assertEq(b, 2 ether);
        assertEq(c, _commitment(EXPECTED, SALT));
        assertEq(e, bytes32(0), "expected is hidden until the reveal");
        assertEq(bond.totalBonded(), 2 ether);
    }

    function test_stake_reverts() public {
        (uint256 id, bytes32 spec) = _newJob(2 ether, EXPECTED, SALT);
        bytes32 c = _commitment(EXPECTED, SALT);
        vm.prank(stranger);
        vm.expectRevert(Operated.NotOperator.selector);
        bond.stakeAndCommit{value: 2 ether}(spec, c, id);

        vm.startPrank(op);
        vm.expectRevert(PredgeValidatorBondV2.ZeroHash.selector);
        bond.stakeAndCommit{value: 2 ether}(bytes32(0), c, id);
        vm.expectRevert(PredgeValidatorBondV2.ZeroHash.selector);
        bond.stakeAndCommit{value: 2 ether}(spec, bytes32(0), id);
        vm.expectRevert(abi.encodeWithSelector(PredgeValidatorBondV2.BondTooSmall.selector, 2 ether));
        bond.stakeAndCommit{value: 2 ether - 1}(spec, c, id);
        vm.expectRevert(PredgeValidatorBondV2.NotOpen.selector);
        bond.stakeAndCommit{value: 2 ether}(spec, c, 999); // unknown job
        // Olympix 5.1.1: the operator cannot commit to a value the client did not fix in the specHash
        vm.expectRevert(PredgeValidatorBondV2.CommitmentNotBound.selector);
        bond.stakeAndCommit{value: 2 ether}(spec, _commitment(OTHER, SALT), id);
        vm.expectRevert(PredgeValidatorBondV2.CommitmentNotBound.selector);
        bond.stakeAndCommit{value: 2 ether}(keccak256("other spec"), c, id);
        // a correctly derived hash for ANOTHER commitment is still not this job's spec
        bytes32 otherSpec = _bspec(OTHER, SALT);
        vm.expectRevert(PredgeValidatorBondV2.JobNotBound.selector);
        bond.stakeAndCommit{value: 2 ether}(otherSpec, _commitment(OTHER, SALT), id);
        bond.stakeAndCommit{value: 2 ether}(spec, c, id);
        vm.expectRevert(PredgeValidatorBondV2.AlreadyCommitted.selector);
        bond.stakeAndCommit{value: 2 ether}(spec, c, id);
        vm.stopPrank();
    }

    function test_stake_wrongEvaluatorNotBound() public {
        bytes32 spec = _bspec(EXPECTED, SALT);
        vm.prank(client);
        uint256 id = job.createJob{value: 1 ether}(provider, stranger, spec, uint64(block.timestamp + 1 days));
        vm.prank(op);
        vm.expectRevert(PredgeValidatorBondV2.JobNotBound.selector);
        bond.stakeAndCommit{value: 1 ether}(spec, _commitment(EXPECTED, SALT), id);
    }

    function test_stake_operatorCannotBeProvider() public {
        bytes32 spec = _bspec(EXPECTED, SALT);
        vm.prank(client);
        uint256 id = job.createJob{value: 1 ether}(op, address(bond), spec, uint64(block.timestamp + 1 days));
        vm.prank(op);
        vm.expectRevert(PredgeValidatorBondV2.ProviderIsOperator.selector);
        bond.stakeAndCommit{value: 1 ether}(spec, _commitment(EXPECTED, SALT), id);
    }

    /// @dev Olympix 5.2.3: the operator cannot be the client of a job it stakes on or scores.
    function test_stake_operatorCannotBeClient() public {
        bytes32 spec = _bspec(EXPECTED, SALT);
        vm.prank(op);
        uint256 id = job.createJob{value: 1 ether}(provider, address(bond), spec, uint64(block.timestamp + 1 days));
        vm.prank(op);
        vm.expectRevert(PredgeValidatorBondV2.ClientIsOperator.selector);
        bond.stakeAndCommit{value: 1 ether}(spec, _commitment(EXPECTED, SALT), id);
    }

    function test_score_rotatedOperatorCannotBeClient() public {
        address newOp = makeAddr("newOp");
        vm.deal(newOp, 10 ether);
        bytes32 spec = _bspec(EXPECTED, SALT);
        vm.prank(newOp);
        uint256 id = job.createJob{value: 1 ether}(provider, address(bond), spec, uint64(block.timestamp + 1 days));
        _stake(spec, EXPECTED, SALT, id, 1 ether); // old operator stakes: fine, it is not the client
        _deliver(id, GOOD);
        vm.prank(safe);
        bond.setOperator(newOp); // the owner rotates to the job's client
        vm.prank(newOp);
        vm.expectRevert(PredgeValidatorBondV2.ClientIsOperator.selector);
        bond.recordScore(spec, 100, EXPECTED, SALT, 0);
    }

    function test_stake_notOpenOnceSubmittedOrLapsed() public {
        (uint256 id, bytes32 spec) = _newJob(1 ether, EXPECTED, SALT);
        _submit(id, OTHER);
        vm.prank(op);
        vm.expectRevert(PredgeValidatorBondV2.NotOpen.selector);
        bond.stakeAndCommit{value: 1 ether}(spec, _commitment(EXPECTED, SALT), id);

        bytes32 salt2 = keccak256("salt2");
        (uint256 id2, bytes32 spec2) = _newJob(1 ether, EXPECTED, salt2);
        vm.warp(block.timestamp + 7 days);
        vm.prank(op);
        vm.expectRevert(PredgeValidatorBondV2.NotOpen.selector);
        bond.stakeAndCommit{value: 1 ether}(spec2, _commitment(EXPECTED, salt2), id2);
    }

    // ---- recordScore ----

    function test_score_pass_movesTheMoneyAndReturnsTheBond() public {
        (uint256 id, bytes32 spec) = _newJob(4 ether, EXPECTED, SALT);
        _stake(spec, EXPECTED, SALT, id, 4 ether);
        _deliver(id, GOOD);
        assertEq(bond.verdictFor(id, EXPECTED), 100);
        vm.expectEmit(true, true, false, true);
        emit Scored(spec, id, 100, EXPECTED, op, 4 ether);
        _score(spec, 100, EXPECTED, SALT);
        assertEq(uint8(job.getJob(id).state), uint8(IAgentJobV2.State.Completed));
        assertEq(job.credit(provider), 4 ether);
        assertEq(job.getJob(id).reason, keccak256("reason"));
        (, PredgeValidatorBondV2.Status st, uint8 sc,, uint64 scoredAt,, uint256 left,, bytes32 revealed) = bond.stakes(spec);
        assertEq(uint8(st), uint8(PredgeValidatorBondV2.Status.Scored));
        assertEq(sc, 100);
        assertEq(revealed, EXPECTED);
        assertEq(left, 0, "a scored stake holds no bond");
        assertEq(scoredAt, block.timestamp);
        assertGe(scoredAt, job.getJob(id).submittedAt, "the verdict never precedes the submission");
        assertEq(bond.credit(op), 4 ether, "bond credited back to the staker with the verdict");
        assertEq(bond.totalBonded(), 0);
    }

    function test_score_fail_refundsClient() public {
        (uint256 id, bytes32 spec) = _newJob(4 ether, EXPECTED, SALT);
        _stake(spec, EXPECTED, SALT, id, 4 ether);
        _submit(id, OTHER);
        assertEq(bond.verdictFor(id, EXPECTED), 0);
        _score(spec, 0, EXPECTED, SALT);
        assertEq(uint8(job.getJob(id).state), uint8(IAgentJobV2.State.Rejected));
        assertEq(job.credit(client), 4 ether);
        assertEq(bond.credit(op), 4 ether);
    }

    function test_score_reverts() public {
        (uint256 id, bytes32 spec) = _newJob(1 ether, EXPECTED, SALT);
        vm.startPrank(op);
        vm.expectRevert(PredgeValidatorBondV2.BadScore.selector);
        bond.recordScore(spec, 50, EXPECTED, SALT, 0);
        vm.expectRevert(PredgeValidatorBondV2.BadScore.selector);
        bond.recordScore(spec, 1, EXPECTED, SALT, 0);
        vm.expectRevert(PredgeValidatorBondV2.NotCommitted.selector);
        bond.recordScore(spec, 100, EXPECTED, SALT, 0);
        bond.stakeAndCommit{value: 1 ether}(spec, _commitment(EXPECTED, SALT), id);
        vm.expectRevert(PredgeValidatorBondV2.BadReveal.selector);
        bond.recordScore(spec, 100, OTHER, SALT, 0);
        vm.expectRevert(PredgeValidatorBondV2.BadReveal.selector);
        bond.recordScore(spec, 100, EXPECTED, OTHER, 0);
        vm.expectRevert(PredgeValidatorBondV2.NotSubmitted.selector);
        bond.recordScore(spec, 100, EXPECTED, SALT, 0);
        vm.stopPrank();
        _deliver(id, GOOD);
        vm.prank(stranger);
        vm.expectRevert(Operated.NotOperator.selector);
        bond.recordScore(spec, 100, EXPECTED, SALT, 0);
        _score(spec, 100, EXPECTED, SALT);
        vm.prank(op);
        vm.expectRevert(PredgeValidatorBondV2.BadStatus.selector);
        bond.recordScore(spec, 100, EXPECTED, SALT, 0);
    }

    function test_score_afterEvaluationWindowRevertsAtTheJob() public {
        (uint256 id, bytes32 spec) = _newJob(1 ether, EXPECTED, SALT);
        _stake(spec, EXPECTED, SALT, id, 1 ether);
        _deliver(id, GOOD);
        vm.warp(block.timestamp + EVAL_WINDOW);
        vm.prank(op);
        vm.expectRevert(); // job.complete -> PastDeadline: a verdict after the deadline is impossible
        bond.recordScore(spec, 100, EXPECTED, SALT, 0);
    }

    // ---- option (a): a false verdict cannot be recorded ----

    function _expectContradiction(bytes32 spec, uint8 score, bytes32 salt) internal {
        vm.prank(op);
        vm.expectRevert(PredgeValidatorBondV2.VerdictContradictsEvidence.selector);
        bond.recordScore(spec, score, EXPECTED, salt, 0);
    }

    function test_falsePass_wrongBytes_reverts() public {
        (uint256 id, bytes32 spec) = _newJob(1 ether, EXPECTED, SALT);
        _stake(spec, EXPECTED, SALT, id, 1 ether);
        _deliver(id, "not the output");
        _expectContradiction(spec, 100, SALT);
        _score(spec, 0, EXPECTED, SALT); // the true verdict goes through
        assertEq(job.credit(client), 1 ether);
    }

    /// @dev The provider knows `expected` (e.g. leaked by the client) and claims it without bytes: still not a delivery.
    function test_falsePass_claimedHashWithoutBytes_reverts() public {
        (uint256 id, bytes32 spec) = _newJob(1 ether, EXPECTED, SALT);
        _stake(spec, EXPECTED, SALT, id, 1 ether);
        _submit(id, EXPECTED);
        assertEq(bond.verdictFor(id, EXPECTED), 0);
        _expectContradiction(spec, 100, SALT);
        _score(spec, 0, EXPECTED, SALT);
        assertEq(job.credit(provider), 0);
    }

    function test_falseFail_correctBytes_reverts() public {
        (uint256 id, bytes32 spec) = _newJob(1 ether, EXPECTED, SALT);
        _stake(spec, EXPECTED, SALT, id, 1 ether);
        _deliver(id, GOOD);
        _expectContradiction(spec, 0, SALT);
        _score(spec, 100, EXPECTED, SALT);
        assertEq(job.credit(provider), 1 ether);
    }

    /// @dev bondBps = 0 (the shipped value) and the smallest floor: the false pass is still impossible (Olympix 5.1.2).
    function test_falsePass_impossibleAtZeroBps() public {
        vm.prank(safe);
        bond.setParams(1, 0);
        (uint256 id, bytes32 spec) = _newJob(100 ether, EXPECTED, SALT);
        _stake(spec, EXPECTED, SALT, id, 1);
        _deliver(id, "colluding provider, wrong output");
        _expectContradiction(spec, 100, SALT);
        assertEq(uint8(job.getJob(id).state), uint8(IAgentJobV2.State.Submitted));
        assertEq(job.credit(provider), 0);
    }

    // ---- release ----

    function test_release_whenJobExpiredWithoutVerdict() public {
        (uint256 id, bytes32 spec) = _newJob(2 ether, EXPECTED, SALT);
        _stake(spec, EXPECTED, SALT, id, 2 ether);
        vm.expectRevert(PredgeValidatorBondV2.JobNotExpired.selector);
        bond.release(spec);
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(PredgeValidatorBondV2.JobNotExpired.selector); // lapsed but not yet claimed
        bond.release(spec);
        job.claimRefund(id);
        address newOp = makeAddr("newOp");
        vm.prank(safe);
        bond.setOperator(newOp);
        vm.expectEmit(true, true, false, true);
        emit Released(spec, op, 2 ether);
        vm.prank(newOp); // the new key triggers it, the OLD staker is credited (L-04)
        bond.release(spec);
        assertEq(bond.credit(op), 2 ether);
        assertEq(bond.credit(newOp), 0);
        (, PredgeValidatorBondV2.Status st,,,,, uint256 left,,) = bond.stakes(spec);
        assertEq(uint8(st), uint8(PredgeValidatorBondV2.Status.Released));
        assertEq(left, 0);
        vm.expectRevert(PredgeValidatorBondV2.BadStatus.selector);
        bond.release(spec);
    }

    function test_release_afterSilentEvaluationWindow() public {
        (uint256 id, bytes32 spec) = _newJob(2 ether, EXPECTED, SALT);
        _stake(spec, EXPECTED, SALT, id, 2 ether);
        _deliver(id, GOOD);
        vm.warp(block.timestamp + EVAL_WINDOW);
        job.claimRefund(id);
        vm.expectEmit(true, true, false, true);
        emit Forfeited(spec, provider, 2 ether);
        bond.release(spec);
        // Olympix 5.2.2: silence on delivered work forfeits the bond to the provider
        assertEq(bond.credit(op), 0);
        assertEq(bond.credit(provider), 2 ether);
        assertEq(bond.totalBonded(), 0);
        (, PredgeValidatorBondV2.Status st,,,,, uint256 left,,) = bond.stakes(spec);
        assertEq(uint8(st), uint8(PredgeValidatorBondV2.Status.Forfeited));
        assertEq(left, 0);
        assertEq(job.credit(client), 2 ether, "documented timeout policy: the escrow still goes to the client");
        vm.expectRevert(PredgeValidatorBondV2.BadStatus.selector);
        bond.release(spec);
    }

    function test_release_reverts() public {
        vm.expectRevert(PredgeValidatorBondV2.NotCommitted.selector);
        bond.release(keccak256("none"));
        (uint256 id, bytes32 spec) = _newJob(1 ether, EXPECTED, SALT);
        _stake(spec, EXPECTED, SALT, id, 1 ether);
        _deliver(id, GOOD);
        _score(spec, 100, EXPECTED, SALT);
        vm.expectRevert(PredgeValidatorBondV2.BadStatus.selector);
        bond.release(spec);
    }

    // ---- pull payments ----

    function test_payoutToRevertingProviderDoesNotBlock() public {
        // The forfeit beneficiary cannot receive value: the bond still lands as credit and can be redirected.
        NoReceive bad = new NoReceive();
        bytes32 spec = _bspec(EXPECTED, SALT);
        vm.prank(client);
        uint256 id = job.createJob{value: 1 ether}(address(bad), address(bond), spec, uint64(block.timestamp + 1 days));
        _stake(spec, EXPECTED, SALT, id, 1 ether);
        vm.prank(address(bad));
        job.submit(id, OTHER, "");
        vm.warp(block.timestamp + EVAL_WINDOW);
        job.claimRefund(id);
        bond.release(spec);
        assertEq(bond.credit(address(bad)), 1 ether);
        vm.expectRevert(PullCredit.TransferFailed.selector);
        bad.callWithdraw(address(bond));
        vm.prank(address(bad));
        bond.withdrawTo(payable(stranger));
        assertEq(bond.credit(address(bad)), 0);
        assertEq(stranger.balance, 10 ether + 1 ether);
    }

    // ---- fuzz ----

    /// @dev Whatever the provider submits and whatever the operator claims, recordScore accepts the verdict
    ///      iff it equals the truth ("delivered" = bytes hashed on-chain whose hash equals the client's
    ///      expected value). A false verdict always reverts and moves nothing.
    function testFuzz_noFalseVerdictCanBeRecorded(bytes32 salt, bool viaBytes, bool matching, bool claimPass, bytes32 junk, uint96 escrow)
        public
    {
        vm.assume(junk != bytes32(0) && junk != EXPECTED);
        escrow = uint96(bound(escrow, 1, 100 ether));
        (uint256 id, bytes32 spec) = _newJob(escrow, EXPECTED, salt);
        uint256 b = bond.requiredBond(escrow);
        _stake(spec, EXPECTED, salt, id, b);
        if (viaBytes) _deliver(id, matching ? GOOD : abi.encode(junk));
        else _submit(id, matching ? EXPECTED : junk); // a claimed hash, even the right one, is not a delivery
        bool truth = viaBytes && matching;
        assertEq(bond.verdictFor(id, EXPECTED), truth ? 100 : 0);
        uint8 claimed = claimPass ? 100 : 0;
        if (claimPass != truth) {
            _expectContradiction(spec, claimed, salt);
            assertEq(uint8(job.getJob(id).state), uint8(IAgentJobV2.State.Submitted), "a false verdict moves nothing");
            assertEq(bond.totalBonded(), b);
        } else {
            _score(spec, claimed, EXPECTED, salt);
            assertEq(uint8(job.getJob(id).state), uint8(truth ? IAgentJobV2.State.Completed : IAgentJobV2.State.Rejected));
            assertEq(job.credit(truth ? provider : client), escrow);
            assertEq(bond.credit(op), b);
        }
    }

    /// @dev Any output bytes at all: a pass is recorded iff sha256(bytes) == expected, a fail iff not.
    function testFuzz_passIffOnChainHashMatches(bytes calldata out, bool claimPass) public {
        vm.assume(out.length != 0);
        (uint256 id, bytes32 spec) = _newJob(1 ether, EXPECTED, SALT);
        _stake(spec, EXPECTED, SALT, id, 1 ether);
        _deliver(id, out);
        bool truth = sha256(out) == EXPECTED;
        if (claimPass != truth) _expectContradiction(spec, claimPass ? 100 : 0, SALT);
        else _score(spec, claimPass ? 100 : 0, EXPECTED, SALT);
    }
}
