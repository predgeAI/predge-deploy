// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, stdStorage, StdStorage, stdError} from "forge-std/Test.sol";
import {PredgeRefundArbiter} from "../../../contracts/PredgeRefundArbiter.sol";
import {MockRefundProtocol} from "../../../contracts/MockRefundProtocol.sol";
import {ToggleReceiver, Reenterer} from "../utils/Actors.sol";

contract PredgeRefundArbiterTest is Test {
    using stdStorage for StdStorage;

    PredgeRefundArbiter arb;
    MockRefundProtocol rp;
    address owner = makeAddr("owner");
    address op = makeAddr("operator");
    address op2 = makeAddr("operator2");
    address payer = makeAddr("payer");
    address merchant = makeAddr("merchant");
    address anyone = makeAddr("anyone");
    uint64 constant WINDOW = 1 days;
    uint96 constant MIN = 0.001 ether;
    bytes32 constant EV = keccak256("payer evidence"); // keccak, not sha256: a precompile call would consume vm.prank
    uint256 constant PID = 42;

    event OperatorUpdated(address indexed previousOperator, address indexed newOperator);
    event EvidenceFiled(uint256 indexed paymentID, address indexed party, bytes32 evidenceHash);
    event Committed(uint256 indexed paymentID, bytes32 evidenceHash, address evidenceFrom, PredgeRefundArbiter.Direction direction, uint96 bond);
    event Ruled(uint256 indexed paymentID, PredgeRefundArbiter.Direction direction, bytes32 evidenceHash, uint64 ruledAt);
    event Slashed(uint256 indexed paymentID, address indexed challenger, uint96 bond, bytes32 committed, bytes32 delivered);
    event Reclaimed(uint256 indexed paymentID, uint96 bond);
    event ParamsUpdated(uint64 challengeWindow, uint96 minBond);

    function setUp() public {
        vm.warp(1_700_000_000);
        // same construction order as the canonical plan: protocol points at the arbiter's future address
        address predicted = vm.computeCreateAddress(owner, vm.getNonce(owner) + 1);
        vm.startPrank(owner);
        rp = new MockRefundProtocol(predicted);
        arb = new PredgeRefundArbiter(address(rp), op, WINDOW, MIN);
        vm.stopPrank();
        assertEq(address(arb), predicted);
        vm.deal(op, 100 ether);
    }

    function _file(address party, uint256 pid, bytes32 h) internal {
        vm.prank(party);
        arb.fileEvidence(pid, h);
    }

    function _rule(uint256 pid, PredgeRefundArbiter.Direction d, uint256 bond) internal {
        vm.prank(op);
        arb.rule{value: bond}(pid, payer, EV, d);
    }

    function _ruled(PredgeRefundArbiter.Direction d) internal {
        _file(payer, PID, EV);
        _rule(PID, d, MIN);
    }

    /// Tamper with the write-once filing via raw storage, to reach the (otherwise unreachable)
    /// slash path. See finding RA-01.
    function _tamperFiling(uint256 pid, address party, bytes32 h) internal {
        stdstore.target(address(arb)).sig("filedEvidence(uint256,address)").with_key(pid).with_key(party).checked_write(h);
    }

    // ───────────── constructor / admin ─────────────
    function test_constructor() public view {
        assertEq(arb.owner(), owner);
        assertEq(arb.operator(), op);
        assertEq(address(arb.refundProtocol()), address(rp));
        assertEq(arb.challengeWindow(), WINDOW);
        assertEq(arb.minBond(), MIN);
        assertEq(rp.arbiter(), address(arb));
    }

    function test_constructor_revert_zeroProtocol() public {
        vm.expectRevert(PredgeRefundArbiter.ZeroAddress.selector);
        new PredgeRefundArbiter(address(0), op, WINDOW, MIN);
    }

    function test_constructor_revert_zeroOperator() public {
        vm.expectRevert(PredgeRefundArbiter.ZeroAddress.selector);
        new PredgeRefundArbiter(address(rp), address(0), WINDOW, MIN);
    }

    function test_setOperator() public {
        vm.expectEmit(true, true, false, false, address(arb));
        emit OperatorUpdated(op, op2);
        vm.prank(owner);
        arb.setOperator(op2);
        assertEq(arb.operator(), op2);
    }

    function test_setOperator_revert_notOwner() public {
        vm.prank(op);
        vm.expectRevert(PredgeRefundArbiter.NotOwner.selector);
        arb.setOperator(op2);
    }

    function test_setOperator_revert_zero() public {
        vm.prank(owner);
        vm.expectRevert(PredgeRefundArbiter.ZeroAddress.selector);
        arb.setOperator(address(0));
    }

    function test_setParams() public {
        vm.expectEmit(false, false, false, true, address(arb));
        emit ParamsUpdated(7, 9);
        vm.prank(owner);
        arb.setParams(7, 9);
        assertEq(arb.challengeWindow(), 7);
        assertEq(arb.minBond(), 9);
    }

    function test_setParams_revert_notOwner() public {
        vm.prank(op);
        vm.expectRevert(PredgeRefundArbiter.NotOwner.selector);
        arb.setParams(0, 0);
    }

    function test_setLockupSeconds_passThrough() public {
        vm.prank(owner);
        arb.setLockupSeconds(merchant, 3600);
        assertEq(rp.lockupSeconds(merchant), 3600);
    }

    function test_setLockupSeconds_revert_notOwner() public {
        vm.prank(op);
        vm.expectRevert(PredgeRefundArbiter.NotOwner.selector);
        arb.setLockupSeconds(merchant, 1);
    }

    // ───────────── fileEvidence ─────────────
    function test_fileEvidence() public {
        vm.expectEmit(true, true, false, true, address(arb));
        emit EvidenceFiled(PID, payer, EV);
        _file(payer, PID, EV);
        assertEq(arb.filedEvidence(PID, payer), EV);
        _file(merchant, PID, keccak256("m")); // both parties may file
        _file(payer, PID + 1, EV); // and per payment
    }

    function test_fileEvidence_revert_zeroHash() public {
        vm.prank(payer);
        vm.expectRevert(PredgeRefundArbiter.ZeroHash.selector);
        arb.fileEvidence(PID, bytes32(0));
    }

    function test_fileEvidence_revert_operator() public {
        vm.prank(op);
        vm.expectRevert(PredgeRefundArbiter.ArbiterCannotFile.selector);
        arb.fileEvidence(PID, EV);
    }

    function test_fileEvidence_revert_owner() public {
        vm.prank(owner);
        vm.expectRevert(PredgeRefundArbiter.ArbiterCannotFile.selector);
        arb.fileEvidence(PID, EV);
    }

    function test_fileEvidence_revert_self() public {
        vm.prank(address(arb));
        vm.expectRevert(PredgeRefundArbiter.ArbiterCannotFile.selector);
        arb.fileEvidence(PID, EV);
    }

    function test_fileEvidence_revert_writeOnce() public {
        _file(payer, PID, EV);
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(PredgeRefundArbiter.EvidenceAlreadyFiled.selector, PID, payer));
        arb.fileEvidence(PID, keccak256("revised"));
    }

    // ───────────── rule ─────────────
    function test_rule_refund_callsProtocol() public {
        _file(payer, PID, EV);
        vm.expectEmit(true, false, false, true, address(arb));
        emit Committed(PID, EV, payer, PredgeRefundArbiter.Direction.Refund, MIN);
        vm.expectEmit(true, false, false, true, address(arb));
        emit Ruled(PID, PredgeRefundArbiter.Direction.Refund, EV, uint64(block.timestamp));
        _rule(PID, PredgeRefundArbiter.Direction.Refund, MIN);
        assertTrue(rp.refunded(PID));
        assertEq(rp.refundCount(), 1);
        assertEq(arb.rulingCount(), 1);
        assertEq(address(arb).balance, MIN);
        (bytes32 h, address from, uint96 bond, uint64 at, PredgeRefundArbiter.Direction d, bool settled) = arb.rulingOf(PID);
        assertEq(h, EV);
        assertEq(from, payer);
        assertEq(bond, MIN);
        assertEq(at, block.timestamp);
        assertEq(uint8(d), uint8(PredgeRefundArbiter.Direction.Refund));
        assertFalse(settled);
        (, , , address decidedBy, , , ) = arb.rulings(PID);
        assertEq(decidedBy, op);
    }

    function test_rule_release_doesNotRefund() public {
        _ruled(PredgeRefundArbiter.Direction.Release);
        assertFalse(rp.refunded(PID));
        assertEq(rp.refundCount(), 0);
        assertEq(arb.rulingCount(), 1);
    }

    function test_rule_revert_notOperator() public {
        _file(payer, PID, EV);
        vm.deal(anyone, 1 ether);
        vm.prank(anyone);
        vm.expectRevert(PredgeRefundArbiter.NotOperator.selector);
        arb.rule{value: MIN}(PID, payer, EV, PredgeRefundArbiter.Direction.Refund);
    }

    function test_rule_revert_zeroHash() public {
        vm.prank(op);
        vm.expectRevert(PredgeRefundArbiter.ZeroHash.selector);
        arb.rule{value: MIN}(PID, payer, bytes32(0), PredgeRefundArbiter.Direction.Refund);
    }

    function test_rule_revert_zeroFrom() public {
        vm.prank(op);
        vm.expectRevert(PredgeRefundArbiter.ZeroAddress.selector);
        arb.rule{value: MIN}(PID, address(0), EV, PredgeRefundArbiter.Direction.Refund);
    }

    function test_rule_revert_directionNone() public {
        vm.prank(op);
        vm.expectRevert(PredgeRefundArbiter.BadDirection.selector);
        arb.rule{value: MIN}(PID, payer, EV, PredgeRefundArbiter.Direction.None);
    }

    function test_rule_revert_directionOutOfRange() public {
        _file(payer, PID, EV);
        bytes memory data = abi.encodeWithSelector(PredgeRefundArbiter.rule.selector, PID, payer, EV, uint8(3));
        vm.prank(op);
        (bool ok, ) = address(arb).call{value: MIN}(data);
        assertFalse(ok, "enum out of range must revert");
    }

    function test_rule_revert_bondTooSmall() public {
        _file(payer, PID, EV);
        vm.prank(op);
        vm.expectRevert(PredgeRefundArbiter.BondTooSmall.selector);
        arb.rule{value: MIN - 1}(PID, payer, EV, PredgeRefundArbiter.Direction.Refund);
    }

    function test_rule_bondExactlyMinOk() public {
        _file(payer, PID, EV);
        _rule(PID, PredgeRefundArbiter.Direction.Refund, MIN);
    }

    function test_rule_revert_noEvidenceFiled() public {
        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(PredgeRefundArbiter.NoEvidenceFiled.selector, PID, payer));
        arb.rule{value: MIN}(PID, payer, EV, PredgeRefundArbiter.Direction.Refund);
    }

    function test_rule_revert_citesDifferentVersion() public {
        _file(payer, PID, keccak256("what the payer actually filed"));
        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(PredgeRefundArbiter.NoEvidenceFiled.selector, PID, payer));
        arb.rule{value: MIN}(PID, payer, EV, PredgeRefundArbiter.Direction.Refund);
    }

    function test_rule_revert_evidenceFiledForOtherPayment() public {
        _file(payer, PID + 1, EV);
        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(PredgeRefundArbiter.NoEvidenceFiled.selector, PID, payer));
        arb.rule{value: MIN}(PID, payer, EV, PredgeRefundArbiter.Direction.Refund);
    }

    function test_rule_revert_alreadyRuled() public {
        _ruled(PredgeRefundArbiter.Direction.Release);
        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(PredgeRefundArbiter.AlreadyRuled.selector, PID));
        arb.rule{value: MIN}(PID, payer, EV, PredgeRefundArbiter.Direction.Refund);
    }

    function test_rule_revert_alreadyRuledEvenAfterReclaim() public {
        _ruled(PredgeRefundArbiter.Direction.Release);
        vm.warp(block.timestamp + WINDOW);
        vm.prank(op);
        arb.reclaim(PID);
        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(PredgeRefundArbiter.AlreadyRuled.selector, PID));
        arb.rule{value: MIN}(PID, payer, EV, PredgeRefundArbiter.Direction.Refund);
    }

    /// BUG (RA-02): bond stored as uint96(msg.value) without a bound check; value >= 2^96 is
    /// truncated and the excess is locked in the contract forever (same pattern as AJ-01, VB-02).
    function test_BUG_rule_truncatesBondAbove2pow96() public {
        _file(payer, PID, EV);
        uint256 v = uint256(type(uint96).max) + 1 + MIN;
        vm.deal(op, v);
        vm.prank(op);
        arb.rule{value: v}(PID, payer, EV, PredgeRefundArbiter.Direction.Release);
        (, , uint96 bond, , , ) = arb.rulingOf(PID);
        assertEq(uint256(bond), v, "bond truncated to uint96");
    }

    // ───────────── challenge ─────────────
    function test_challenge_revert_notRuled() public {
        vm.expectRevert(abi.encodeWithSelector(PredgeRefundArbiter.NotRuled.selector, PID));
        arb.challenge(PID);
    }

    function test_challenge_revert_honestRuling() public {
        _ruled(PredgeRefundArbiter.Direction.Refund);
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(PredgeRefundArbiter.RulingHonest.selector, PID));
        arb.challenge(PID);
        // other parties filing later does not change the cited filing
        _file(merchant, PID, keccak256("merchant"));
        vm.expectRevert(abi.encodeWithSelector(PredgeRefundArbiter.RulingHonest.selector, PID));
        arb.challenge(PID);
    }

    function test_challenge_revert_alreadySettled() public {
        _ruled(PredgeRefundArbiter.Direction.Refund);
        vm.warp(block.timestamp + WINDOW);
        vm.prank(op);
        arb.reclaim(PID);
        vm.expectRevert(abi.encodeWithSelector(PredgeRefundArbiter.AlreadySettled.selector, PID));
        arb.challenge(PID);
    }

    /// The slash path is only reachable if the write-once filing changes, which the contract
    /// itself never allows (finding RA-01). Here storage is forced to exercise the payout logic.
    function test_challenge_slashesOnTamperedFiling() public {
        _ruled(PredgeRefundArbiter.Direction.Refund);
        bytes32 changed = keccak256("changed");
        _tamperFiling(PID, payer, changed);
        assertTrue(arb.wouldSlash(PID));
        vm.expectEmit(true, true, false, true, address(arb));
        emit Slashed(PID, anyone, MIN, EV, changed);
        vm.prank(anyone);
        arb.challenge(PID);
        assertEq(anyone.balance, MIN);
        assertEq(arb.slashCount(), 1);
        (, , uint96 bond, , , bool settled) = arb.rulingOf(PID);
        assertEq(bond, 0);
        assertTrue(settled);
        assertFalse(arb.wouldSlash(PID));
        // no double slash, no reclaim of a slashed bond
        vm.expectRevert(abi.encodeWithSelector(PredgeRefundArbiter.AlreadySettled.selector, PID));
        arb.challenge(PID);
        vm.warp(block.timestamp + WINDOW);
        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(PredgeRefundArbiter.AlreadySettled.selector, PID));
        arb.reclaim(PID);
    }

    function test_challenge_revert_challengerCannotReceive() public {
        _ruled(PredgeRefundArbiter.Direction.Refund);
        _tamperFiling(PID, payer, keccak256("changed"));
        ToggleReceiver c = new ToggleReceiver();
        c.setAccept(false);
        vm.expectRevert(PredgeRefundArbiter.TransferFailed.selector);
        c.exec(address(arb), 0, abi.encodeCall(PredgeRefundArbiter.challenge, (PID)));
    }

    function test_challenge_reentrancyBlocked() public {
        _ruled(PredgeRefundArbiter.Direction.Refund);
        _tamperFiling(PID, payer, keccak256("changed"));
        Reenterer r = new Reenterer();
        r.arm(address(arb), abi.encodeCall(PredgeRefundArbiter.challenge, (PID)));
        r.exec(address(arb), 0, abi.encodeCall(PredgeRefundArbiter.challenge, (PID)));
        assertTrue(r.reentered());
        assertFalse(r.reentrySucceeded());
        assertEq(address(r).balance, MIN);
    }

    // ───────────── reclaim ─────────────
    function test_reclaim_afterWindow() public {
        _ruled(PredgeRefundArbiter.Direction.Refund);
        uint256 before = op.balance;
        vm.warp(block.timestamp + WINDOW);
        vm.expectEmit(true, false, false, true, address(arb));
        emit Reclaimed(PID, MIN);
        vm.prank(op);
        arb.reclaim(PID);
        assertEq(op.balance, before + MIN);
        assertEq(address(arb).balance, 0);
        (, , uint96 bond, , , bool settled) = arb.rulingOf(PID);
        assertEq(bond, 0);
        assertTrue(settled);
    }

    function test_reclaim_revert_windowOpen_boundary() public {
        _ruled(PredgeRefundArbiter.Direction.Refund);
        vm.warp(block.timestamp + WINDOW - 1);
        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(PredgeRefundArbiter.WindowOpen.selector, PID));
        arb.reclaim(PID);
        vm.warp(block.timestamp + 1);
        vm.prank(op);
        arb.reclaim(PID);
    }

    function test_reclaim_revert_notOperator() public {
        _ruled(PredgeRefundArbiter.Direction.Refund);
        vm.warp(block.timestamp + WINDOW);
        vm.prank(owner);
        vm.expectRevert(PredgeRefundArbiter.NotOperator.selector);
        arb.reclaim(PID);
    }

    function test_reclaim_revert_notRuled() public {
        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(PredgeRefundArbiter.NotRuled.selector, PID));
        arb.reclaim(PID);
    }

    function test_reclaim_revert_twice() public {
        _ruled(PredgeRefundArbiter.Direction.Refund);
        vm.warp(block.timestamp + WINDOW);
        vm.startPrank(op);
        arb.reclaim(PID);
        vm.expectRevert(abi.encodeWithSelector(PredgeRefundArbiter.AlreadySettled.selector, PID));
        arb.reclaim(PID);
        vm.stopPrank();
    }

    function test_reclaim_revert_operatorCannotReceive() public {
        ToggleReceiver o = new ToggleReceiver();
        vm.prank(owner);
        arb.setOperator(address(o));
        _file(payer, PID, EV);
        vm.deal(address(o), 1 ether);
        o.exec(address(arb), MIN, abi.encodeCall(PredgeRefundArbiter.rule, (PID, payer, EV, PredgeRefundArbiter.Direction.Refund)));
        vm.warp(block.timestamp + WINDOW);
        o.setAccept(false);
        vm.expectRevert(PredgeRefundArbiter.TransferFailed.selector);
        o.exec(address(arb), 0, abi.encodeCall(PredgeRefundArbiter.reclaim, (PID)));
    }

    // ───────────── views ─────────────
    function test_wouldSlash_branches() public {
        assertFalse(arb.wouldSlash(PID), "no ruling");
        _ruled(PredgeRefundArbiter.Direction.Refund);
        assertFalse(arb.wouldSlash(PID), "honest");
        vm.warp(block.timestamp + WINDOW);
        vm.prank(op);
        arb.reclaim(PID);
        _tamperFiling(PID, payer, keccak256("x"));
        assertFalse(arb.wouldSlash(PID), "settled");
    }

    // ───────────── documented findings (pass = behaviour as described) ─────────────

    /// RA-01 (informational): rule() requires filedEvidence[pid][from] == evidenceHash and
    /// filings are write-once, so challenge() can NEVER succeed in practice: slashing is dead
    /// code and the bond secures nothing beyond "evidence was filed by some non-operator key".
    function testFuzz_finding_honestRulingNeverSlashable(bytes32 h, address party, address challenger, uint32 dt) public {
        vm.assume(h != bytes32(0) && party != address(0) && party != op && party != owner && party != address(arb));
        vm.prank(party);
        arb.fileEvidence(PID, h);
        vm.prank(op);
        arb.rule{value: MIN}(PID, party, h, PredgeRefundArbiter.Direction.Refund);
        vm.warp(block.timestamp + dt);
        vm.prank(challenger);
        vm.expectRevert(abi.encodeWithSelector(PredgeRefundArbiter.RulingHonest.selector, PID));
        arb.challenge(PID);
    }

    /// RA-03 (design): `evidenceFrom` is not bound to the payment's payer or merchant. An operator
    /// can file "evidence" from a sock-puppet key it controls and rule on it; the ruling is
    /// unslashable. The constraint "evidence comes from the parties" is not enforced on-chain.
    function test_finding_operatorCanCiteSockPuppetEvidence() public {
        address puppet = makeAddr("operator-controlled puppet");
        _file(puppet, PID, EV);
        vm.prank(op);
        arb.rule{value: MIN}(PID, puppet, EV, PredgeRefundArbiter.Direction.Refund);
        assertTrue(rp.refunded(PID));
        assertFalse(arb.wouldSlash(PID));
    }

    /// RA-04 (centralisation): setParams applies retroactively to open rulings. The owner can
    /// set challengeWindow = 0 and the operator reclaims immediately; or raise it to lock bonds.
    function test_finding_setParamsIsRetroactive() public {
        _ruled(PredgeRefundArbiter.Direction.Refund);
        vm.prank(owner);
        arb.setParams(0, MIN);
        vm.prank(op);
        arb.reclaim(PID); // same block as the ruling
        vm.prank(owner);
        arb.setParams(type(uint64).max, 0);
        _file(payer, PID + 1, EV);
        vm.prank(op);
        arb.rule(PID + 1, payer, EV, PredgeRefundArbiter.Direction.Refund); // minBond 0: zero bond allowed
        vm.warp(block.timestamp + 365 days);
        // RA-07: ruledAt + challengeWindow is uint64 arithmetic; a window near type(uint64).max
        // overflows and reclaim panics (0x11) instead of returning WindowOpen. Bonds are locked
        // until the owner lowers the window again.
        vm.prank(op);
        vm.expectRevert(stdError.arithmeticError);
        arb.reclaim(PID + 1);
        vm.prank(owner);
        arb.setParams(365 days * 2, 0);
        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(PredgeRefundArbiter.WindowOpen.selector, PID + 1));
        arb.reclaim(PID + 1);
    }

    /// RA-05 (operational): after setOperator, bonds posted by the previous operator are paid
    /// to the NEW operator on reclaim; the old key can no longer reclaim its own stake.
    function test_finding_operatorRotationRedirectsBond() public {
        _ruled(PredgeRefundArbiter.Direction.Refund);
        vm.prank(owner);
        arb.setOperator(op2);
        vm.warp(block.timestamp + WINDOW);
        vm.prank(op);
        vm.expectRevert(PredgeRefundArbiter.NotOperator.selector);
        arb.reclaim(PID);
        vm.prank(op2);
        arb.reclaim(PID);
        assertEq(op2.balance, MIN);
    }

    /// RA-06 (design): an operator that has been rotated out may then file evidence as a
    /// "party" (the ArbiterCannotFile check only looks at current keys).
    function test_finding_formerOperatorCanFile() public {
        vm.prank(owner);
        arb.setOperator(op2);
        _file(op, PID, EV);
        assertEq(arb.filedEvidence(PID, op), EV);
    }

    function testFuzz_onlyOperatorRules(address caller) public {
        vm.assume(caller != op);
        _file(payer, PID, EV);
        vm.deal(caller, 1 ether);
        vm.prank(caller);
        vm.expectRevert(PredgeRefundArbiter.NotOperator.selector);
        arb.rule{value: MIN}(PID, payer, EV, PredgeRefundArbiter.Direction.Refund);
    }

    function testFuzz_reclaimWindow(uint64 window, uint32 dt) public {
        window = uint64(bound(window, 1, 365 days));
        vm.prank(owner);
        arb.setParams(window, MIN);
        _ruled(PredgeRefundArbiter.Direction.Release);
        vm.warp(block.timestamp + dt);
        vm.prank(op);
        if (dt < window) {
            vm.expectRevert(abi.encodeWithSelector(PredgeRefundArbiter.WindowOpen.selector, PID));
            arb.reclaim(PID);
        } else {
            arb.reclaim(PID);
            assertEq(address(arb).balance, 0);
        }
    }

    function testFuzz_ruleBond(uint96 bond) public {
        bond = uint96(bound(bond, MIN, 50 ether));
        _file(payer, PID, EV);
        _rule(PID, PredgeRefundArbiter.Direction.Refund, bond);
        (, , uint96 b, , , ) = arb.rulingOf(PID);
        assertEq(b, bond);
        assertEq(address(arb).balance, bond);
    }
}
