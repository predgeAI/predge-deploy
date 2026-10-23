// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "./Base.sol";
import {ArbiterBase} from "./PredgeRefundArbiterV2.t.sol";
import {PredgeValidatorBondV2} from "../../contracts/v2/PredgeValidatorBondV2.sol";
import {PredgeRefundArbiterV2} from "../../contracts/v2/PredgeRefundArbiterV2.sol";
import {IAgentJobV2} from "../../contracts/v2/interfaces/IAgentJobV2.sol";

/// @notice Regression tests for the Olympix BugPoCer scan of c47ed42 (23 Oct 2026). Each test replays
///         the attack sequence of the corresponding Olympix PoC against the fixed contracts and asserts
///         the harm assertions of that PoC now hold (or, where the attack's first step is now refused,
///         that it reverts and the closest still-possible variant is harmless).
contract OlympixBondRegressionTest is Base {
    bytes32 internal constant SALT = keccak256("client salt");
    bytes32 internal constant AGREED = keccak256("operator-and-provider-agreed hash");
    uint256 internal constant ESCROW = 10 ether;
    bytes32 internal EXPECTED; // sha256(GOOD): fixed by the client in the specHash

    function setUp() public {
        _deployJobAndBond();
        EXPECTED = _good();
    }

    // ------------------------------------------------------------ 5.1.1 (a, b, c)

    /// @dev 5.1.1-a/b step 1: the operator can no longer commit to a value of its own choosing.
    function test_5_1_1_operatorCannotChooseExpected() public {
        (uint256 id, bytes32 spec) = _newJob(ESCROW, EXPECTED, SALT);
        vm.prank(op);
        vm.expectRevert(PredgeValidatorBondV2.CommitmentNotBound.selector);
        bond.stakeAndCommit{value: ESCROW}(spec, _commitment(AGREED, SALT), id);
        // Not even with a spec derived for its own value: that spec belongs to no job the client created.
        bytes32 own = _bspec(AGREED, SALT);
        vm.prank(op);
        vm.expectRevert(PredgeValidatorBondV2.JobNotBound.selector);
        bond.stakeAndCommit{value: ESCROW}(own, _commitment(AGREED, SALT), id);
    }

    /// @dev 5.1.1-a/c, strongest remaining variant: the operator commits to the client's value (it must) and
    ///      leaks it to a colluding provider, who submits the right hash with NO bytes. The PoC's harm
    ///      assertions now hold: the pass is slashable, the client is made whole at full bond, the
    ///      colluders do not profit and the operator cannot reclaim.
    function test_5_1_1_leakedExpectedWithoutBytesIsSlashable() public {
        uint256 providerBefore = provider.balance;
        uint256 opBefore = op.balance;
        (uint256 id, bytes32 spec) = _newJob(ESCROW, EXPECTED, SALT);
        assertEq(bond.requiredBond(ESCROW), ESCROW, "bond fully covers the escrow");
        _stake(spec, EXPECTED, SALT, id, ESCROW);
        _submit(id, EXPECTED); // claimed hash only: no work, no bytes
        assertFalse(job.getJob(id).hashedOnChain);
        _score(spec, 100, EXPECTED, SALT);
        assertEq(job.credit(provider), ESCROW, "the false pass still moves the escrow...");

        assertTrue(bond.wouldSlash(spec), "...but it is now slashable");
        vm.prank(client);
        bond.challenge(spec);
        vm.warp(block.timestamp + WINDOW);
        vm.expectRevert(PredgeValidatorBondV2.NotScored.selector);
        bond.reclaim(spec);

        vm.prank(provider);
        job.withdraw();
        int256 colludersProfit =
            (int256(provider.balance) - int256(providerBefore)) + (int256(op.balance) - int256(opBefore));
        assertLe(colludersProfit, 0, "colluders do not profit at full bond");
        assertGe(bond.credit(client) + job.credit(client), ESCROW, "client is made whole");
    }

    /// @dev 5.1.1-b false fail: the operator cannot commit an unmatchable value; with the client's value, a 0
    ///      on real bytes is slashable and pays the provider.
    function test_5_1_1_falseFailOnRealWorkIsSlashable() public {
        (uint256 id, bytes32 spec) = _newJob(ESCROW, EXPECTED, SALT);
        bytes32 unmatchable = keccak256("garbage the operator picked");
        vm.prank(op);
        vm.expectRevert(PredgeValidatorBondV2.CommitmentNotBound.selector);
        bond.stakeAndCommit{value: ESCROW}(spec, _commitment(unmatchable, SALT), id);

        _stake(spec, EXPECTED, SALT, id, ESCROW);
        _deliver(id, GOOD);
        assertTrue(job.getJob(id).hashedOnChain);
        _score(spec, 0, EXPECTED, SALT); // false fail: client credited the escrow
        assertTrue(bond.wouldSlash(spec));
        vm.prank(provider);
        bond.challenge(spec);
        assertGe(job.credit(provider) + bond.credit(provider), ESCROW, "provider made whole at full bond");
        assertEq(bond.credit(op), 0, "operator loses its bond");
    }

    // ------------------------------------------------------------ 5.2.2 (a, b, c, d, e)

    /// @dev 5.2.2-a, shipped parameters (bondBps = 0): silence on a delivered job now costs the operator its bond,
    ///      and the provider receives it.
    function test_5_2_2_silenceForfeitsFloorBondToProvider() public {
        vm.prank(safe);
        bond.setParams(WINDOW, MIN_BOND, 0);
        (uint256 id, bytes32 spec) = _newJob(100 ether, EXPECTED, SALT);
        _stake(spec, EXPECTED, SALT, id, MIN_BOND);
        _deliver(id, GOOD);
        vm.warp(block.timestamp + EVAL_WINDOW);
        job.claimRefund(id);
        bond.release(spec);
        assertEq(bond.credit(op), 0, "silence is not free");
        assertEq(bond.credit(provider), MIN_BOND, "the provider is compensated with the bond");
        assertEq(job.credit(client), 100 ether, "documented timeout policy: escrow to the client");
    }

    /// @dev 5.2.2-a second test / 5.2.2-b: at full bond the provider receives a bond equal to the escrow.
    function test_5_2_2_silenceForfeitsFullBondToProvider() public {
        (uint256 id, bytes32 spec) = _newJob(5 ether, EXPECTED, SALT);
        _stake(spec, EXPECTED, SALT, id, 5 ether);
        _deliver(id, GOOD);
        vm.warp(block.timestamp + EVAL_WINDOW);
        vm.prank(op);
        vm.expectRevert(); // a late verdict is impossible (job: PastDeadline)
        bond.recordScore(spec, 100, EXPECTED, SALT, 0);
        job.claimRefund(id);
        bond.release(spec);
        assertLt(bond.credit(op), 5 ether);
        assertEq(bond.credit(provider), 5 ether);
        uint256 before_ = provider.balance;
        vm.prank(provider);
        bond.withdraw();
        assertEq(provider.balance - before_, 5 ether);
    }

    /// @dev Unchanged and intended: an operator that never staked, or a job never submitted, returns the bond.
    function test_5_2_2_noSubmissionStillReturnsBond() public {
        (uint256 id, bytes32 spec) = _newJob(1 ether, EXPECTED, SALT);
        _stake(spec, EXPECTED, SALT, id, 1 ether);
        vm.warp(block.timestamp + 7 days);
        job.claimRefund(id);
        bond.release(spec);
        assertEq(bond.credit(op), 1 ether);
        assertEq(bond.credit(provider), 0);
    }

    // ------------------------------------------------------------ 5.2.3 / 5.1.2-a

    /// @dev 5.2.3: the operator acting as the job's client cannot stake on (or later score) that job.
    function test_5_2_3_operatorAsClientRefused() public {
        bytes32 spec = _bspec(EXPECTED, SALT);
        vm.prank(op);
        uint256 id = job.createJob{value: 1 ether}(provider, address(bond), spec, uint64(block.timestamp + 1 days));
        vm.prank(op);
        vm.expectRevert(PredgeValidatorBondV2.ClientIsOperator.selector);
        bond.stakeAndCommit{value: 1 ether}(spec, _commitment(EXPECTED, SALT), id);
    }

    // ------------------------------------------------------------ 5.3.8

    /// @dev 5.3.8: rotating the operator mid-flight without handing over the preimage no longer leaves the provider
    ///      with nothing: the stake is forfeited to it.
    function test_5_3_8_rotationWithoutPreimageForfeitsToProvider() public {
        (uint256 id, bytes32 spec) = _newJob(2 ether, EXPECTED, SALT);
        _stake(spec, EXPECTED, SALT, id, 2 ether);
        _deliver(id, GOOD);
        address newOp = makeAddr("newOp");
        vm.prank(safe);
        bond.setOperator(newOp);
        vm.prank(newOp); // does not know the salt
        vm.expectRevert(PredgeValidatorBondV2.BadReveal.selector);
        bond.recordScore(spec, 100, EXPECTED, keccak256("guess"), 0);
        vm.warp(block.timestamp + EVAL_WINDOW);
        job.claimRefund(id);
        bond.release(spec);
        assertEq(bond.credit(provider), 2 ether);
        assertEq(bond.credit(op), 0);
    }
}

contract OlympixArbiterRegressionTest is ArbiterBase {
    PredgeRefundArbiterV2.Direction internal constant REFUND = PredgeRefundArbiterV2.Direction.Refund;
    PredgeRefundArbiterV2.Direction internal constant RELEASE = PredgeRefundArbiterV2.Direction.Release;

    function setUp() public {
        _deployArbiter();
    }

    /// @dev 5.2.1-a/b/d: the PoC's payment (lockup ends 1 hour after the window) can no longer be ruled on in
    ///      either direction, so a free dispute can never run a ruling past the release.
    function test_5_2_1_shortLockupCannotBeRuled() public {
        uint256 pid = rp.recordPayment(payer, payee, 1 ether, block.timestamp + WINDOW + 1 hours);
        _file(pid);
        uint256 need = arb.requiredBond(1 ether);
        vm.startPrank(op);
        vm.expectRevert(PredgeRefundArbiterV2.LockupTooShort.selector);
        arb.rule{value: need}(pid, payer, EV_PAYER, REFUND);
        vm.expectRevert(PredgeRefundArbiterV2.LockupTooShort.selector);
        arb.rule{value: need}(pid, payee, EV_PAYEE, RELEASE);
        vm.stopPrank();
    }

    /// @dev 5.2.1-a replayed at the tightest lockup that is now allowed: the payee disputes one second before the
    ///      window closes and the owner resolves at the very last second of its resolution period. The refund
    ///      still executes, because the whole timeline ends before releaseTimestamp.
    function test_5_2_1_lastSecondDisputeStillLeavesOwnerFullPeriod() public {
        uint256 pid = rp.recordPayment(payer, payee, 1 ether, block.timestamp + WINDOW + arb.RESOLUTION_TIMEOUT() + 1);
        _file(pid);
        uint256 need = arb.requiredBond(1 ether);
        _rule(pid, payer, EV_PAYER, REFUND, need);
        uint256 ruledAt = block.timestamp;
        vm.warp(ruledAt + WINDOW - 1);
        vm.prank(payee);
        arb.dispute(pid, EV_COUNTER);
        uint64 expiresAt = arb.rulings(pid).expiresAt;
        (,,, uint256 releaseTs) = rp.paymentInfo(pid);
        assertLt(expiresAt, releaseTs, "the owner's whole resolution period ends before release");
        vm.warp(uint256(expiresAt) - 1);
        vm.prank(safe);
        arb.resolve(pid, REFUND);
        (,,,, bool refunded) = rp.payments(pid);
        assertTrue(refunded, "the correct refund executes");
        assertEq(arb.credit(op), need);
    }

    /// @dev 5.2.1-b: a Release ruling overturned into a Refund at the last moment still executes and slashes.
    function test_5_2_1_releaseOverturnStillExecutes() public {
        uint256 pid = rp.recordPayment(payer, payee, 1 ether, block.timestamp + WINDOW + arb.RESOLUTION_TIMEOUT() + 1);
        _file(pid);
        uint256 need = arb.requiredBond(1 ether);
        _rule(pid, payee, EV_PAYEE, RELEASE, need);
        vm.warp(block.timestamp + WINDOW - 1);
        vm.prank(payer);
        arb.dispute(pid, EV_COUNTER);
        vm.warp(uint256(arb.rulings(pid).expiresAt) - 1);
        vm.prank(safe);
        arb.resolve(pid, REFUND);
        assertEq(arb.credit(payer), need, "operator's bond goes to the harmed payer");
        assertEq(rp.refundCount(), 1);
    }
}
