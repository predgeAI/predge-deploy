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

    event Committed(bytes32 indexed requestHash, uint256 indexed jobId, address indexed staker, bytes32 commitment, uint256 bond, uint64 window);
    event Scored(bytes32 indexed requestHash, uint256 indexed jobId, uint8 score, bytes32 expected, uint64 scoredAt, uint64 windowEnd);
    event Slashed(bytes32 indexed requestHash, address indexed challenger, address indexed harmed, uint256 bond, uint8 recordedScore, bytes32 delivered);
    event Reclaimed(bytes32 indexed requestHash, address indexed staker, uint256 bond);
    event Released(bytes32 indexed requestHash, address indexed staker, uint256 bond);
    event Forfeited(bytes32 indexed requestHash, address indexed provider, uint256 bond);
    event ParamsUpdated(uint64 disputeWindow, uint256 minBond, uint16 bondBps);

    function setUp() public {
        _deployJobAndBond();
        EXPECTED = _good();
    }

    // ---- construction / params (M-01, L-01) ----

    /// @dev `new` under `vm.expectRevert` ends the test early in forge; deploy through an external call instead.
    function mk(address o, address p, address j, uint64 w, uint256 m, uint16 b) external returns (address) {
        return address(new PredgeValidatorBondV2(o, p, j, w, m, b));
    }

    function test_constructor() public view {
        assertEq(bond.owner(), safe);
        assertEq(bond.operator(), op);
        assertEq(address(bond.job()), address(job));
        assertEq(bond.disputeWindow(), WINDOW);
        assertEq(bond.minBond(), MIN_BOND);
        assertEq(bond.bondBps(), BPS);
    }

    function test_constructor_reverts() public {
        vm.expectRevert(Owned2Step.ZeroAddress.selector);
        this.mk(address(0), op, address(job), WINDOW, MIN_BOND, BPS);
        vm.expectRevert(Owned2Step.ZeroAddress.selector);
        this.mk(safe, address(0), address(job), WINDOW, MIN_BOND, BPS);
        vm.expectRevert(Owned2Step.ZeroAddress.selector);
        this.mk(safe, op, address(0), WINDOW, MIN_BOND, BPS);
        vm.expectRevert(PredgeValidatorBondV2.BadParams.selector);
        this.mk(safe, op, address(job), 59 minutes, MIN_BOND, BPS);
        vm.expectRevert(PredgeValidatorBondV2.BadParams.selector);
        this.mk(safe, op, address(job), 31 days, MIN_BOND, BPS);
        vm.expectRevert(PredgeValidatorBondV2.BadParams.selector);
        this.mk(safe, op, address(job), WINDOW, 0, BPS);
        vm.expectRevert(PredgeValidatorBondV2.BadParams.selector);
        this.mk(safe, op, address(job), WINDOW, MIN_BOND, 10_001);
    }

    function test_setParams_ownerOnlyAndBounded() public {
        vm.prank(op);
        vm.expectRevert(Owned2Step.NotOwner.selector);
        bond.setParams(2 days, 1, 5000);
        vm.startPrank(safe);
        vm.expectRevert(PredgeValidatorBondV2.BadParams.selector);
        bond.setParams(1 minutes, 1, 5000);
        vm.expectEmit(false, false, false, true);
        emit ParamsUpdated(2 days, 7, 5000);
        bond.setParams(2 days, 7, 5000);
        vm.stopPrank();
        assertEq(bond.disputeWindow(), 2 days);
        assertEq(bond.minBond(), 7);
        assertEq(bond.bondBps(), 5000);
    }

    function test_paramChangeIsNotRetroactive() public {
        (uint256 id, bytes32 spec) = _newJob(10 ether, EXPECTED, SALT);
        _stake(spec, EXPECTED, SALT, id, 10 ether);
        vm.prank(safe);
        bond.setParams(30 days, MIN_BOND, BPS); // owner stretches the window afterwards
        _deliver(id, GOOD);
        _score(spec, 100, EXPECTED, SALT);
        (,,,, , uint64 snap,,,,) = bond.stakes(spec);
        assertEq(snap, WINDOW, "stake keeps the window it was made with");
        vm.warp(block.timestamp + WINDOW);
        bond.reclaim(spec); // would revert WindowOpen if the new 30d window applied
    }

    function test_requiredBond_isMaxOfFloorAndScaled() public {
        assertEq(bond.requiredBond(1), MIN_BOND);
        assertEq(bond.requiredBond(10 ether), 10 ether);
        vm.prank(safe);
        bond.setParams(WINDOW, MIN_BOND, 2500);
        assertEq(bond.requiredBond(10 ether), 2.5 ether);
        assertEq(bond.requiredBond(3), MIN_BOND);
        vm.prank(safe);
        bond.setParams(WINDOW, 1, 3333);
        assertEq(bond.requiredBond(10), 4, "rounds up: ceil(3.333)");
    }

    // ---- stakeAndCommit ----

    function test_stake_ok() public {
        (uint256 id, bytes32 spec) = _newJob(2 ether, EXPECTED, SALT);
        vm.expectEmit(true, true, true, true);
        emit Committed(spec, id, op, _commitment(EXPECTED, SALT), 2 ether, WINDOW);
        _stake(spec, EXPECTED, SALT, id, 2 ether);
        (address staker, PredgeValidatorBondV2.Status st,,,,, uint256 jobId, uint256 b, bytes32 c, bytes32 e) = bond.stakes(spec);
        assertEq(staker, op);
        assertEq(uint8(st), uint8(PredgeValidatorBondV2.Status.Committed));
        assertEq(jobId, id);
        assertEq(b, 2 ether);
        assertEq(c, _commitment(EXPECTED, SALT));
        assertEq(e, bytes32(0), "expected is hidden until the reveal");
        assertEq(bond.totalBonded(), 2 ether);
        (,,, uint64 stakedAt,,,,,,) = bond.stakes(spec);
        assertEq(stakedAt, block.timestamp);
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
        bond.recordScore(spec, 0, EXPECTED, SALT, 0);
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

    function test_score_pass_movesTheMoney() public {
        (uint256 id, bytes32 spec) = _newJob(4 ether, EXPECTED, SALT);
        _stake(spec, EXPECTED, SALT, id, 4 ether);
        _deliver(id, GOOD);
        vm.expectEmit(true, true, false, true);
        emit Scored(spec, id, 100, EXPECTED, uint64(block.timestamp), uint64(block.timestamp) + WINDOW);
        _score(spec, 100, EXPECTED, SALT);
        assertEq(uint8(job.getJob(id).state), uint8(IAgentJobV2.State.Completed));
        assertEq(job.credit(provider), 4 ether);
        assertEq(job.getJob(id).reason, keccak256("reason"));
        (, PredgeValidatorBondV2.Status st,, , uint64 scoredAt,,,,, bytes32 revealed) = bond.stakes(spec);
        assertEq(uint8(st), uint8(PredgeValidatorBondV2.Status.Scored));
        assertEq(revealed, EXPECTED);
        assertGe(scoredAt, job.getJob(id).submittedAt, "window can never start before the submission");
    }

    function test_score_fail_refundsClient() public {
        (uint256 id, bytes32 spec) = _newJob(4 ether, EXPECTED, SALT);
        _stake(spec, EXPECTED, SALT, id, 4 ether);
        _submit(id, OTHER);
        _score(spec, 0, EXPECTED, SALT);
        assertEq(uint8(job.getJob(id).state), uint8(IAgentJobV2.State.Rejected));
        assertEq(job.credit(client), 4 ether);
    }

    function test_score_reverts() public {
        (uint256 id, bytes32 spec) = _newJob(1 ether, EXPECTED, SALT);
        vm.startPrank(op);
        vm.expectRevert(PredgeValidatorBondV2.BadScore.selector);
        bond.recordScore(spec, 50, EXPECTED, SALT, 0);
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

    // ---- challenge ----

    /// @dev `delivered == EXPECTED` means the provider delivers the real bytes; anything else is a claimed hash.
    function _scored(uint256 n, bytes32 delivered, uint8 score, uint256 escrow) internal returns (uint256 id, bytes32 spec) {
        bytes32 salt = keccak256(abi.encode(SALT, n));
        (id, spec) = _newJob(escrow, EXPECTED, salt);
        _stake(spec, EXPECTED, salt, id, bond.requiredBond(escrow));
        if (delivered == EXPECTED) _deliver(id, GOOD);
        else _submit(id, delivered);
        _score(spec, score, EXPECTED, salt);
    }

    function test_challenge_falsePass_paysClientNotCaller() public {
        (, bytes32 spec) = _scored(1, OTHER, 100, 5 ether);
        assertTrue(bond.wouldSlash(spec));
        uint256 callerBefore = stranger.balance;
        vm.expectEmit(true, true, true, true);
        emit Slashed(spec, stranger, client, 5 ether, 100, OTHER);
        vm.prank(stranger);
        bond.challenge(spec);
        assertEq(bond.credit(client), 5 ether, "harmed client is credited");
        assertEq(bond.credit(stranger), 0, "challenger earns nothing");
        assertEq(stranger.balance, callerBefore);
        assertEq(bond.totalBonded(), 0);
        assertEq(bond.slashCount(), 1);
        (,,,,,,, uint256 left,,) = bond.stakes(spec);
        assertEq(left, 0, "slashed stake holds no bond");
        assertFalse(bond.wouldSlash(spec));
        vm.prank(client);
        bond.withdraw();
        assertEq(client.balance, 1_000 ether - 5 ether + 5 ether, "client lost the escrow and got the bond");
    }

    function test_challenge_falseFail_paysProvider() public {
        (, bytes32 spec) = _scored(1, EXPECTED, 0, 5 ether);
        vm.prank(stranger);
        bond.challenge(spec);
        assertEq(bond.credit(provider), 5 ether);
    }

    function test_challenge_honestVerdictsRevert() public {
        (, bytes32 s1) = _scored(1, EXPECTED, 100, 1 ether);
        (, bytes32 s2) = _scored(2, OTHER, 0, 1 ether);
        assertFalse(bond.wouldSlash(s1));
        assertFalse(bond.wouldSlash(s2));
        vm.expectRevert(PredgeValidatorBondV2.VerdictHonest.selector);
        bond.challenge(s1);
        vm.expectRevert(PredgeValidatorBondV2.VerdictHonest.selector);
        bond.challenge(s2);
    }

    function test_challenge_stateAndWindowGuards() public {
        vm.expectRevert(PredgeValidatorBondV2.NotScored.selector);
        bond.challenge(keccak256("none"));
        (, bytes32 spec) = _scored(1, OTHER, 100, 1 ether);
        vm.warp(block.timestamp + WINDOW);
        assertFalse(bond.wouldSlash(spec));
        vm.expectRevert(PredgeValidatorBondV2.WindowClosed.selector);
        bond.challenge(spec);
        bond.reclaim(spec); // a lie nobody challenged in time stands, by design
        vm.expectRevert(PredgeValidatorBondV2.NotScored.selector);
        bond.challenge(spec);
    }

    // ---- reclaim / release ----

    function test_reclaim_paysStakerAfterWindowEvenAfterRotation() public {
        (, bytes32 spec) = _scored(1, EXPECTED, 100, 3 ether);
        vm.expectRevert(PredgeValidatorBondV2.WindowOpen.selector);
        bond.reclaim(spec);
        address newOp = makeAddr("newOp");
        vm.prank(safe);
        bond.setOperator(newOp);
        vm.warp(block.timestamp + WINDOW);
        vm.expectEmit(true, true, false, true);
        emit Reclaimed(spec, op, 3 ether);
        vm.prank(newOp); // the new key triggers it, the OLD staker is credited (L-04)
        bond.reclaim(spec);
        assertEq(bond.credit(op), 3 ether);
        assertEq(bond.credit(newOp), 0);
        assertEq(bond.totalBonded(), 0);
        (,,,,,,, uint256 left,,) = bond.stakes(spec);
        assertEq(left, 0, "reclaimed stake holds no bond");
        vm.expectRevert(PredgeValidatorBondV2.NotScored.selector);
        bond.reclaim(spec);
    }

    function test_release_whenJobExpiredWithoutVerdict() public {
        (uint256 id, bytes32 spec) = _newJob(2 ether, EXPECTED, SALT);
        _stake(spec, EXPECTED, SALT, id, 2 ether);
        vm.expectRevert(PredgeValidatorBondV2.JobNotExpired.selector);
        bond.release(spec);
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(PredgeValidatorBondV2.JobNotExpired.selector); // lapsed but not yet claimed
        bond.release(spec);
        job.claimRefund(id);
        vm.expectEmit(true, true, false, true);
        emit Released(spec, op, 2 ether);
        bond.release(spec);
        assertEq(bond.credit(op), 2 ether);
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
        (, PredgeValidatorBondV2.Status st,,,,,, uint256 left,,) = bond.stakes(spec);
        assertEq(uint8(st), uint8(PredgeValidatorBondV2.Status.Forfeited));
        assertEq(left, 0);
        assertEq(job.credit(client), 2 ether, "documented timeout policy: the escrow still goes to the client");
        vm.expectRevert(PredgeValidatorBondV2.BadStatus.selector);
        bond.release(spec);
    }

    function test_release_reverts() public {
        vm.expectRevert(PredgeValidatorBondV2.NotCommitted.selector);
        bond.release(keccak256("none"));
        (, bytes32 spec) = _scored(1, EXPECTED, 100, 1 ether);
        vm.expectRevert(PredgeValidatorBondV2.BadStatus.selector);
        bond.release(spec);
    }

    // ---- pull payments ----

    function test_payoutToRevertingStakerDoesNotBlock() public {
        // The harmed party cannot receive value: the slash still lands as credit and can be redirected.
        NoReceive bad = new NoReceive();
        bytes32 spec = _bspec(EXPECTED, SALT);
        vm.deal(address(bad), 1 ether);
        vm.prank(address(bad));
        uint256 id = job.createJob{value: 1 ether}(provider, address(bond), spec, uint64(block.timestamp + 1 days));
        _stake(spec, EXPECTED, SALT, id, 1 ether);
        _submit(id, OTHER);
        _score(spec, 100, EXPECTED, SALT);
        bond.challenge(spec);
        assertEq(bond.credit(address(bad)), 1 ether);
        vm.expectRevert(PullCredit.TransferFailed.selector);
        bad.callWithdraw(address(bond));
        vm.prank(address(bad));
        bond.withdrawTo(payable(stranger));
        assertEq(bond.credit(address(bad)), 0);
    }

    // ---- fuzz ----

    /// @dev Whatever the provider submits, the verdict is slashable iff it contradicts the truth, where
    ///      "delivered" means bytes hashed on-chain whose hash equals the client's expected value.
    function testFuzz_slashableIffContradicted(bytes32 salt, bool viaBytes, bool matching, bool claimPass, bytes32 junk) public {
        vm.assume(junk != bytes32(0) && junk != EXPECTED);
        (uint256 id, bytes32 spec) = _newJob(1 ether, EXPECTED, salt);
        _stake(spec, EXPECTED, salt, id, 1 ether);
        if (viaBytes) _deliver(id, matching ? GOOD : abi.encode(junk));
        else _submit(id, matching ? EXPECTED : junk); // a claimed hash, even the right one, is not a delivery
        _score(spec, claimPass ? 100 : 0, EXPECTED, salt);
        bool truth = viaBytes && matching;
        bool lied = claimPass != truth;
        assertEq(bond.wouldSlash(spec), lied);
        if (lied) {
            bond.challenge(spec);
            assertEq(bond.credit(claimPass ? client : provider), 1 ether);
        } else {
            vm.expectRevert(PredgeValidatorBondV2.VerdictHonest.selector);
            bond.challenge(spec);
        }
    }

    /// @dev Self-challenge is never profitable: whoever calls challenge, the operator's net is <= 0 on a lie.
    function testFuzz_operatorNeverProfitsFromChallenging(uint96 escrow, bool claimPass) public {
        escrow = uint96(bound(escrow, 1, 100 ether));
        (uint256 id, bytes32 spec) = _newJob(escrow, EXPECTED, SALT);
        uint256 b = bond.requiredBond(escrow);
        _stake(spec, EXPECTED, SALT, id, b);
        if (claimPass) _submit(id, OTHER); // the verdict below is the opposite of the truth
        else _deliver(id, GOOD);
        _score(spec, claimPass ? 100 : 0, EXPECTED, SALT);
        vm.prank(op);
        bond.challenge(spec);
        assertEq(bond.credit(op), 0);
        assertGe(bond.credit(claimPass ? client : provider), b);
    }
}
