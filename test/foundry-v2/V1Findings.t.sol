// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base, NoReceive} from "./Base.sol";
import {ArbiterBase} from "./PredgeRefundArbiterV2.t.sol";
import {PredgeValidatorBondV2} from "../../contracts/v2/PredgeValidatorBondV2.sol";
import {PredgeRefundArbiterV2} from "../../contracts/v2/PredgeRefundArbiterV2.sol";
import {PredgeAgentValidatorV2} from "../../contracts/v2/PredgeAgentValidatorV2.sol";
import {PredgeSettlementV2} from "../../contracts/v2/PredgeSettlementV2.sol";
import {AgentJobV2} from "../../contracts/v2/AgentJobV2.sol";
import {IAgentJobV2} from "../../contracts/v2/interfaces/IAgentJobV2.sol";
import {Owned2Step} from "../../contracts/v2/access/PredgeAccess.sol";
import {PullCredit} from "../../contracts/v2/access/PullCredit.sol";

/// @notice v2 versions of the v1 test_BUG_ / test_finding_ tests (PR #2): each v1 attack must revert or be harmless.
contract V1FindingsBondTest is Base {
    bytes32 internal E; // sha256(GOOD)
    bytes32 constant SALT = keccak256("salt");
    bytes32 constant X = keccak256("other");

    function setUp() public {
        _deployJobAndBond();
        E = _good();
    }

    // VB-01 / test_BUG_stake_allowedAfterDeliverableIsPublic, test_finding_postHocCommitMakesFalsePassUnslashable
    function test_fixed_VB01_stakeAfterDeliverableReverts() public {
        (uint256 id, bytes32 spec) = _newJob(1 ether, E, SALT);
        _submit(id, X);
        vm.prank(op);
        vm.expectRevert(PredgeValidatorBondV2.NotOpen.selector);
        bond.stakeAndCommit{value: 1 ether}(spec, keccak256(abi.encode(E, SALT)), id);
    }

    // test_finding_scoreBeforeDeliveryThenReclaim
    function test_fixed_scoreBeforeDeliveryThenReclaim() public {
        (uint256 id, bytes32 spec) = _newJob(1 ether, E, SALT);
        _stake(spec, E, SALT, id, 1 ether);
        vm.prank(op);
        vm.expectRevert(PredgeValidatorBondV2.NotSubmitted.selector);
        bond.recordScore(spec, 100, E, SALT, 0);
    }

    // test_BUG_*_truncates*: amounts are uint256 end to end; a value above 2^96 is stored exactly.
    function test_fixed_noUint96Truncation() public {
        uint256 big = uint256(type(uint96).max) + 1 ether;
        vm.deal(client, big);
        bytes32 spec = _bspec(E, SALT);
        vm.prank(client);
        uint256 id = job.createJob{value: big}(provider, address(bond), spec, uint64(block.timestamp + 1 days));
        assertEq(job.getJob(id).escrow, big);
        assertEq(address(job).balance, big);
        vm.deal(op, big);
        _stake(spec, E, SALT, id, big);
        (,,,,,, uint256 b,,) = bond.stakes(spec);
        assertEq(b, big);
        assertEq(bond.totalBonded(), big);
    }

    // test_finding_rotationInheritsStakesAndBypassesProviderCheck (VB-04)
    function test_fixed_VB04_rotatedOperatorCannotScoreItsOwnJob() public {
        bytes32 spec = _bspec(E, SALT);
        address newOp = makeAddr("newOp");
        vm.prank(client);
        uint256 id = job.createJob{value: 1 ether}(newOp, address(bond), spec, uint64(block.timestamp + 1 days));
        _stake(spec, E, SALT, id, 1 ether); // old op stakes: fine, the provider is not op
        vm.prank(newOp);
        job.submit(id, X, "");
        vm.prank(safe);
        bond.setOperator(newOp); // owner rotates to the provider
        vm.prank(newOp);
        vm.expectRevert(PredgeValidatorBondV2.ProviderIsOperator.selector);
        bond.recordScore(spec, 100, E, SALT, 0);
    }

    // test_finding_operatorRotationRedirectsBond (L-04): the bond always goes back to the staker.
    function test_fixed_rotationDoesNotRedirectBond() public {
        (uint256 id, bytes32 spec) = _newJob(1 ether, E, SALT);
        _stake(spec, E, SALT, id, 1 ether);
        _deliver(id, GOOD);
        address newOp = makeAddr("newOp");
        vm.prank(safe);
        bond.setOperator(newOp);
        vm.prank(newOp); // the new key scores (it was handed the preimage); the OLD staker is credited
        bond.recordScore(spec, 100, E, SALT, 0);
        assertEq(bond.credit(newOp), 0);
        assertEq(bond.credit(op), 1 ether, "the bond came back to the staker with the verdict");
    }

    // test_finding_comparisonIsRawEquality (VB-05): raw equality of the stored 32 bytes, and only for a hash
    // the chain computed. After Olympix 5.1.1 a claimed hash with no bytes never counts as delivered.
    function test_fixed_VB05_rawEqualityOfStoredHash() public {
        bytes memory out = "output";
        bytes32 h = sha256(out);
        (uint256 id, bytes32 spec) = _newJob(1 ether, h, SALT);
        _stake(spec, h, SALT, id, 1 ether);
        _deliver(id, out);
        _score(spec, 100, h, SALT);
        // a claimed hash equal to `expected`, with no bytes, is NOT a delivery: passing it is refused
        bytes32 salt2 = keccak256("salt2");
        (uint256 id2, bytes32 spec2) = _newJob(1 ether, E, salt2);
        _stake(spec2, E, salt2, id2, 1 ether);
        _submit(id2, E);
        vm.prank(op);
        vm.expectRevert(PredgeValidatorBondV2.VerdictContradictsEvidence.selector);
        bond.recordScore(spec2, 100, E, salt2, 0);
    }

    // Parameter boundaries are inclusive.
    function test_paramBoundaries() public {
        vm.startPrank(safe);
        bond.setParams(1, 0);
        bond.setParams(1, 10_000);
        vm.expectRevert(PredgeValidatorBondV2.BadParams.selector);
        bond.setParams(1, 10_001);
        vm.expectRevert(PredgeValidatorBondV2.BadParams.selector);
        bond.setParams(0, 0);
        vm.stopPrank();
    }

    function test_requiredBond_floorEqualsScaled() public {
        assertEq(bond.requiredBond(MIN_BOND), MIN_BOND);
    }
}

contract V1FindingsArbiterTest is ArbiterBase {
    function setUp() public { _deployArbiter(); }

    // test_finding_operatorCanCiteSockPuppetEvidence / test_finding_formerOperatorCanFile
    function test_fixed_sockPuppetEvidence() public {
        uint256 pid = _pay(1 ether);
        address sock = makeAddr("sock");
        vm.prank(sock);
        vm.expectRevert(PredgeRefundArbiterV2.NotAParty.selector);
        arb.fileEvidence(pid, EV_PAYER);
        vm.prank(op);
        vm.expectRevert(PredgeRefundArbiterV2.NotAParty.selector); // the (former) operator is no party either
        arb.fileEvidence(pid, EV_PAYER);
    }

    // test_BUG_rule_truncatesBondAbove2pow96
    function test_fixed_noUint96Truncation() public {
        uint256 big = uint256(type(uint96).max) + 1 ether;
        vm.deal(op, big);
        uint256 pid = rp.recordPayment(payer, payee, 1 ether, block.timestamp + 30 days);
        _file(pid);
        _rule(pid, payer, EV_PAYER, PredgeRefundArbiterV2.Direction.Release, big);
        assertEq(arb.rulings(pid).bond, big);
        assertEq(arb.totalBonded(), big);
    }

    // RA-04 / test_finding_setParamsIsRetroactive and RA-07 window overflow
    function test_fixed_RA04_RA07_paramsBoundedAndNotRetroactive() public {
        uint256 pid = _pay(1 ether);
        _file(pid);
        _rule(pid, payer, EV_PAYER, PredgeRefundArbiterV2.Direction.Release, 1 ether);
        vm.prank(safe);
        vm.expectRevert(PredgeRefundArbiterV2.BadParams.selector);
        arb.setParams(type(uint64).max, 1, 0); // no overflow / no bricked reclaim
        vm.prank(safe);
        arb.setParams(30 days, 1, 0);
        vm.warp(block.timestamp + WINDOW);
        arb.finalize(pid);
    }

    function test_paramBoundaries() public {
        vm.startPrank(safe);
        arb.setParams(1 hours, 1, 0);
        arb.setParams(30 days, 1, 10_000);
        vm.expectRevert(PredgeRefundArbiterV2.BadParams.selector);
        arb.setParams(30 days + 1, 1, 0);
        vm.stopPrank();
    }

    function test_requiredBond_floorEqualsScaled() public view {
        assertEq(arb.requiredBond(MIN_BOND * 10_000 / BPS), MIN_BOND);
    }

    function test_expireKeepsAccounting() public {
        uint256 pid = _pay(1 ether);
        _file(pid);
        _rule(pid, payer, EV_PAYER, PredgeRefundArbiterV2.Direction.Release, 2 ether);
        _rule2();
        vm.warp(block.timestamp + WINDOW + arb.RESOLUTION_TIMEOUT());
        arb.expire(pid);
        assertEq(arb.totalBonded(), 3 ether, "only the other ruling's bond is still held");
    }

    function _rule2() internal {
        uint256 pid = _pay(1 ether);
        _file(pid);
        _rule(pid, payer, EV_PAYER, PredgeRefundArbiterV2.Direction.Release, 3 ether);
    }
}

contract V1FindingsMiscTest is Base {
    function setUp() public { _deployJobAndBond(); }

    // AV-01 / test_BUG_request_frontRunSquatsRequestHash
    function test_fixed_AV01_squattingImpossible() public {
        PredgeAgentValidatorV2 reg = new PredgeAgentValidatorV2(safe, op, address(0));
        vm.prank(stranger);
        vm.expectRevert(PredgeAgentValidatorV2.NotAuthorized.selector);
        reg.validationRequest(op, 1, "squat", keccak256("spec"));
        // and the hash is domain separated, so a squat on another chain/registry cannot collide anyway
        assertTrue(reg.requestHashFor(1, keccak256("spec")) != keccak256("spec"));
    }

    // AV-02 / test_BUG_commitLeadTime_zeroWhenSameBlock: documented, not a bug: zero is possible in the same block.
    function test_fixed_AV02_sameBlockLeadIsZeroAndDocumented() public {
        PredgeAgentValidatorV2 reg = new PredgeAgentValidatorV2(safe, op, address(0));
        vm.startPrank(op);
        bytes32 h = reg.validationRequest(op, 1, "x", keccak256("d"));
        reg.validationResponse(h, 100, "", keccak256("r"), "");
        vm.stopPrank();
        assertEq(reg.commitLeadTime(h), 0);
    }

    // AJ-02 / test_finding_escrowLockedWhenNeitherPartyCanReceive: with pull payments an unreceivable party
    // cannot block settlement and can redirect its credit.
    function test_fixed_AJ02_unreceivableParties() public {
        NoReceive a = new NoReceive();
        NoReceive b = new NoReceive();
        vm.deal(address(a), 1 ether);
        bytes32 spec = _spec(1);
        vm.prank(address(a));
        uint256 id = job.createJob{value: 1 ether}(address(b), op, spec, uint64(block.timestamp + 1 days));
        vm.prank(address(b));
        job.submit(id, keccak256("d"), "");
        vm.prank(op);
        job.reject(id, 0, "");
        assertEq(job.credit(address(a)), 1 ether);
        vm.prank(address(a));
        job.withdrawTo(payable(stranger));
        assertEq(address(job).balance, 0);
    }

    // test_finding_openJobHasNoTimeoutRefund
    function test_fixed_openJobTimeoutRefund() public {
        (uint256 id,) = _newJob(1, 1 ether);
        vm.warp(block.timestamp + 7 days);
        job.claimRefund(id);
        assertEq(job.credit(client), 1 ether);
    }

    // PS-01 / test_finding_withdrawToZeroBurns
    function test_fixed_PS01_withdrawToZeroReverts() public {
        PredgeSettlementV2 s = new PredgeSettlementV2(safe);
        vm.deal(address(s), 1 ether);
        vm.prank(safe);
        vm.expectRevert(Owned2Step.ZeroAddress.selector);
        s.withdraw(payable(address(0)));
    }
}
