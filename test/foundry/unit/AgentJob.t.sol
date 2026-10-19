// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AgentJob} from "../../../contracts/AgentJob.sol";
import {ToggleReceiver, Reenterer} from "../utils/Actors.sol";

contract AgentJobTest is Test {
    AgentJob job;
    address client = makeAddr("client");
    address provider = makeAddr("provider");
    address evaluator = makeAddr("evaluator");
    address stranger = makeAddr("stranger");
    bytes32 constant SPEC = keccak256("spec");
    bytes32 constant DELIV = keccak256("deliverable");
    bytes32 constant REASON = keccak256("reason");

    event JobCreated(uint256 indexed jobId, address indexed client, address indexed evaluator, address provider, uint96 escrow, bytes32 specHash);
    event Submitted(uint256 indexed jobId, bytes32 deliverable);
    event Completed(uint256 indexed jobId, bytes32 reason, address provider, uint96 paid);
    event Rejected(uint256 indexed jobId, bytes32 reason, address client, uint96 refunded);

    function setUp() public {
        job = new AgentJob();
        vm.deal(client, 1_000 ether);
    }

    function _create(uint256 amt) internal returns (uint256 id) {
        vm.prank(client);
        id = job.createJob{value: amt}(provider, evaluator, SPEC);
    }

    function _submitted(uint256 amt) internal returns (uint256 id) {
        id = _create(amt);
        vm.prank(provider);
        job.submit(id, DELIV, "");
    }

    function _assertJob(uint256 id, AgentJob.State st, bytes32 d, bytes32 r, uint96 esc) internal view {
        (AgentJob.State s, bytes32 spec, bytes32 dd, bytes32 rr, uint96 e) = job.jobState(id);
        assertEq(uint8(s), uint8(st), "state");
        assertEq(spec, SPEC, "spec");
        assertEq(dd, d, "deliverable");
        assertEq(rr, r, "reason");
        assertEq(e, esc, "escrow");
    }

    // ───────────── createJob ─────────────
    function test_createJob_storesEverything() public {
        vm.expectEmit(true, true, true, true, address(job));
        emit JobCreated(1, client, evaluator, provider, 1 ether, SPEC);
        uint256 id = _create(1 ether);
        assertEq(id, 1);
        assertEq(job.jobCount(), 1);
        assertEq(address(job).balance, 1 ether);
        (address c, address p, address e, uint96 esc, bytes32 spec, bytes32 d, bytes32 r, AgentJob.State s) = job.jobs(id);
        assertEq(c, client);
        assertEq(p, provider);
        assertEq(e, evaluator);
        assertEq(esc, 1 ether);
        assertEq(spec, SPEC);
        assertEq(d, bytes32(0));
        assertEq(r, bytes32(0));
        assertEq(uint8(s), uint8(AgentJob.State.Open));
    }

    function test_createJob_idsIncrement() public {
        assertEq(_create(1), 1);
        assertEq(_create(2), 2);
        assertEq(_create(3), 3);
        assertEq(job.jobCount(), 3);
        assertEq(address(job).balance, 6);
    }

    function test_createJob_revert_zeroProvider() public {
        vm.prank(client);
        vm.expectRevert(AgentJob.ZeroAddress.selector);
        job.createJob{value: 1}(address(0), evaluator, SPEC);
    }

    function test_createJob_revert_zeroEvaluator() public {
        vm.prank(client);
        vm.expectRevert(AgentJob.ZeroAddress.selector);
        job.createJob{value: 1}(provider, address(0), SPEC);
    }

    function test_createJob_revert_zeroEscrow() public {
        vm.prank(client);
        vm.expectRevert(AgentJob.ZeroEscrow.selector);
        job.createJob(provider, evaluator, SPEC);
    }

    function testFuzz_createJob_escrowEqualsValue(uint96 amt) public {
        amt = uint96(bound(amt, 1, type(uint96).max));
        vm.deal(client, amt);
        uint256 id = _create(amt);
        (, , , uint96 esc, , , , ) = job.jobs(id);
        assertEq(esc, amt);
        assertEq(address(job).balance, amt);
    }

    /// BUG (AJ-01): escrow is stored as uint96(msg.value) with no bound check. Any msg.value
    /// >= 2^96 wei is silently truncated: the contract keeps the full value but only the low 96
    /// bits are ever paid out, so the remainder is locked forever. Requires ~7.9e10 units of an
    /// 18-decimal native token, so practically unreachable on most chains, but the escrow
    /// invariant (escrow == value received) is not enforced.
    function test_BUG_createJob_truncatesEscrowAbove2pow96() public {
        uint256 amt = uint256(type(uint96).max) + 2;
        vm.deal(client, amt);
        uint256 id = _create(amt);
        (, , , uint96 esc, , , , ) = job.jobs(id);
        assertEq(uint256(esc), amt, "escrow truncated to uint96");
    }

    // ───────────── submit ─────────────
    function test_submit_setsDeliverable() public {
        uint256 id = _create(1 ether);
        vm.expectEmit(true, false, false, true, address(job));
        emit Submitted(id, DELIV);
        vm.prank(provider);
        job.submit(id, DELIV, hex"beef");
        _assertJob(id, AgentJob.State.Submitted, DELIV, bytes32(0), 1 ether);
    }

    function test_submit_revert_notProvider() public {
        uint256 id = _create(1 ether);
        vm.prank(stranger);
        vm.expectRevert(AgentJob.NotProvider.selector);
        job.submit(id, DELIV, "");
    }

    function test_submit_revert_nonexistentJob() public {
        vm.prank(provider);
        vm.expectRevert(AgentJob.NotProvider.selector);
        job.submit(42, DELIV, "");
    }

    function test_submit_revert_twice() public {
        uint256 id = _submitted(1 ether);
        vm.prank(provider);
        vm.expectRevert(AgentJob.BadState.selector);
        job.submit(id, keccak256("other"), "");
    }

    function test_submit_revert_afterComplete() public {
        uint256 id = _submitted(1 ether);
        vm.prank(evaluator);
        job.complete(id, REASON, "");
        vm.prank(provider);
        vm.expectRevert(AgentJob.BadState.selector);
        job.submit(id, DELIV, "");
    }

    // ───────────── complete ─────────────
    function test_complete_paysProvider() public {
        uint256 id = _submitted(3 ether);
        vm.expectEmit(true, false, false, true, address(job));
        emit Completed(id, REASON, provider, 3 ether);
        vm.prank(evaluator);
        job.complete(id, REASON, "");
        assertEq(provider.balance, 3 ether);
        assertEq(address(job).balance, 0);
        _assertJob(id, AgentJob.State.Completed, DELIV, REASON, 0);
    }

    function test_complete_revert_notEvaluator() public {
        uint256 id = _submitted(1 ether);
        address[3] memory who = [client, provider, stranger];
        for (uint256 i; i < 3; i++) {
            vm.prank(who[i]);
            vm.expectRevert(AgentJob.NotEvaluator.selector);
            job.complete(id, REASON, "");
        }
    }

    function test_complete_revert_whileOpen() public {
        uint256 id = _create(1 ether);
        vm.prank(evaluator);
        vm.expectRevert(AgentJob.BadState.selector);
        job.complete(id, REASON, "");
    }

    function test_complete_revert_twice_noDoublePay() public {
        uint256 id = _submitted(1 ether);
        vm.prank(evaluator);
        job.complete(id, REASON, "");
        vm.prank(evaluator);
        vm.expectRevert(AgentJob.BadState.selector);
        job.complete(id, REASON, "");
        assertEq(provider.balance, 1 ether);
    }

    function test_complete_revert_afterReject() public {
        uint256 id = _submitted(1 ether);
        vm.prank(evaluator);
        job.reject(id, REASON, "");
        vm.prank(evaluator);
        vm.expectRevert(AgentJob.BadState.selector);
        job.complete(id, REASON, "");
    }

    function test_complete_revert_providerCannotReceive() public {
        ToggleReceiver p = new ToggleReceiver();
        vm.prank(client);
        uint256 id = job.createJob{value: 1 ether}(address(p), evaluator, SPEC);
        p.exec(address(job), 0, abi.encodeCall(AgentJob.submit, (id, DELIV, "")));
        p.setAccept(false);
        vm.prank(evaluator);
        vm.expectRevert(AgentJob.TransferFailed.selector);
        job.complete(id, REASON, "");
        // state rolled back: evaluator can still reject and refund the client
        _assertJob(id, AgentJob.State.Submitted, DELIV, bytes32(0), 1 ether);
        vm.prank(evaluator);
        job.reject(id, REASON, "");
        assertEq(client.balance, 1_000 ether);
    }

    function test_complete_reentrancyByProviderFails() public {
        Reenterer p = new Reenterer();
        vm.prank(client);
        uint256 id = job.createJob{value: 1 ether}(address(p), address(p), SPEC);
        p.exec(address(job), 0, abi.encodeCall(AgentJob.submit, (id, DELIV, "")));
        p.arm(address(job), abi.encodeCall(AgentJob.reject, (id, REASON, "")));
        p.exec(address(job), 0, abi.encodeCall(AgentJob.complete, (id, REASON, "")));
        assertTrue(p.reentered());
        assertFalse(p.reentrySucceeded(), "re-entrant reject must fail");
        assertEq(address(p).balance, 1 ether);
        assertEq(address(job).balance, 0);
    }

    // ───────────── reject ─────────────
    function test_reject_refundsClient() public {
        uint256 id = _submitted(2 ether);
        uint256 before = client.balance;
        vm.expectEmit(true, false, false, true, address(job));
        emit Rejected(id, REASON, client, 2 ether);
        vm.prank(evaluator);
        job.reject(id, REASON, "");
        assertEq(client.balance, before + 2 ether);
        assertEq(provider.balance, 0);
        _assertJob(id, AgentJob.State.Rejected, DELIV, REASON, 0);
    }

    function test_reject_revert_notEvaluator() public {
        uint256 id = _submitted(1 ether);
        vm.prank(client);
        vm.expectRevert(AgentJob.NotEvaluator.selector);
        job.reject(id, REASON, "");
    }

    function test_reject_revert_whileOpen() public {
        uint256 id = _create(1 ether);
        vm.prank(evaluator);
        vm.expectRevert(AgentJob.BadState.selector);
        job.reject(id, REASON, "");
    }

    function test_reject_revert_twice_noDoubleRefund() public {
        uint256 id = _submitted(1 ether);
        vm.prank(evaluator);
        job.reject(id, REASON, "");
        uint256 bal = client.balance;
        vm.prank(evaluator);
        vm.expectRevert(AgentJob.BadState.selector);
        job.reject(id, REASON, "");
        assertEq(client.balance, bal);
    }

    function test_reject_revert_clientCannotReceive() public {
        ToggleReceiver c = new ToggleReceiver();
        vm.deal(address(c), 1 ether);
        bytes memory ret = c.exec(address(job), 1 ether, abi.encodeCall(AgentJob.createJob, (provider, evaluator, SPEC)));
        uint256 id = abi.decode(ret, (uint256));
        vm.prank(provider);
        job.submit(id, DELIV, "");
        c.setAccept(false);
        vm.prank(evaluator);
        vm.expectRevert(AgentJob.TransferFailed.selector);
        job.reject(id, REASON, "");
    }

    /// Finding AJ-02 (documented behaviour): if BOTH the provider and the client cannot receive
    /// native value (e.g. blacklisted / non-payable contracts), the escrow is locked forever:
    /// neither complete nor reject can succeed and there is no timeout or rescue path.
    function test_finding_escrowLockedWhenNeitherPartyCanReceive() public {
        ToggleReceiver c = new ToggleReceiver();
        ToggleReceiver p = new ToggleReceiver();
        vm.deal(address(c), 1 ether);
        uint256 id = abi.decode(
            c.exec(address(job), 1 ether, abi.encodeCall(AgentJob.createJob, (address(p), evaluator, SPEC))), (uint256)
        );
        p.exec(address(job), 0, abi.encodeCall(AgentJob.submit, (id, DELIV, "")));
        c.setAccept(false);
        p.setAccept(false);
        vm.startPrank(evaluator);
        vm.expectRevert(AgentJob.TransferFailed.selector);
        job.complete(id, REASON, "");
        vm.expectRevert(AgentJob.TransferFailed.selector);
        job.reject(id, REASON, "");
        vm.stopPrank();
        assertEq(address(job).balance, 1 ether);
    }

    /// Finding AJ-03 (documented behaviour): a job that is never submitted has no expiry, so
    /// the client's escrow stays locked unless the provider submits.
    function test_finding_openJobHasNoTimeoutRefund() public {
        uint256 id = _create(1 ether);
        vm.warp(block.timestamp + 3650 days);
        vm.prank(evaluator);
        vm.expectRevert(AgentJob.BadState.selector);
        job.reject(id, REASON, "");
    }

    // ───────────── fuzz: full lifecycle conserves value ─────────────
    function testFuzz_lifecycle_conservesValue(uint96 amt, bool pass, bytes32 d, bytes32 r) public {
        amt = uint96(bound(amt, 1, 1_000 ether));
        uint256 id = _create(amt);
        vm.prank(provider);
        job.submit(id, d, "");
        uint256 cBefore = client.balance;
        vm.prank(evaluator);
        if (pass) job.complete(id, r, "");
        else job.reject(id, r, "");
        assertEq(address(job).balance, 0);
        if (pass) assertEq(provider.balance, amt);
        else assertEq(client.balance, cBefore + amt);
        _assertJobFuzz(id, pass ? AgentJob.State.Completed : AgentJob.State.Rejected, d, r);
    }

    function _assertJobFuzz(uint256 id, AgentJob.State st, bytes32 d, bytes32 r) internal view {
        (AgentJob.State s, , bytes32 dd, bytes32 rr, uint96 e) = job.jobState(id);
        assertEq(uint8(s), uint8(st));
        assertEq(dd, d);
        assertEq(rr, r);
        assertEq(e, 0);
    }

    function testFuzz_onlyEvaluatorCanSettle(address caller) public {
        vm.assume(caller != evaluator);
        uint256 id = _submitted(1 ether);
        vm.startPrank(caller);
        vm.expectRevert(AgentJob.NotEvaluator.selector);
        job.complete(id, REASON, "");
        vm.expectRevert(AgentJob.NotEvaluator.selector);
        job.reject(id, REASON, "");
        vm.stopPrank();
    }
}
