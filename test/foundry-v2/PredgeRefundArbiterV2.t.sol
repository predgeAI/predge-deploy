// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PredgeRefundArbiterV2} from "../../contracts/v2/PredgeRefundArbiterV2.sol";
import {MockRefundProtocolV2} from "../../contracts/v2/mocks/MockRefundProtocolV2.sol";
import {Owned2Step, Operated} from "../../contracts/v2/access/PredgeAccess.sol";
import {PullCredit} from "../../contracts/v2/access/PullCredit.sol";

abstract contract ArbiterBase is Test {
    address internal safe = makeAddr("safe");
    address internal op = makeAddr("operator");
    address internal payer = makeAddr("payer");
    address internal payee = makeAddr("payee");
    address internal stranger = makeAddr("stranger");

    uint64 internal constant WINDOW = 1 days;
    uint256 internal constant MIN_BOND = 1e15;
    uint16 internal constant BPS = 500; // 5% of the payment

    PredgeRefundArbiterV2 internal arb;
    MockRefundProtocolV2 internal rp;

    bytes32 internal constant EV_PAYER = keccak256("payer evidence");
    bytes32 internal constant EV_PAYEE = keccak256("payee evidence");
    bytes32 internal constant EV_COUNTER = keccak256("counter evidence");

    function _deployArbiter() internal {
        vm.warp(1_760_000_000);
        // The mock needs the arbiter address and vice versa: predict the arbiter (next CREATE after the mock).
        uint256 n = vm.getNonce(address(this));
        address predicted = vm.computeCreateAddress(address(this), n + 1);
        rp = new MockRefundProtocolV2(predicted);
        arb = new PredgeRefundArbiterV2(safe, op, address(rp), WINDOW, MIN_BOND, BPS);
        assertEq(address(arb), predicted);
        vm.deal(op, 1_000 ether);
        vm.deal(payer, 10 ether);
        vm.deal(payee, 10 ether);
    }

    function _pay(uint256 amount) internal returns (uint256 pid) {
        pid = rp.recordPayment(payer, payee, amount, block.timestamp + 30 days);
    }

    function _file(uint256 pid) internal {
        vm.prank(payer);
        arb.fileEvidence(pid, EV_PAYER);
        vm.prank(payee);
        arb.fileEvidence(pid, EV_PAYEE);
    }

    function _rule(uint256 pid, address from, bytes32 ev, PredgeRefundArbiterV2.Direction d, uint256 value) internal {
        vm.prank(op);
        arb.rule{value: value}(pid, from, ev, d);
    }

    function _status(uint256 pid) internal view returns (PredgeRefundArbiterV2.Status st) {
        st = arb.rulings(pid).status;
    }
}

contract PredgeRefundArbiterV2Test is ArbiterBase {
    PredgeRefundArbiterV2.Direction internal constant REFUND = PredgeRefundArbiterV2.Direction.Refund;
    PredgeRefundArbiterV2.Direction internal constant RELEASE = PredgeRefundArbiterV2.Direction.Release;
    PredgeRefundArbiterV2.Direction internal constant NONE = PredgeRefundArbiterV2.Direction.None;

    event EvidenceFiled(uint256 indexed paymentID, address indexed party, bytes32 evidenceHash);
    event Ruled(uint256 indexed paymentID, address indexed staker, address indexed evidenceFrom, bytes32 evidenceHash, PredgeRefundArbiterV2.Direction direction, uint256 bond, uint64 windowEnd);
    event Disputed(uint256 indexed paymentID, address indexed disputer, bytes32 counterEvidence, uint64 expiresAt);
    event Finalized(uint256 indexed paymentID, address indexed staker, PredgeRefundArbiterV2.Direction direction, uint256 bond);
    event Overturned(uint256 indexed paymentID, address indexed harmed, PredgeRefundArbiterV2.Direction finalDirection, uint256 bond);
    event Voided(uint256 indexed paymentID, address indexed staker, uint256 bond);
    event ParamsUpdated(uint64 challengeWindow, uint256 minBond, uint16 bondBps);

    function setUp() public {
        _deployArbiter();
    }

    /// @dev `new` under `vm.expectRevert` ends the test early in forge; deploy through an external call instead.
    function mk(address o, address p, address r, uint64 w, uint256 m, uint16 b) external returns (address) {
        return address(new PredgeRefundArbiterV2(o, p, r, w, m, b));
    }

    function test_constructor_and_params() public {
        assertEq(arb.owner(), safe);
        assertEq(arb.operator(), op);
        assertEq(address(arb.refundProtocol()), address(rp));
        vm.expectRevert(Owned2Step.ZeroAddress.selector);
        this.mk(safe, op, address(0), WINDOW, MIN_BOND, BPS);
        vm.expectRevert(PredgeRefundArbiterV2.BadParams.selector);
        this.mk(safe, op, address(rp), 1 minutes, MIN_BOND, BPS);
        vm.expectRevert(PredgeRefundArbiterV2.BadParams.selector);
        this.mk(safe, op, address(rp), 31 days, MIN_BOND, BPS);
        vm.expectRevert(PredgeRefundArbiterV2.BadParams.selector);
        this.mk(safe, op, address(rp), WINDOW, 0, BPS);
        vm.expectRevert(PredgeRefundArbiterV2.BadParams.selector);
        this.mk(safe, op, address(rp), WINDOW, MIN_BOND, 10_001);

        vm.prank(op);
        vm.expectRevert(Owned2Step.NotOwner.selector);
        arb.setParams(2 days, 1, 1);
        vm.startPrank(safe);
        vm.expectRevert(PredgeRefundArbiterV2.BadParams.selector);
        arb.setParams(1 minutes, 5, 1000);
        vm.expectRevert(PredgeRefundArbiterV2.BadParams.selector);
        arb.setParams(2 days, 5, 10_001);
        vm.stopPrank();
        vm.prank(safe);
        vm.expectEmit(false, false, false, true);
        emit ParamsUpdated(2 days, 5, 1000);
        arb.setParams(2 days, 5, 1000);
        assertEq(arb.requiredBond(1 ether), 0.1 ether);
        assertEq(arb.requiredBond(1), 5);
    }

    event LockupForwarded(address indexed recipient, uint256 lockupSeconds);

    function test_setLockupSeconds_isOwnerOnlyPassThrough() public {
        uint256 ok = WINDOW + arb.RESOLUTION_TIMEOUT() + 1;
        vm.prank(op);
        vm.expectRevert(Owned2Step.NotOwner.selector);
        arb.setLockupSeconds(payee, ok);
        vm.expectEmit(true, false, false, true);
        emit LockupForwarded(payee, ok);
        vm.prank(safe);
        arb.setLockupSeconds(payee, ok);
        assertEq(rp.lockupSeconds(payee), ok);
    }

    /// @dev Olympix 5.3.12: the forwarded lockup is bounded below by window + resolution timeout and above by MAX_LOCKUP.
    function test_setLockupSeconds_bounded() public {
        uint256 floor_ = uint256(WINDOW) + 14 days; // literal: also pins RESOLUTION_TIMEOUT
        vm.startPrank(safe);
        vm.expectRevert(PredgeRefundArbiterV2.BadParams.selector);
        arb.setLockupSeconds(payee, 0);
        vm.expectRevert(PredgeRefundArbiterV2.BadParams.selector);
        arb.setLockupSeconds(payee, floor_);
        arb.setLockupSeconds(payee, floor_ + 1);
        arb.setLockupSeconds(payee, 365 days);
        assertEq(arb.MAX_LOCKUP(), 365 days);
        vm.expectRevert(PredgeRefundArbiterV2.BadParams.selector);
        arb.setLockupSeconds(payee, 365 days + 1);
        vm.expectRevert(PredgeRefundArbiterV2.BadParams.selector);
        arb.setLockupSeconds(payee, type(uint256).max);
        // the floor follows the current challenge window
        arb.setParams(2 days, MIN_BOND, BPS);
        vm.expectRevert(PredgeRefundArbiterV2.BadParams.selector);
        arb.setLockupSeconds(payee, floor_ + 1);
        arb.setLockupSeconds(payee, floor_ + 1 days + 1);
        vm.stopPrank();
        assertEq(rp.lockupSeconds(payee), floor_ + 1 days + 1);
    }

    // ---- evidence ----

    function test_fileEvidence_onlyPartiesWriteOnce() public {
        uint256 pid = _pay(1 ether);
        vm.expectEmit(true, true, false, true);
        emit EvidenceFiled(pid, payer, EV_PAYER);
        vm.prank(payer);
        arb.fileEvidence(pid, EV_PAYER);
        assertEq(arb.filedEvidence(pid, payer), EV_PAYER);

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(PredgeRefundArbiterV2.EvidenceAlreadyFiled.selector, pid, payer));
        arb.fileEvidence(pid, EV_COUNTER);
        vm.prank(stranger);
        vm.expectRevert(PredgeRefundArbiterV2.NotAParty.selector);
        arb.fileEvidence(pid, EV_COUNTER);
        vm.prank(op);
        vm.expectRevert(PredgeRefundArbiterV2.NotAParty.selector); // the arbiter cannot manufacture the record
        arb.fileEvidence(pid, EV_COUNTER);
        vm.prank(payee);
        vm.expectRevert(PredgeRefundArbiterV2.ZeroHash.selector);
        arb.fileEvidence(pid, bytes32(0));
        vm.prank(payee);
        vm.expectRevert(PredgeRefundArbiterV2.NotAParty.selector); // payment that does not exist: no party
        arb.fileEvidence(999, EV_PAYEE);
    }

    function test_fileEvidence_closedOnceRuled() public {
        uint256 pid = _pay(1 ether);
        vm.prank(payer);
        arb.fileEvidence(pid, EV_PAYER);
        _rule(pid, payer, EV_PAYER, REFUND, 1 ether);
        vm.prank(payee);
        vm.expectRevert(PredgeRefundArbiterV2.EvidenceClosed.selector);
        arb.fileEvidence(pid, EV_PAYEE);
    }

    // ---- rule ----

    function test_rule_recordsAndExecutesNothing() public {
        uint256 pid = _pay(1 ether);
        _file(pid);
        uint256 bondNeeded = arb.requiredBond(1 ether); // 5% = 0.05 ether
        assertEq(bondNeeded, 0.05 ether);
        vm.expectEmit(true, true, true, true);
        emit Ruled(pid, op, payer, EV_PAYER, REFUND, bondNeeded, uint64(block.timestamp) + WINDOW);
        _rule(pid, payer, EV_PAYER, REFUND, bondNeeded);
        assertEq(rp.refundCount(), 0, "optimistic: nothing executes inside rule()");
        assertEq(uint8(_status(pid)), uint8(PredgeRefundArbiterV2.Status.Ruled));
        assertEq(arb.totalBonded(), bondNeeded);
        assertEq(arb.rulingCount(), 1);
        assertEq(arb.harmedParty(pid), payee);
        PredgeRefundArbiterV2.Ruling memory r = arb.rulings(pid);
        assertEq(r.evidenceFrom, payer);
        assertEq(r.evidenceHash, EV_PAYER);
        assertEq(r.staker, op);
        assertEq(r.payer, payer);
        assertEq(r.payee, payee);
        assertEq(r.bond, bondNeeded);
        assertEq(r.window, WINDOW);
        assertEq(r.ruledAt, block.timestamp);
        assertEq(r.expiresAt, block.timestamp + WINDOW + arb.RESOLUTION_TIMEOUT());
        assertEq(uint8(r.direction), uint8(REFUND));
    }

    function test_recordsAreComplete_afterEachTerminalPath() public {
        // dispute + overturn
        uint256 p1 = _pay(1 ether);
        _file(p1);
        _rule(p1, payer, EV_PAYER, REFUND, 1 ether);
        vm.prank(payee);
        arb.dispute(p1, EV_COUNTER);
        assertEq(arb.rulings(p1).counterEvidence, EV_COUNTER);
        vm.prank(safe);
        arb.resolve(p1, RELEASE);
        assertEq(uint8(arb.rulings(p1).status), uint8(PredgeRefundArbiterV2.Status.Overturned));
        assertEq(arb.rulings(p1).bond, 0);
        // finalize
        uint256 p2 = _pay(1 ether);
        _file(p2);
        _rule(p2, payer, EV_PAYER, RELEASE, 1 ether);
        // expire
        uint256 p3 = _pay(1 ether);
        _file(p3);
        _rule(p3, payee, EV_PAYEE, RELEASE, 1 ether);
        vm.warp(block.timestamp + WINDOW);
        arb.finalize(p2);
        assertEq(arb.rulings(p2).bond, 0);
        assertEq(uint8(arb.rulings(p2).status), uint8(PredgeRefundArbiterV2.Status.Finalized));
        vm.warp(block.timestamp + arb.RESOLUTION_TIMEOUT());
        arb.expire(p3);
        assertEq(arb.rulings(p3).bond, 0);
        assertEq(uint8(arb.rulings(p3).status), uint8(PredgeRefundArbiterV2.Status.Voided));
        // a ruling that is upheld after a dispute also zeroes the bond
        uint256 p4 = _pay(1 ether);
        _file(p4);
        _rule(p4, payer, EV_PAYER, REFUND, 1 ether);
        vm.prank(payee);
        arb.dispute(p4, EV_COUNTER);
        vm.prank(safe);
        arb.resolve(p4, REFUND);
        assertEq(arb.rulings(p4).bond, 0);
    }

    function test_rule_reverts() public {
        uint256 pid = _pay(1 ether);
        _file(pid);
        uint256 need = arb.requiredBond(1 ether);
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        vm.expectRevert(Operated.NotOperator.selector);
        arb.rule{value: need}(pid, payer, EV_PAYER, REFUND);

        vm.startPrank(op);
        vm.expectRevert(PredgeRefundArbiterV2.ZeroHash.selector);
        arb.rule{value: need}(pid, payer, bytes32(0), REFUND);
        vm.expectRevert(PredgeRefundArbiterV2.BadDirection.selector);
        arb.rule{value: need}(pid, payer, EV_PAYER, NONE);
        vm.expectRevert(PredgeRefundArbiterV2.UnknownPayment.selector);
        arb.rule{value: need}(777, payer, EV_PAYER, REFUND);
        vm.expectRevert(PredgeRefundArbiterV2.NotAParty.selector); // evidence from someone who is not a party
        arb.rule{value: need}(pid, stranger, EV_PAYER, REFUND);
        vm.expectRevert(abi.encodeWithSelector(PredgeRefundArbiterV2.NoEvidenceFiled.selector, pid, payer));
        arb.rule{value: need}(pid, payer, EV_PAYEE, REFUND); // cites a hash the payer never filed
        vm.expectRevert(abi.encodeWithSelector(PredgeRefundArbiterV2.BondTooSmall.selector, need));
        arb.rule{value: need - 1}(pid, payer, EV_PAYER, REFUND);
        arb.rule{value: need}(pid, payer, EV_PAYER, REFUND);
        vm.expectRevert(abi.encodeWithSelector(PredgeRefundArbiterV2.AlreadyRuled.selector, pid));
        arb.rule{value: need}(pid, payer, EV_PAYER, REFUND);
        vm.stopPrank();
    }

    function test_rule_operatorCannotBeAParty() public {
        uint256 pid = rp.recordPayment(op, payee, 1 ether, block.timestamp + 30 days);
        vm.prank(op);
        arb.fileEvidence(pid, EV_PAYER); // the operator is the payer: it may file as a party...
        vm.prank(op);
        vm.expectRevert(PredgeRefundArbiterV2.OperatorIsParty.selector); // ...but cannot then rule on its own payment
        arb.rule{value: 1 ether}(pid, op, EV_PAYER, REFUND);
        uint256 pid2 = rp.recordPayment(payer, op, 1 ether, block.timestamp + 30 days);
        vm.prank(op);
        vm.expectRevert(PredgeRefundArbiterV2.OperatorIsParty.selector);
        arb.rule{value: 1 ether}(pid2, payer, EV_PAYER, REFUND);
    }

    /// @dev Olympix 5.2.1: the whole ruling (window + full resolution period) must end before release, for
    ///      BOTH directions (a Release can be overturned into a Refund). Boundary is exclusive.
    function test_rule_needsLockupBeyondWindowAndResolution() public {
        uint256 edge = block.timestamp + WINDOW + 14 days; // literal 14 days pins RESOLUTION_TIMEOUT
        uint256 pid = rp.recordPayment(payer, payee, 1 ether, edge);
        _file(pid);
        vm.startPrank(op);
        vm.expectRevert(PredgeRefundArbiterV2.LockupTooShort.selector);
        arb.rule{value: 1 ether}(pid, payer, EV_PAYER, REFUND);
        vm.expectRevert(PredgeRefundArbiterV2.LockupTooShort.selector);
        arb.rule{value: 1 ether}(pid, payee, EV_PAYEE, RELEASE);
        vm.stopPrank();
        uint256 pid2 = rp.recordPayment(payer, payee, 1 ether, edge + 1);
        _file(pid2);
        _rule(pid2, payer, EV_PAYER, REFUND, 1 ether);
        uint256 pid3 = rp.recordPayment(payer, payee, 1 ether, edge + 1);
        _file(pid3);
        _rule(pid3, payee, EV_PAYEE, RELEASE, 1 ether);
        assertEq(arb.RESOLUTION_TIMEOUT(), 14 days);
    }

    function test_bondScalesWithPayment() public {
        uint256 pid = _pay(1000 ether);
        _file(pid);
        assertEq(arb.requiredBond(1000 ether), 50 ether);
        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(PredgeRefundArbiterV2.BondTooSmall.selector, 50 ether));
        arb.rule{value: MIN_BOND}(pid, payer, EV_PAYER, REFUND);
    }

    // ---- undisputed path ----

    function test_finalize_refund_afterWindow() public {
        uint256 pid = _pay(1 ether);
        _file(pid);
        uint256 need = arb.requiredBond(1 ether);
        _rule(pid, payer, EV_PAYER, REFUND, need);
        vm.expectRevert(PredgeRefundArbiterV2.WindowOpen.selector);
        arb.finalize(pid);
        vm.warp(block.timestamp + WINDOW);
        vm.expectEmit(true, true, false, true);
        emit Finalized(pid, op, REFUND, need);
        vm.prank(stranger);
        arb.finalize(pid);
        assertEq(rp.refundCount(), 1);
        assertEq(arb.credit(op), need);
        assertEq(arb.totalBonded(), 0);
        vm.expectRevert(PredgeRefundArbiterV2.BadStatus.selector);
        arb.finalize(pid);
    }

    function test_finalize_release_executesNothing() public {
        uint256 pid = _pay(1 ether);
        _file(pid);
        _rule(pid, payee, EV_PAYEE, RELEASE, MIN_BOND + 1 ether);
        vm.warp(block.timestamp + WINDOW);
        arb.finalize(pid);
        assertEq(rp.refundCount(), 0);
        assertEq(arb.credit(op), MIN_BOND + 1 ether);
    }

    function test_finalize_revertsIfRefundProtocolReverts_thenExpireVoids() public {
        uint256 pid = _pay(1 ether);
        _file(pid);
        uint256 need = arb.requiredBond(1 ether);
        _rule(pid, payer, EV_PAYER, REFUND, need);
        vm.warp(block.timestamp + WINDOW);
        vm.mockCallRevert(address(rp), abi.encodeWithSelector(MockRefundProtocolV2.refundByArbiter.selector, pid), "rp down");
        vm.expectRevert("rp down");
        arb.finalize(pid);
        vm.expectRevert(PredgeRefundArbiterV2.NotExpired.selector);
        arb.expire(pid);
        vm.warp(block.timestamp + arb.RESOLUTION_TIMEOUT());
        vm.expectEmit(true, true, false, true);
        emit Voided(pid, op, need);
        arb.expire(pid);
        assertEq(arb.credit(op), need, "bond is never stuck");
        assertEq(rp.refundCount(), 0, "voided: nothing executed");
        assertEq(uint8(_status(pid)), uint8(PredgeRefundArbiterV2.Status.Voided));
    }

    // ---- dispute path (H-03) ----

    function test_dispute_freezesAndOwnerOverturnsRefund() public {
        uint256 pid = _pay(1 ether);
        _file(pid);
        uint256 need = arb.requiredBond(1 ether);
        _rule(pid, payer, EV_PAYER, REFUND, need); // harms the payee
        vm.expectEmit(true, true, false, true);
        emit Disputed(pid, payee, EV_COUNTER, uint64(block.timestamp) + arb.RESOLUTION_TIMEOUT());
        vm.prank(payee);
        arb.dispute(pid, EV_COUNTER);
        assertEq(uint8(_status(pid)), uint8(PredgeRefundArbiterV2.Status.Disputed));

        vm.warp(block.timestamp + WINDOW);
        vm.expectRevert(PredgeRefundArbiterV2.BadStatus.selector); // frozen: cannot finalize
        arb.finalize(pid);

        vm.expectEmit(true, true, false, true);
        emit Overturned(pid, payee, RELEASE, need);
        vm.prank(safe);
        arb.resolve(pid, RELEASE);
        assertEq(arb.credit(payee), need, "operator's bond goes to the harmed party");
        assertEq(arb.credit(op), 0);
        assertEq(rp.refundCount(), 0);
        assertEq(arb.overturnCount(), 1);
        assertEq(arb.totalBonded(), 0);
    }

    function test_dispute_ownerUpholds() public {
        uint256 pid = _pay(1 ether);
        _file(pid);
        uint256 need = arb.requiredBond(1 ether);
        _rule(pid, payer, EV_PAYER, REFUND, need);
        vm.prank(payee);
        arb.dispute(pid, EV_COUNTER);
        vm.prank(safe);
        arb.resolve(pid, REFUND);
        assertEq(arb.credit(op), need);
        assertEq(rp.refundCount(), 1);
        assertEq(uint8(_status(pid)), uint8(PredgeRefundArbiterV2.Status.Finalized));
    }

    function test_dispute_ownerOverturnsReleaseIntoRefund() public {
        uint256 pid = _pay(1 ether);
        _file(pid);
        uint256 need = arb.requiredBond(1 ether);
        _rule(pid, payee, EV_PAYEE, RELEASE, need); // harms the payer
        assertEq(arb.harmedParty(pid), payer);
        vm.prank(payer);
        arb.dispute(pid, EV_COUNTER);
        vm.prank(safe);
        arb.resolve(pid, REFUND);
        assertEq(arb.credit(payer), need);
        assertEq(rp.refundCount(), 1);
    }

    function test_dispute_reverts() public {
        uint256 pid = _pay(1 ether);
        _file(pid);
        vm.prank(payee);
        vm.expectRevert(PredgeRefundArbiterV2.ZeroHash.selector);
        arb.dispute(pid, bytes32(0));
        vm.prank(payee);
        vm.expectRevert(PredgeRefundArbiterV2.BadStatus.selector); // not ruled yet
        arb.dispute(pid, EV_COUNTER);
        _rule(pid, payer, EV_PAYER, REFUND, MIN_BOND + 1 ether);
        vm.prank(payer); // the party the ruling FAVOURS cannot freeze it
        vm.expectRevert(PredgeRefundArbiterV2.NotHarmedParty.selector);
        arb.dispute(pid, EV_COUNTER);
        vm.prank(stranger);
        vm.expectRevert(PredgeRefundArbiterV2.NotHarmedParty.selector);
        arb.dispute(pid, EV_COUNTER);
        vm.warp(block.timestamp + WINDOW);
        vm.prank(payee);
        vm.expectRevert(PredgeRefundArbiterV2.WindowClosed.selector);
        arb.dispute(pid, EV_COUNTER);
    }

    function test_resolve_reverts() public {
        uint256 pid = _pay(1 ether);
        _file(pid);
        _rule(pid, payer, EV_PAYER, REFUND, MIN_BOND + 1 ether);
        vm.startPrank(safe);
        vm.expectRevert(PredgeRefundArbiterV2.BadDirection.selector);
        arb.resolve(pid, NONE);
        vm.expectRevert(PredgeRefundArbiterV2.BadStatus.selector); // not disputed
        arb.resolve(pid, REFUND);
        vm.stopPrank();
        vm.prank(payee);
        arb.dispute(pid, EV_COUNTER);
        vm.prank(op);
        vm.expectRevert(Owned2Step.NotOwner.selector);
        arb.resolve(pid, RELEASE);
        vm.warp(block.timestamp + arb.RESOLUTION_TIMEOUT());
        vm.prank(safe);
        vm.expectRevert(PredgeRefundArbiterV2.ResolutionExpired.selector);
        arb.resolve(pid, RELEASE);
        arb.expire(pid); // an idle owner cannot freeze the bond forever
        assertEq(arb.credit(op), MIN_BOND + 1 ether);
    }

    function test_expire_badStatus() public {
        vm.expectRevert(PredgeRefundArbiterV2.BadStatus.selector);
        arb.expire(1);
    }

    function test_harmedParty_unruledIsZero() public view {
        assertEq(arb.harmedParty(5), address(0));
    }

    function test_paramChangeIsNotRetroactive() public {
        uint256 pid = _pay(1 ether);
        _file(pid);
        _rule(pid, payer, EV_PAYER, REFUND, MIN_BOND + 1 ether);
        vm.prank(safe);
        arb.setParams(30 days, 1e18, 10_000); // owner tries to stretch the window / raise the bond afterwards
        vm.warp(block.timestamp + WINDOW);
        arb.finalize(pid); // still the old 1 day window
        assertEq(arb.credit(op), MIN_BOND + 1 ether);
    }

    function test_bondWithdraw() public {
        uint256 pid = _pay(1 ether);
        _file(pid);
        _rule(pid, payer, EV_PAYER, RELEASE, 2 ether);
        vm.warp(block.timestamp + WINDOW);
        arb.finalize(pid);
        uint256 b = op.balance;
        vm.prank(op);
        arb.withdraw();
        assertEq(op.balance, b + 2 ether);
        vm.prank(op);
        vm.expectRevert(PullCredit.NothingToWithdraw.selector);
        arb.withdraw();
    }

    function testFuzz_bondAlwaysAtLeastScaledAndFloor(uint128 amount, uint16 bps, uint128 floor_) public {
        bps = uint16(bound(bps, 0, 10_000));
        floor_ = uint128(bound(floor_, 1, 1e24));
        vm.prank(safe);
        arb.setParams(WINDOW, floor_, bps);
        uint256 need = arb.requiredBond(amount);
        assertGe(need, floor_);
        assertGe(need * 10_000, uint256(amount) * bps);
        assertLe(need, uint256(floor_) + uint256(amount)); // never more than floor + amount at bps <= 100%
    }
}
