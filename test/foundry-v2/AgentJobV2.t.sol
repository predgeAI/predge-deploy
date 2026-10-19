// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base, NoReceive, ReentrantReceiver} from "./Base.sol";
import {AgentJobV2} from "../../contracts/v2/AgentJobV2.sol";
import {IAgentJobV2} from "../../contracts/v2/interfaces/IAgentJobV2.sol";
import {PullCredit} from "../../contracts/v2/access/PullCredit.sol";

contract AgentJobV2Test is Base {
    address internal evaluator = makeAddr("evaluator");
    bytes32 internal constant SPEC = keccak256("spec");
    bytes32 internal constant DELIV = keccak256("deliverable");

    event JobCreated(uint256 indexed jobId, address indexed client, address indexed evaluator, address provider, uint256 escrow, uint64 expiredAt, bytes32 specHash);
    event Submitted(uint256 indexed jobId, address indexed provider, bytes32 deliverable, bool hashedOnChain);
    event Completed(uint256 indexed jobId, address indexed evaluator, address indexed recipient, uint256 amount, bytes32 reason);
    event Rejected(uint256 indexed jobId, address indexed evaluator, address indexed recipient, uint256 amount, bytes32 reason);
    event Refunded(uint256 indexed jobId, address indexed caller, address indexed recipient, uint256 amount);
    event Withdrawn(address indexed account, address indexed to, uint256 amount);

    function setUp() public {
        job = new AgentJobV2(EVAL_WINDOW);
        vm.deal(client, 100 ether);
    }

    function _create(uint256 v) internal returns (uint256 id) {
        vm.prank(client);
        id = job.createJob{value: v}(provider, evaluator, SPEC, uint64(block.timestamp + 1 days));
    }

    function mk(uint64 w) external returns (address) {
        return address(new AgentJobV2(w));
    }

    function test_constructor_rejectsZeroWindow() public {
        vm.expectRevert(AgentJobV2.BadWindow.selector);
        this.mk(0);
        assertEq(job.evaluationWindow(), EVAL_WINDOW);
    }

    function test_createJob_storesAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit JobCreated(1, client, evaluator, provider, 5 ether, uint64(block.timestamp + 1 days), SPEC);
        uint256 id = _create(5 ether);
        IAgentJobV2.Job memory j = job.getJob(id);
        assertEq(id, 1);
        assertEq(j.client, client);
        assertEq(j.provider, provider);
        assertEq(j.evaluator, evaluator);
        assertEq(j.escrow, 5 ether);
        assertEq(uint8(j.state), uint8(IAgentJobV2.State.Open));
        assertEq(job.totalEscrowed(), 5 ether);
        assertEq(job.jobCount(), 1);
    }

    function test_createJob_reverts() public {
        vm.startPrank(client);
        vm.expectRevert(AgentJobV2.ZeroAddress.selector);
        job.createJob{value: 1}(address(0), evaluator, SPEC, uint64(block.timestamp + 1));
        vm.expectRevert(AgentJobV2.ZeroAddress.selector);
        job.createJob{value: 1}(provider, address(0), SPEC, uint64(block.timestamp + 1));
        vm.expectRevert(AgentJobV2.ZeroEscrow.selector);
        job.createJob(provider, evaluator, SPEC, uint64(block.timestamp + 1));
        vm.expectRevert(AgentJobV2.BadExpiry.selector);
        job.createJob{value: 1}(provider, evaluator, SPEC, uint64(block.timestamp));
        vm.stopPrank();
    }

    function test_submit_hashOnly() public {
        uint256 id = _create(1 ether);
        vm.expectEmit(true, true, false, true);
        emit Submitted(id, provider, DELIV, false);
        vm.prank(provider);
        job.submit(id, DELIV, "");
        IAgentJobV2.Job memory j = job.getJob(id);
        assertEq(j.deliverable, DELIV);
        assertFalse(j.hashedOnChain);
        assertEq(j.submittedAt, block.timestamp);
        assertEq(uint8(j.state), uint8(IAgentJobV2.State.Submitted));
    }

    function test_submit_bytesHashedOnChain() public {
        uint256 id = _create(1 ether);
        bytes memory out = "the actual output";
        bytes32 h = sha256(out);
        vm.prank(provider);
        job.submit(id, h, out);
        IAgentJobV2.Job memory j = job.getJob(id);
        assertEq(j.deliverable, sha256(out));
        assertTrue(j.hashedOnChain);
    }

    function test_submit_bytesMismatchReverts() public {
        uint256 id = _create(1 ether);
        vm.prank(provider);
        vm.expectRevert(AgentJobV2.HashMismatch.selector);
        job.submit(id, DELIV, "not matching");
    }

    function test_submit_reverts() public {
        uint256 id = _create(1 ether);
        vm.prank(stranger);
        vm.expectRevert(AgentJobV2.NotProvider.selector);
        job.submit(id, DELIV, "");
        vm.startPrank(provider);
        vm.expectRevert(AgentJobV2.ZeroDeliverable.selector);
        job.submit(id, bytes32(0), "");
        vm.expectRevert(AgentJobV2.BadState.selector);
        job.submit(99, DELIV, "");
        job.submit(id, DELIV, "");
        vm.expectRevert(AgentJobV2.BadState.selector);
        job.submit(id, DELIV, "");
        vm.stopPrank();
    }

    function test_submit_afterExpiryReverts() public {
        uint256 id = _create(1 ether);
        vm.warp(block.timestamp + 1 days);
        vm.prank(provider);
        vm.expectRevert(AgentJobV2.PastDeadline.selector);
        job.submit(id, DELIV, "");
    }

    function test_complete_creditsProviderPull() public {
        uint256 id = _create(2 ether);
        vm.prank(provider);
        job.submit(id, DELIV, "");
        vm.expectEmit(true, true, true, true);
        emit Completed(id, evaluator, provider, 2 ether, bytes32("r"));
        vm.prank(evaluator);
        job.complete(id, bytes32("r"), "");
        assertEq(job.credit(provider), 2 ether);
        assertEq(job.totalCredit(), 2 ether);
        assertEq(job.totalEscrowed(), 0);
        assertEq(uint8(job.getJob(id).state), uint8(IAgentJobV2.State.Completed));
        assertEq(job.getJob(id).reason, bytes32("r"));
        uint256 before_ = provider.balance;
        vm.prank(provider);
        job.withdraw();
        assertEq(provider.balance, before_ + 2 ether);
        assertEq(job.totalCredit(), 0);
    }

    function test_reject_creditsClient() public {
        uint256 id = _create(2 ether);
        vm.prank(provider);
        job.submit(id, DELIV, "");
        vm.expectEmit(true, true, true, true);
        emit Rejected(id, evaluator, client, 2 ether, bytes32("r"));
        vm.prank(evaluator);
        job.reject(id, bytes32("r"), "");
        assertEq(job.credit(client), 2 ether);
        assertEq(uint8(job.getJob(id).state), uint8(IAgentJobV2.State.Rejected));
    }

    function test_decide_reverts() public {
        uint256 id = _create(1 ether);
        vm.prank(evaluator);
        vm.expectRevert(AgentJobV2.BadState.selector); // not submitted yet
        job.complete(id, 0, "");
        vm.prank(provider);
        job.submit(id, DELIV, "");
        vm.prank(stranger);
        vm.expectRevert(AgentJobV2.NotEvaluator.selector);
        job.complete(id, 0, "");
        vm.prank(stranger);
        vm.expectRevert(AgentJobV2.NotEvaluator.selector);
        job.reject(id, 0, "");
        vm.warp(block.timestamp + EVAL_WINDOW);
        vm.prank(evaluator);
        vm.expectRevert(AgentJobV2.PastDeadline.selector);
        job.complete(id, 0, "");
    }

    function test_decide_onlyOnce() public {
        uint256 id = _create(1 ether);
        vm.prank(provider);
        job.submit(id, DELIV, "");
        vm.startPrank(evaluator);
        job.complete(id, 0, "");
        vm.expectRevert(AgentJobV2.BadState.selector);
        job.reject(id, 0, "");
        vm.expectRevert(AgentJobV2.BadState.selector);
        job.complete(id, 0, "");
        vm.stopPrank();
    }

    // ---- expiry (M-03) ----

    function test_claimRefund_openJobAfterExpiry() public {
        uint256 id = _create(3 ether);
        vm.expectRevert(AgentJobV2.NotExpired.selector);
        job.claimRefund(id);
        vm.warp(block.timestamp + 1 days);
        vm.expectEmit(true, true, true, true);
        emit Refunded(id, stranger, client, 3 ether);
        vm.prank(stranger); // anyone can trigger, the client is credited
        job.claimRefund(id);
        assertEq(job.credit(client), 3 ether);
        assertEq(uint8(job.getJob(id).state), uint8(IAgentJobV2.State.Expired));
        vm.expectRevert(AgentJobV2.BadState.selector);
        job.claimRefund(id);
    }

    function test_claimRefund_submittedButEvaluatorSilent() public {
        uint256 id = _create(3 ether);
        vm.prank(provider);
        job.submit(id, DELIV, "");
        vm.warp(block.timestamp + EVAL_WINDOW - 1);
        vm.expectRevert(AgentJobV2.NotExpired.selector);
        job.claimRefund(id);
        vm.warp(block.timestamp + 1);
        job.claimRefund(id);
        assertEq(job.credit(client), 3 ether);
        assertEq(job.credit(provider), 0, "documented: silent evaluator refunds the client");
    }

    function test_claimRefund_badStates() public {
        vm.expectRevert(AgentJobV2.BadState.selector);
        job.claimRefund(42);
        uint256 id = _create(1 ether);
        vm.prank(provider);
        job.submit(id, DELIV, "");
        vm.prank(evaluator);
        job.complete(id, 0, "");
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(AgentJobV2.BadState.selector);
        job.claimRefund(id);
    }

    // ---- pull payments (L-03) ----

    function test_withdraw_reverts() public {
        vm.expectRevert(PullCredit.NothingToWithdraw.selector);
        job.withdraw();
        vm.expectRevert(PullCredit.ZeroRecipient.selector);
        job.withdrawTo(payable(address(0)));
    }

    function test_revertingRecipientCannotBlockOutcomeAndCanRedirect() public {
        NoReceive bad = new NoReceive();
        vm.prank(client);
        uint256 id = job.createJob{value: 1 ether}(address(bad), evaluator, SPEC, uint64(block.timestamp + 1 days));
        vm.prank(address(bad));
        job.submit(id, DELIV, "");
        vm.prank(evaluator);
        job.complete(id, 0, ""); // does not revert even though the provider cannot receive
        assertEq(job.credit(address(bad)), 1 ether);
        vm.expectRevert(PullCredit.TransferFailed.selector);
        bad.callWithdraw(address(job));
        vm.prank(address(bad));
        job.withdrawTo(payable(stranger));
        assertEq(job.credit(address(bad)), 0);
    }

    function test_withdraw_isReentrancySafe() public {
        ReentrantReceiver r = new ReentrantReceiver();
        r.set(address(job));
        vm.prank(client);
        uint256 id = job.createJob{value: 1 ether}(address(r), evaluator, SPEC, uint64(block.timestamp + 1 days));
        vm.prank(address(r));
        job.submit(id, DELIV, "");
        vm.prank(evaluator);
        job.complete(id, 0, "");
        r.go();
        assertTrue(r.reentered());
        assertTrue(r.reenterFailed());
        assertEq(address(r).balance, 1 ether);
    }

    // ---- fuzz ----

    function testFuzz_escrowPaidExactlyOnce(uint96 amt, bool pass, bool lateDecision) public {
        amt = uint96(bound(amt, 1, 50 ether));
        uint256 id = _create(amt);
        vm.prank(provider);
        job.submit(id, DELIV, "");
        if (lateDecision) {
            vm.warp(block.timestamp + EVAL_WINDOW);
            job.claimRefund(id);
            assertEq(job.credit(client), amt);
        } else {
            vm.prank(evaluator);
            if (pass) job.complete(id, 0, ""); else job.reject(id, 0, "");
            assertEq(job.credit(pass ? provider : client), amt);
        }
        assertEq(job.totalEscrowed(), 0);
        assertEq(job.totalCredit(), amt);
        assertGe(address(job).balance, job.totalCredit());
    }

    function testFuzz_bytesAlwaysHashedOnChain(bytes calldata out) public {
        vm.assume(out.length > 0);
        uint256 id = _create(1 ether);
        bytes32 h = sha256(out);
        vm.prank(provider);
        job.submit(id, h, out);
        assertEq(job.getJob(id).deliverable, h);
    }
}
