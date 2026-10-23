// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PredgeRefundArbiter} from "../../../contracts/PredgeRefundArbiter.sol";
import {MockRefundProtocol} from "../../../contracts/MockRefundProtocol.sol";

contract ArbiterHandler is Test {
    PredgeRefundArbiter public arb;
    MockRefundProtocol public rp;
    address public op;
    address[3] internal parties = [address(0xA11CE), address(0xB0B), address(0xCA401)];
    uint256 internal constant PIDS = 8;

    uint256 public rulings;
    uint256 public refunds;
    uint256 public totalIn;
    uint256 public totalOut;
    mapping(uint256 => uint256) public exits;
    bool public earlyReclaim;
    bool public unauthorizedSucceeded;
    bool public filingChanged;
    mapping(uint256 => mapping(address => bytes32)) public firstFiling;

    constructor(PredgeRefundArbiter a, MockRefundProtocol r, address o) {
        arb = a;
        rp = r;
        op = o;
    }

    function file(uint256 pSeed, uint256 pid, bytes32 h) external {
        address p = parties[pSeed % 3];
        pid = pid % PIDS;
        vm.prank(p);
        try arb.fileEvidence(pid, h) {
            if (firstFiling[pid][p] != bytes32(0)) filingChanged = true;
            firstFiling[pid][p] = h;
        } catch {}
    }

    function rule(uint256 pid, uint256 pSeed, bool refund, uint96 amt, bool citeFiled, bytes32 random) external {
        pid = pid % PIDS;
        address p = parties[pSeed % 3];
        bytes32 h = citeFiled ? arb.filedEvidence(pid, p) : random;
        amt = uint96(bound(amt, 0, 5 ether));
        vm.deal(op, op.balance + amt);
        vm.prank(op);
        try arb.rule{value: amt}(pid, p, h, refund ? PredgeRefundArbiter.Direction.Refund : PredgeRefundArbiter.Direction.Release) {
            rulings++;
            if (refund) refunds++;
            totalIn += amt;
        } catch {}
    }

    function challenge(uint256 pid, address who) external {
        pid = pid % PIDS;
        if (who.code.length > 0 || uint160(who) < 0x10000) return;
        (, , uint96 b, , , ) = arb.rulingOf(pid);
        vm.prank(who);
        try arb.challenge(pid) {
            exits[pid]++;
            totalOut += b;
        } catch {}
    }

    function reclaim(uint256 pid) external {
        pid = pid % PIDS;
        (, , uint96 b, uint64 at, , ) = arb.rulingOf(pid);
        vm.prank(op);
        try arb.reclaim(pid) {
            if (block.timestamp < uint256(at) + arb.challengeWindow()) earlyReclaim = true;
            exits[pid]++;
            totalOut += b;
        } catch {}
    }

    function intruder(uint256 pid, address who) external {
        pid = pid % PIDS;
        // skip the operator, the owner (the test contract) and any contract: vm.deal on the
        // arbiter itself would fake a balance change
        if (who == op || who == arb.owner() || who.code.length > 0 || uint160(who) < 0x10000) return;
        vm.deal(who, 1 ether);
        vm.startPrank(who);
        try arb.reclaim(pid) {
            unauthorizedSucceeded = true;
        } catch {}
        try arb.rule{value: 1 ether}(pid, parties[0], arb.filedEvidence(pid, parties[0]), PredgeRefundArbiter.Direction.Refund) {
            unauthorizedSucceeded = true;
        } catch {}
        try arb.setParams(0, 0) {
            unauthorizedSucceeded = true;
        } catch {}
        try arb.setOperator(who) {
            unauthorizedSucceeded = true;
        } catch {}
        vm.stopPrank();
    }

    function warp(uint32 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 3 days));
    }
}

contract PredgeRefundArbiterInvariantTest is Test {
    PredgeRefundArbiter arb;
    MockRefundProtocol rp;
    ArbiterHandler h;
    address op = address(0x0BE7);

    function setUp() public {
        vm.warp(1_700_000_000);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        rp = new MockRefundProtocol(predicted);
        arb = new PredgeRefundArbiter(address(rp), op, 1 days, 0.001 ether);
        h = new ArbiterHandler(arb, rp, op);
        targetContract(address(h));
    }

    function invariant_balanceEqualsUnsettledBonds() public view {
        uint256 sum;
        for (uint256 pid; pid < 8; pid++) {
            (, , uint96 b, , , bool settled) = arb.rulingOf(pid);
            if (settled) assertEq(b, 0);
            else sum += b;
        }
        assertEq(address(arb).balance, sum);
        assertEq(h.totalIn(), h.totalOut() + address(arb).balance);
    }

    /// RA-01: with write-once filings and rule() requiring a byte-exact citation, no ruling is
    /// ever slashable.
    function invariant_noRulingEverSlashed() public view {
        assertEq(arb.slashCount(), 0);
        for (uint256 pid; pid < 8; pid++) assertFalse(arb.wouldSlash(pid));
    }

    function invariant_countersMatch() public view {
        assertEq(arb.rulingCount(), h.rulings());
        assertEq(rp.refundCount(), h.refunds());
    }

    function invariant_bondExitsAtMostOnce() public view {
        for (uint256 pid; pid < 8; pid++) assertLe(h.exits(pid), 1);
    }

    function invariant_noReclaimInsideWindow() public view {
        assertFalse(h.earlyReclaim());
    }

    function invariant_filingsWriteOnce() public view {
        assertFalse(h.filingChanged());
    }

    function invariant_onlyOperatorAndOwnerAct() public view {
        assertFalse(h.unauthorizedSucceeded());
    }
}
