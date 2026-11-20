// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Base, ReentrantReceiver} from "./Base.sol";
import {IdentityMock} from "./Misc.t.sol";
import {AgentJobV2} from "../../contracts/v2/AgentJobV2.sol";
import {IAgentJobV2} from "../../contracts/v2/interfaces/IAgentJobV2.sol";
import {PredgeValidatorBondV2} from "../../contracts/v2/PredgeValidatorBondV2.sol";
import {PredgeRefundArbiterV2} from "../../contracts/v2/PredgeRefundArbiterV2.sol";
import {PredgeAgentValidatorV2} from "../../contracts/v2/PredgeAgentValidatorV2.sol";
import {PredgeSettlementV2} from "../../contracts/v2/PredgeSettlementV2.sol";
import {Owned2Step} from "../../contracts/v2/access/PredgeAccess.sol";

// Tests for the Arc Studio pre-audit review of 21 Nov 2026. Every test name carries the finding ID it covers
// (F-01 ... F-19, see OLYMPIX_SUBMISSION.md). Tests for findings that are still Open document the CURRENT
// behaviour, so a later fix has to update them on purpose.

/// @dev A Refund Protocol stand-in whose payment fields are set freely (including a zero payer) and which can
///      be told to reject `refundByArbiter`, as a real protocol would for a payment already refunded or released.
contract ConfigurableRefundProtocol {
    struct P {
        address payer;
        address payee;
        uint256 amount;
        uint256 releaseTimestamp;
    }

    mapping(uint256 => P) public p;
    bool public rejectRefunds;
    uint256 public refundCount;

    function set(uint256 id, address payer, address payee, uint256 amount, uint256 releaseTimestamp) external {
        p[id] = P(payer, payee, amount, releaseTimestamp);
    }

    function setRejectRefunds(bool b) external {
        rejectRefunds = b;
    }

    function paymentInfo(uint256 id) external view returns (address, address, uint256, uint256) {
        P storage x = p[id];
        return (x.payer, x.payee, x.amount, x.releaseTimestamp);
    }

    function refundByArbiter(uint256) external {
        require(!rejectRefunds, "refund rejected");
        refundCount += 1;
    }

    function setLockupSeconds(address, uint256) external {}
}

/// @dev An identity registry that answers `ownerOf` with one byte only.
contract ShortReturnRegistry {
    fallback() external {
        assembly {
            mstore(0, 0x01)
            return(31, 1)
        }
    }
}

/// @dev An identity registry that answers with a 32-byte word whose low 20 bytes are `who` but whose high bits
///      are dirty, which is not a valid ABI-encoded address.
contract DirtyWordRegistry {
    address public who;

    function setWho(address w) external {
        who = w;
    }

    fallback() external {
        uint256 w = uint256(uint160(who)) | (uint256(1) << 200);
        assembly {
            mstore(0, w)
            return(0, 32)
        }
    }
}

// =====================================================================================================
// PredgeRefundArbiterV2: F-01, F-03, F-04, F-05, F-06, F-07, F-15, F-16
// =====================================================================================================

contract ArcStudioArbiterTest is Test {
    address internal safe = makeAddr("safe");
    address internal op = makeAddr("operator");
    address internal payer = makeAddr("payer");
    address internal payee = makeAddr("payee");
    address internal stranger = makeAddr("stranger");

    uint64 internal constant WINDOW = 1 days;
    uint256 internal constant MIN_BOND = 1e15;
    uint16 internal constant BPS = 500;
    uint256 internal constant AMOUNT = 1 ether;
    uint256 internal constant ID = 1;

    bytes32 internal constant EV = keccak256("payer evidence");
    bytes32 internal constant COUNTER = keccak256("counter evidence");

    ConfigurableRefundProtocol internal rp;
    PredgeRefundArbiterV2 internal arb;

    function setUp() public {
        vm.warp(1_760_000_000);
        rp = new ConfigurableRefundProtocol();
        arb = new PredgeRefundArbiterV2(safe, op, address(rp), WINDOW, MIN_BOND, BPS);
        rp.set(ID, payer, payee, AMOUNT, block.timestamp + 30 days);
        vm.deal(op, 100 ether);
    }

    function _bond() internal view returns (uint256) {
        return arb.requiredBond(AMOUNT);
    }

    function _ruleWith(address from, PredgeRefundArbiterV2.Direction d) internal {
        vm.prank(from);
        arb.fileEvidence(ID, EV);
        uint256 b = _bond();
        vm.prank(op);
        arb.rule{value: b}(ID, from, EV, d);
    }

    // ---------------------------------------------------------------- F-01 (Fixed)

    /// @dev F-01: a payment whose payer is address(0) is refused at `rule`. Before the fix, a Release ruling on it
    ///      could never be disputed (nobody can call as address(0)) and an overturn would credit the bond to
    ///      address(0), where it could never be withdrawn.
    function test_F01_ruleRejectsPaymentWithZeroPayer() public {
        rp.set(2, address(0), payee, AMOUNT, block.timestamp + 30 days);
        vm.prank(payee);
        arb.fileEvidence(2, EV);
        uint256 b = _bond();
        vm.prank(op);
        vm.expectRevert(PredgeRefundArbiterV2.UnknownPayment.selector);
        arb.rule{value: b}(2, payee, EV, PredgeRefundArbiterV2.Direction.Release);
        assertEq(arb.totalBonded(), 0);
    }

    /// @dev F-01: the zero-payee check is unchanged, and a well-formed payment is still accepted.
    function test_F01_zeroPayeeStillRejectedAndNormalPaymentAccepted() public {
        rp.set(3, payer, address(0), AMOUNT, block.timestamp + 30 days);
        vm.prank(op);
        vm.expectRevert(PredgeRefundArbiterV2.UnknownPayment.selector);
        arb.rule{value: 1 ether}(3, payer, EV, PredgeRefundArbiterV2.Direction.Refund);

        _ruleWith(payer, PredgeRefundArbiterV2.Direction.Refund);
        assertEq(uint8(arb.rulings(ID).status), uint8(PredgeRefundArbiterV2.Status.Ruled));
    }

    // ---------------------------------------------------------------- F-03 (Open)

    /// @dev F-03 (current behaviour): when the Refund Protocol rejects the refund, the owner cannot overturn a
    ///      Release ruling into a Refund, so the operator's bond cannot be slashed; the ruling ends Voided and the
    ///      bond goes back to the staker.
    function test_F03_overturnIntoRefundBlockedWhenProtocolRejects() public {
        _ruleWith(payer, PredgeRefundArbiterV2.Direction.Release);
        vm.prank(payer);
        arb.dispute(ID, COUNTER);
        rp.setRejectRefunds(true);

        vm.prank(safe);
        vm.expectRevert(bytes("refund rejected"));
        arb.resolve(ID, PredgeRefundArbiterV2.Direction.Refund);

        vm.warp(block.timestamp + arb.RESOLUTION_TIMEOUT());
        arb.expire(ID);
        assertEq(uint8(arb.rulings(ID).status), uint8(PredgeRefundArbiterV2.Status.Voided));
        assertEq(arb.credit(op), _bond(), "bond back to the staker, not to the harmed payer");
        assertEq(arb.credit(payer), 0);
    }

    /// @dev F-03 (current behaviour): the same rejection blocks `finalize` of an undisputed Refund ruling.
    function test_F03_finalizeOfRefundBlockedWhenProtocolRejects() public {
        _ruleWith(payer, PredgeRefundArbiterV2.Direction.Refund);
        vm.warp(block.timestamp + WINDOW);
        rp.setRejectRefunds(true);
        vm.expectRevert(bytes("refund rejected"));
        arb.finalize(ID);
    }

    // ---------------------------------------------------------------- F-04 (Open)

    /// @dev F-04 (current behaviour): once a ruling is Voided the payment can never be ruled again and no party can
    ///      file new evidence.
    function test_F04_voidedPaymentCannotBeRuledAgain() public {
        _ruleWith(payer, PredgeRefundArbiterV2.Direction.Refund);
        vm.prank(payee);
        arb.dispute(ID, COUNTER);
        vm.warp(block.timestamp + arb.RESOLUTION_TIMEOUT());
        arb.expire(ID);

        uint256 b = _bond();
        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(PredgeRefundArbiterV2.AlreadyRuled.selector, ID));
        arb.rule{value: b}(ID, payer, EV, PredgeRefundArbiterV2.Direction.Refund);
        vm.prank(payee);
        vm.expectRevert(PredgeRefundArbiterV2.EvidenceClosed.selector);
        arb.fileEvidence(ID, keccak256("new"));
    }

    // ---------------------------------------------------------------- F-05 (Open)

    /// @dev F-05 (current behaviour): after `expiresAt` an undisputed Refund ruling can be finalized (refund runs)
    ///      OR expired (nothing runs). Whoever calls first decides.
    function test_F05_afterExpiryFinalizeAndExpireRace() public {
        _ruleWith(payer, PredgeRefundArbiterV2.Direction.Refund);
        vm.warp(arb.rulings(ID).expiresAt);

        uint256 snap = vm.snapshotState();
        arb.finalize(ID);
        assertEq(rp.refundCount(), 1, "finalize executed the refund");

        vm.revertToState(snap);
        vm.prank(payee); // the party the refund harms
        arb.expire(ID);
        assertEq(rp.refundCount(), 0, "expire executed nothing");
        assertEq(uint8(arb.rulings(ID).status), uint8(PredgeRefundArbiterV2.Status.Voided));
    }

    // ---------------------------------------------------------------- F-06 (Accepted risk)

    /// @dev F-06: a dispute costs nothing; if the owner stays silent for RESOLUTION_TIMEOUT the ruling is voided,
    ///      nothing executes, and the operator keeps its bond.
    function test_F06_freeDisputeAndOwnerSilenceVoidsRuling() public {
        _ruleWith(payer, PredgeRefundArbiterV2.Direction.Refund);
        uint256 balBefore = payee.balance;
        vm.prank(payee);
        arb.dispute(ID, COUNTER);
        assertEq(payee.balance, balBefore, "dispute is free");
        vm.warp(block.timestamp + arb.RESOLUTION_TIMEOUT());
        arb.expire(ID);
        assertEq(rp.refundCount(), 0);
        assertEq(arb.credit(op), _bond());
    }

    // ---------------------------------------------------------------- F-07 (Accepted risk)

    /// @dev F-07: the owner is the court of last resort and is not barred from resolving a payment it is a party to.
    function test_F07_ownerCanResolvePaymentItIsPartyTo() public {
        rp.set(5, safe, payee, AMOUNT, block.timestamp + 30 days);
        vm.prank(payee);
        arb.fileEvidence(5, EV);
        uint256 b = _bond();
        vm.prank(op);
        arb.rule{value: b}(5, payee, EV, PredgeRefundArbiterV2.Direction.Release);
        vm.prank(safe);
        arb.dispute(5, COUNTER);
        vm.prank(safe);
        arb.resolve(5, PredgeRefundArbiterV2.Direction.Refund);
        assertEq(arb.credit(safe), b, "the owner, as payer, received the slashed bond");
        assertEq(rp.refundCount(), 1);
    }

    /// @dev F-07: owner-only configuration stays owner-only.
    function test_F07_ownerPowersAreOwnerOnly() public {
        vm.startPrank(stranger);
        vm.expectRevert(Owned2Step.NotOwner.selector);
        arb.setParams(WINDOW, MIN_BOND, BPS);
        vm.expectRevert(Owned2Step.NotOwner.selector);
        arb.setOperator(stranger);
        vm.expectRevert(Owned2Step.NotOwner.selector);
        arb.setLockupSeconds(payee, 20 days);
        vm.expectRevert(Owned2Step.NotOwner.selector);
        arb.resolve(ID, PredgeRefundArbiterV2.Direction.Refund);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- F-15 (False positive)

    /// @dev F-15: `fileEvidence` needs only payer and payee from `paymentInfo`; amount and release time are read and
    ///      enforced in `rule`, so the ignored return values are not a gap.
    function test_F15_unusedReturnValuesAreEnforcedInRule() public {
        vm.prank(stranger);
        vm.expectRevert(PredgeRefundArbiterV2.NotAParty.selector);
        arb.fileEvidence(ID, EV);

        rp.set(6, payer, payee, AMOUNT, block.timestamp + WINDOW + 14 days); // release too early
        vm.prank(payer);
        arb.fileEvidence(6, EV); // accepted: fileEvidence does not look at the release time
        uint256 b = _bond();
        vm.prank(op);
        vm.expectRevert(PredgeRefundArbiterV2.LockupTooShort.selector);
        arb.rule{value: b}(6, payer, EV, PredgeRefundArbiterV2.Direction.Refund);
        vm.prank(payer);
        arb.fileEvidence(ID, EV);
        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(PredgeRefundArbiterV2.BondTooSmall.selector, b));
        arb.rule{value: b - 1}(ID, payer, EV, PredgeRefundArbiterV2.Direction.Refund);
    }

    // ---------------------------------------------------------------- F-16 (Accepted risk)

    /// @dev F-16: the arbiter's timestamp comparisons are exact at the boundaries.
    function test_F16_arbiterTimestampBoundaries() public {
        _ruleWith(payer, PredgeRefundArbiterV2.Direction.Refund);
        uint256 end = block.timestamp + WINDOW;
        vm.warp(end - 1);
        vm.expectRevert(PredgeRefundArbiterV2.WindowOpen.selector);
        arb.finalize(ID);
        vm.warp(end);
        vm.prank(payee);
        vm.expectRevert(PredgeRefundArbiterV2.WindowClosed.selector);
        arb.dispute(ID, COUNTER);
        arb.finalize(ID);
    }
}

// =====================================================================================================
// PredgeValidatorBondV2 + AgentJobV2: F-08, F-09, F-10, F-11, F-16, F-19
// =====================================================================================================

contract ArcStudioBondTest is Base {
    bytes32 internal constant SALT = keccak256("salt");
    uint256 internal constant ESCROW = 1 ether;

    function setUp() public {
        _deployJobAndBond();
    }

    // ---------------------------------------------------------------- F-08 (Open)

    /// @dev F-08 (current behaviour): the client picks `expiredAt` with no upper bound. If the provider never
    ///      submits, the operator's bond (and the client's escrow) stay locked until then.
    function test_F08_farExpiryLocksBondUntilExpiry() public {
        bytes32 spec = _bspec(_good(), SALT);
        vm.prank(client);
        uint256 id = job.createJob{value: ESCROW}(provider, address(bond), spec, type(uint64).max);
        _stake(spec, _good(), SALT, id, ESCROW);

        vm.warp(block.timestamp + 100 * 365 days);
        vm.expectRevert(AgentJobV2.NotExpired.selector);
        job.claimRefund(id);
        vm.expectRevert(PredgeValidatorBondV2.JobNotExpired.selector);
        bond.release(spec);
        assertEq(bond.totalBonded(), ESCROW, "bond still locked after 100 years");
    }

    // ---------------------------------------------------------------- F-09 (Accepted risk)

    /// @dev F-09: rotating the operator while a stake is Committed, without handing over (expected, salt), leaves the
    ///      new key unable to score; the job times out and the bond is forfeited to the provider.
    function test_F09_rotationWithoutPreimageForfeitsBond() public {
        (uint256 id, bytes32 spec) = _newJob(ESCROW, _good(), SALT);
        _stake(spec, _good(), SALT, id, ESCROW);
        address newOp = makeAddr("newOperator");
        vm.prank(safe);
        bond.setOperator(newOp);
        _deliver(id, GOOD);

        bytes32 e = _good(); // computed before the prank: the sha256 precompile call would consume it
        vm.prank(newOp);
        vm.expectRevert(PredgeValidatorBondV2.BadReveal.selector);
        bond.recordScore(spec, 100, e, keccak256("guessed salt"), 0);

        vm.warp(block.timestamp + EVAL_WINDOW);
        job.claimRefund(id);
        bond.release(spec);
        assertEq(bond.credit(provider), ESCROW, "bond forfeited to the provider");
        assertEq(bond.credit(op), 0);
        assertEq(job.credit(client), ESCROW, "escrow refunded to the client");
    }

    // ---------------------------------------------------------------- F-10 (Accepted risk)

    /// @dev F-10: stakes are keyed by specHash, which is public. Anyone can open another job with the same specHash;
    ///      only one of the jobs that share it can ever be bonded.
    function test_F10_jobsSharingSpecHashOnlyOneBondable() public {
        (uint256 idA, bytes32 spec) = _newJob(ESCROW, _good(), SALT);
        vm.prank(stranger);
        uint256 idB = job.createJob{value: 1}(stranger, address(bond), spec, uint64(block.timestamp + 7 days));

        _stake(spec, _good(), SALT, idA, ESCROW);
        bytes32 c = _commitment(_good(), SALT);
        vm.prank(op);
        vm.expectRevert(PredgeValidatorBondV2.AlreadyCommitted.selector);
        bond.stakeAndCommit{value: ESCROW}(spec, c, idB);
        (,,,,, uint256 stakedJob,,,) = bond.stakes(spec);
        assertEq(stakedJob, idA, "the stake names the job the operator chose");
    }

    // ---------------------------------------------------------------- F-11 (Accepted risk)

    /// @dev F-11: a job that names the bond as evaluator but is never staked cannot be completed, even with the
    ///      correct bytes; the client is refunded at the timeout and the provider is not paid.
    function test_F11_unstakedJobCanOnlyRefund() public {
        (uint256 id, bytes32 spec) = _newJob(ESCROW, _good(), SALT);
        _deliver(id, GOOD);
        bytes32 e = _good();
        vm.prank(op);
        vm.expectRevert(PredgeValidatorBondV2.NotCommitted.selector);
        bond.recordScore(spec, 100, e, SALT, 0);
        vm.warp(block.timestamp + EVAL_WINDOW);
        job.claimRefund(id);
        assertEq(job.credit(client), ESCROW);
        assertEq(job.credit(provider), 0);
    }

    // ---------------------------------------------------------------- F-16 (Accepted risk)

    /// @dev F-16: the job's timestamp comparisons are exact at the boundaries.
    function test_F16_jobTimestampBoundaries() public {
        (uint256 id, bytes32 spec) = _newJob(ESCROW, _good(), SALT);
        _stake(spec, _good(), SALT, id, ESCROW);
        uint64 exp = job.getJob(id).expiredAt;
        vm.warp(exp);
        bytes32 h = _good();
        vm.prank(provider);
        vm.expectRevert(AgentJobV2.PastDeadline.selector);
        job.submit(id, h, GOOD);
        vm.warp(exp - 1);
        _deliver(id, GOOD);
        vm.warp(block.timestamp + EVAL_WINDOW);
        vm.prank(op);
        vm.expectRevert(AgentJobV2.PastDeadline.selector); // the job refuses the verdict at the window's end
        bond.recordScore(spec, 100, h, SALT, 0);
        vm.warp(block.timestamp - 1);
        _score(spec, 100, _good(), SALT);
        assertEq(job.credit(provider), ESCROW);
    }

    // ---------------------------------------------------------------- F-19 (Accepted risk)

    /// @dev F-19: PullCredit's low-level call zeroes the credit before sending, so a re-entering recipient gets
    ///      nothing twice.
    function test_F19_pullCreditReentryGetsNothingTwice() public {
        ReentrantReceiver r = new ReentrantReceiver();
        address evaluator = makeAddr("evaluator");
        vm.prank(client);
        uint256 id = job.createJob{value: ESCROW}(address(r), evaluator, keccak256("s"), uint64(block.timestamp + 1 days));
        vm.prank(address(r));
        job.submit(id, keccak256("d"), "");
        vm.prank(evaluator);
        job.complete(id, keccak256("ok"), "");

        r.set(address(job));
        r.go();
        assertTrue(r.reentered());
        assertTrue(r.reenterFailed(), "the nested withdraw reverted (NothingToWithdraw)");
        assertEq(address(r).balance, ESCROW);
        assertEq(job.totalCredit(), 0);
    }
}

// =====================================================================================================
// PredgeAgentValidatorV2, PredgeSettlementV2, Owned2Step: F-02, F-12, F-13, F-14, F-17, F-18, F-19
// =====================================================================================================

contract ArcStudioRegistryTest is Test {
    address internal safe = makeAddr("safe");
    address internal op = makeAddr("operator");
    address internal agentOwner = makeAddr("agentOwner");
    address internal stranger = makeAddr("stranger");

    // ---------------------------------------------------------------- F-02 (Fixed)

    /// @dev F-02: a registry address with no code. Before the fix the decode of the empty return data reverted
    ///      outside the try/catch with no reason; now the caller is simply not authorized.
    function test_F02_codelessRegistryMeansNotAuthorized() public {
        PredgeAgentValidatorV2 r = new PredgeAgentValidatorV2(safe, op, makeAddr("eoaRegistry"));
        vm.prank(stranger);
        vm.expectRevert(PredgeAgentValidatorV2.NotAuthorized.selector);
        r.validationRequest(op, 1, "u", keccak256("d"));
    }

    /// @dev F-02: a registry that returns fewer than 32 bytes.
    function test_F02_shortReturnMeansNotAuthorized() public {
        PredgeAgentValidatorV2 r = new PredgeAgentValidatorV2(safe, op, address(new ShortReturnRegistry()));
        vm.prank(stranger);
        vm.expectRevert(PredgeAgentValidatorV2.NotAuthorized.selector);
        r.validationRequest(op, 1, "u", keccak256("d"));
    }

    /// @dev F-02: a registry that returns a word that is not a clean address, even if its low 20 bytes are the caller.
    function test_F02_dirtyAddressWordMeansNotAuthorized() public {
        DirtyWordRegistry reg = new DirtyWordRegistry();
        reg.setWho(stranger);
        PredgeAgentValidatorV2 r = new PredgeAgentValidatorV2(safe, op, address(reg));
        vm.prank(stranger);
        vm.expectRevert(PredgeAgentValidatorV2.NotAuthorized.selector);
        r.validationRequest(op, 1, "u", keccak256("d"));
    }

    /// @dev F-02: the behaviour for a well-formed registry is unchanged: the owner is authorized, others are not,
    ///      and a reverting `ownerOf` (unknown token) means not authorized.
    function test_F02_wellFormedRegistryUnchanged() public {
        IdentityMock idr = new IdentityMock();
        idr.set(7, agentOwner);
        PredgeAgentValidatorV2 r = new PredgeAgentValidatorV2(safe, op, address(idr));
        vm.prank(agentOwner);
        bytes32 h = r.validationRequest(op, 7, "u", keccak256("d"));
        assertEq(h, r.requestHashFor(7, keccak256("d")));
        vm.prank(stranger);
        vm.expectRevert(PredgeAgentValidatorV2.NotAuthorized.selector);
        r.validationRequest(op, 7, "u", keccak256("d2"));
        vm.prank(agentOwner);
        vm.expectRevert(PredgeAgentValidatorV2.NotAuthorized.selector);
        r.validationRequest(op, 8, "u", keccak256("d3")); // ownerOf(8) reverts
        idr.setBroken(true);
        vm.prank(agentOwner);
        vm.expectRevert(PredgeAgentValidatorV2.NotAuthorized.selector);
        r.validationRequest(op, 7, "u", keccak256("d4"));
    }

    /// @dev F-02: authorization of any registry answer is exactly "the answer equals the caller".
    function testFuzz_F02_onlyExactOwnerAuthorized(address claimed, address caller) public {
        vm.assume(caller != op && caller != address(0));
        IdentityMock idr = new IdentityMock();
        vm.assume(claimed != address(0));
        idr.set(1, claimed);
        PredgeAgentValidatorV2 r = new PredgeAgentValidatorV2(safe, op, address(idr));
        vm.prank(caller);
        if (claimed == caller) {
            r.validationRequest(op, 1, "u", keccak256("d"));
            assertEq(r.requestCount(), 1);
        } else {
            vm.expectRevert(PredgeAgentValidatorV2.NotAuthorized.selector);
            r.validationRequest(op, 1, "u", keccak256("d"));
        }
    }

    // ---------------------------------------------------------------- F-12 (Accepted risk)

    /// @dev F-12: with an identity registry set, the agent owner can record a (agentId, digest) request first, with
    ///      its own requestURI; the operator's identical request then reverts.
    function test_F12_agentOwnerCanPreRegisterRequest() public {
        IdentityMock idr = new IdentityMock();
        idr.set(7, agentOwner);
        PredgeAgentValidatorV2 r = new PredgeAgentValidatorV2(safe, op, address(idr));
        bytes32 d = keccak256("digest");
        vm.prank(agentOwner);
        bytes32 h = r.validationRequest(op, 7, "ipfs://owner-chosen", d);
        vm.prank(op);
        vm.expectRevert(PredgeAgentValidatorV2.AlreadyRequested.selector);
        r.validationRequest(op, 7, "ipfs://operator", d);
        assertEq(r.requestURIOf(h), "ipfs://owner-chosen");
    }

    // ---------------------------------------------------------------- F-13 (Accepted risk)

    /// @dev F-13: `getSummary` rounds the average down.
    function test_F13_summaryAverageRoundsDown() public {
        PredgeAgentValidatorV2 r = new PredgeAgentValidatorV2(safe, op, address(0));
        bytes32[] memory hs = new bytes32[](2);
        vm.startPrank(op);
        hs[0] = r.validationRequest(op, 1, "u", keccak256("a"));
        hs[1] = r.validationRequest(op, 1, "u", keccak256("b"));
        r.validationResponse(hs[0], 100, "", keccak256("r0"), "");
        r.validationResponse(hs[1], 51, "", keccak256("r1"), "");
        vm.stopPrank();
        (uint64 count, uint8 avg) = r.getSummary(1, hs);
        assertEq(count, 2);
        assertEq(avg, 75, "151 / 2 rounds down to 75");
    }

    // ---------------------------------------------------------------- F-14 (Accepted risk)

    event Withdrawn(address indexed to, uint256 amount);

    /// @dev F-14: withdrawing an empty settlement contract succeeds and emits a zero-amount event.
    function test_F14_settlementZeroBalanceWithdrawSucceeds() public {
        PredgeSettlementV2 s = new PredgeSettlementV2(safe);
        address to = makeAddr("treasury");
        vm.expectEmit(true, false, false, true, address(s));
        emit Withdrawn(to, 0);
        vm.prank(safe);
        s.withdraw(payable(to));
        assertEq(to.balance, 0);
    }

    // ---------------------------------------------------------------- F-17 (False positive)

    /// @dev F-17: nominating address(0) cancels a pending nomination; it can never set the owner to zero.
    function test_F17_nominatingZeroCancelsAndNeverZeroesOwner() public {
        PredgeSettlementV2 s = new PredgeSettlementV2(safe);
        address next = makeAddr("next");
        vm.startPrank(safe);
        s.transferOwnership(next);
        s.transferOwnership(address(0));
        vm.stopPrank();
        vm.prank(next);
        vm.expectRevert(Owned2Step.NotPendingOwner.selector);
        s.acceptOwnership();
        assertEq(s.owner(), safe);
        assertEq(s.pendingOwner(), address(0));
    }

    // ---------------------------------------------------------------- F-18 (False positive)

    /// @dev F-18: a zero identity registry is the documented "operator only" mode, not a missing check.
    function test_F18_zeroRegistryMeansOperatorOnly() public {
        PredgeAgentValidatorV2 r = new PredgeAgentValidatorV2(safe, op, address(0));
        vm.prank(stranger);
        vm.expectRevert(PredgeAgentValidatorV2.NotAuthorized.selector);
        r.validationRequest(op, 1, "u", keccak256("d"));
        vm.prank(op);
        r.validationRequest(op, 1, "u", keccak256("d"));
        assertEq(r.requestCount(), 1);
    }

    // ---------------------------------------------------------------- F-19 (Accepted risk)

    /// @dev F-19: the settlement's low-level call checks its result; a failed send reverts and leaves the balance.
    function test_F19_settlementFailedSendReverts() public {
        PredgeSettlementV2 s = new PredgeSettlementV2(safe);
        vm.deal(address(this), 1 ether);
        s.payForRoute{value: 1 ether}(keccak256("route"), "");
        RejectAll sink = new RejectAll();
        vm.prank(safe);
        vm.expectRevert(PredgeSettlementV2.WithdrawFailed.selector);
        s.withdraw(payable(address(sink)));
        assertEq(address(s).balance, 1 ether);
    }
}

contract RejectAll {}
