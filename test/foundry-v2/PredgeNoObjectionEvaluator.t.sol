// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AgentJobV2} from "../../contracts/v2/AgentJobV2.sol";
import {IAgentJobV2} from "../../contracts/v2/interfaces/IAgentJobV2.sol";
import {PredgeNoObjectionEvaluator as Eval} from "../../contracts/rsk-poc/PredgeNoObjectionEvaluator.sol";

contract NoObjectionEvaluatorTest is Test {
    uint64 constant OBJ = 10 days;
    uint64 constant WIN = 24 days; // 10 days objection + 14 days review

    AgentJobV2 job;
    Eval ev;
    address client = makeAddr("client");
    address provider = makeAddr("provider");
    address reviewer = makeAddr("reviewer");
    address stranger = makeAddr("stranger");
    bytes32 checklist = keccak256("ReRISE B2B evidence checklist v1");
    bytes32[] files;

    function setUp() public {
        job = new AgentJobV2(WIN);
        ev = new Eval(address(job), reviewer, OBJ);
        vm.deal(client, 10 ether);
        files.push(sha256("before.jpg"));
        files.push(sha256("after.jpg"));
        files.push(sha256("completion-report.pdf"));
        files.push(sha256("manifest.pdf"));
    }

    function _open(uint256 n) internal returns (uint256 id) {
        bytes32 spec = ev.specHashFor(checklist, n);
        vm.prank(client);
        id = job.createJob{value: 1 ether}(provider, address(ev), spec, uint64(block.timestamp + 30 days));
        assertEq(job.getJob(id).client, client);
    }

    function _submit(uint256 id, bytes32[] memory fh) internal {
        bytes memory m = abi.encode(checklist, fh);
        bytes32 d = sha256(m);
        vm.prank(provider);
        job.submit(id, d, m);
    }

    function test_silenceReleasesToContractor() public {
        uint256 id = _open(4);
        _submit(id, files);
        vm.expectRevert(Eval.ObjectionPeriodRunning.selector);
        ev.releaseOnSilence(id, checklist, files);
        vm.warp(block.timestamp + OBJ);
        assertTrue(ev.packageComplete(id, checklist, files));
        vm.prank(stranger);
        ev.releaseOnSilence(id, checklist, files);
        assertEq(uint8(job.getJob(id).state), uint8(IAgentJobV2.State.Completed));
        assertEq(job.credit(provider), 1 ether);
        assertEq(job.credit(client), 0);
    }

    function test_objectionHoldsThenReviewerDecides() public {
        uint256 id = _open(4);
        _submit(id, files);
        vm.warp(block.timestamp + OBJ - 1);
        vm.prank(client);
        ev.object(id, keccak256("written objection"));
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(Eval.OnHold.selector);
        ev.releaseOnSilence(id, checklist, files);
        vm.prank(stranger);
        vm.expectRevert(Eval.NotReviewer.selector);
        ev.resolve(id, true, keccak256("x"));
        vm.prank(reviewer);
        ev.resolve(id, false, keccak256("refund decision"));
        assertEq(uint8(job.getJob(id).state), uint8(IAgentJobV2.State.Rejected));
        assertEq(job.credit(client), 1 ether);
    }

    function test_objectionReviewerPays() public {
        uint256 id = _open(4);
        _submit(id, files);
        vm.prank(client);
        ev.object(id, keccak256("o"));
        vm.prank(reviewer);
        ev.resolve(id, true, keccak256("pay"));
        assertEq(job.credit(provider), 1 ether);
    }

    function test_reviewerSilenceRefundsClient() public {
        uint256 id = _open(4);
        _submit(id, files);
        vm.prank(client);
        ev.object(id, keccak256("o"));
        vm.warp(block.timestamp + WIN);
        vm.prank(reviewer);
        vm.expectRevert(AgentJobV2.PastDeadline.selector);
        ev.resolve(id, true, keccak256("late"));
        job.claimRefund(id);
        assertEq(job.credit(client), 1 ether);
    }

    function test_lateObjectionRejected() public {
        uint256 id = _open(4);
        _submit(id, files);
        vm.warp(block.timestamp + OBJ);
        vm.prank(client);
        vm.expectRevert(Eval.ObjectionPeriodOver.selector);
        ev.object(id, keccak256("late"));
    }

    function test_onlyClientObjects() public {
        uint256 id = _open(4);
        _submit(id, files);
        vm.prank(stranger);
        vm.expectRevert(Eval.NotClient.selector);
        ev.object(id, keccak256("o"));
        vm.prank(provider);
        vm.expectRevert(Eval.NotClient.selector);
        ev.object(id, keccak256("o"));
    }

    function test_reviewerCannotTouchUnobjectedJob() public {
        uint256 id = _open(4);
        _submit(id, files);
        vm.prank(reviewer);
        vm.expectRevert(Eval.NoObjection.selector);
        ev.resolve(id, false, keccak256("r"));
    }

    function test_incompletePackageNeverReleases_clientRefundedAtWindowEnd() public {
        uint256 id = _open(5); // checklist has 5 items, contractor submits 4
        _submit(id, files);
        vm.warp(block.timestamp + OBJ);
        assertFalse(ev.packageComplete(id, checklist, files));
        vm.expectRevert(Eval.IncompletePackage.selector);
        ev.releaseOnSilence(id, checklist, files);
        vm.warp(block.timestamp + WIN);
        job.claimRefund(id);
        assertEq(job.credit(client), 1 ether);
    }

    function test_emptyItemIsIncomplete() public {
        uint256 id = _open(4);
        bytes32[] memory fh = files;
        fh[2] = bytes32(0);
        _submit(id, fh);
        vm.warp(block.timestamp + OBJ);
        vm.expectRevert(Eval.IncompletePackage.selector);
        ev.releaseOnSilence(id, checklist, fh);
    }

    function test_wrongPreimageOrClaimedHashRejected() public {
        uint256 id = _open(4);
        // claimed hash only (no bytes): not hashed on-chain -> not releasable
        bytes32 d = sha256(abi.encode(checklist, files));
        vm.prank(provider);
        job.submit(id, d, "");
        vm.warp(block.timestamp + OBJ);
        vm.expectRevert(Eval.IncompletePackage.selector);
        ev.releaseOnSilence(id, checklist, files);
    }

    function test_otherChecklistRejected() public {
        uint256 id = _open(4);
        bytes memory m = abi.encode(keccak256("other checklist"), files);
        bytes32 d = sha256(m);
        vm.prank(provider);
        job.submit(id, d, m);
        vm.warp(block.timestamp + OBJ);
        vm.expectRevert(Eval.IncompletePackage.selector);
        ev.releaseOnSilence(id, keccak256("other checklist"), files);
    }

    function test_noDoubleObjection() public {
        uint256 id = _open(4);
        _submit(id, files);
        vm.startPrank(client);
        ev.object(id, keccak256("a"));
        vm.expectRevert(Eval.AlreadyObjected.selector);
        ev.object(id, keccak256("b"));
        vm.stopPrank();
    }

    function test_jobOfAnotherEvaluator() public {
        vm.prank(client);
        uint256 id = job.createJob{value: 1}(provider, stranger, bytes32(0), uint64(block.timestamp + 1 days));
        vm.expectRevert(Eval.NotOurJob.selector);
        ev.object(id, keccak256("o"));
    }

    function test_constructorGuards() public {
        vm.expectRevert(Eval.BadPeriod.selector);
        new Eval(address(job), reviewer, WIN);
        vm.expectRevert(Eval.BadPeriod.selector);
        new Eval(address(job), reviewer, 0);
        vm.expectRevert(Eval.ZeroAddress.selector);
        new Eval(address(job), address(0), OBJ);
    }

    function test_withdrawAfterRelease() public {
        uint256 id = _open(4);
        _submit(id, files);
        vm.warp(block.timestamp + OBJ);
        ev.releaseOnSilence(id, checklist, files);
        uint256 before = provider.balance;
        vm.prank(provider);
        job.withdraw();
        assertEq(provider.balance - before, 1 ether);
    }

    function testFuzz_releaseOnlyAfterPeriod(uint64 dt) public {
        uint256 id = _open(4);
        _submit(id, files);
        dt = uint64(bound(dt, 0, WIN - 1));
        vm.warp(block.timestamp + dt);
        if (dt < OBJ) {
            vm.expectRevert(Eval.ObjectionPeriodRunning.selector);
            ev.releaseOnSilence(id, checklist, files);
        } else {
            ev.releaseOnSilence(id, checklist, files);
            assertEq(job.credit(provider), 1 ether);
        }
    }
}
