// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PredgeAgentValidatorV2} from "../../contracts/v2/PredgeAgentValidatorV2.sol";
import {PredgeSettlementV2} from "../../contracts/v2/PredgeSettlementV2.sol";
import {MockRefundProtocolV2} from "../../contracts/v2/mocks/MockRefundProtocolV2.sol";
import {Owned2Step, Operated} from "../../contracts/v2/access/PredgeAccess.sol";
import {NoReceive} from "./Base.sol";

contract IdentityMock {
    mapping(uint256 => address) public owners;
    bool public broken;
    function set(uint256 id, address o) external { owners[id] = o; }
    function setBroken(bool b) external { broken = b; }
    function ownerOf(uint256 id) external view returns (address) {
        require(!broken && owners[id] != address(0), "ERC721: invalid token ID");
        return owners[id];
    }
}

contract PredgeAgentValidatorV2Test is Test {
    address safe = makeAddr("safe");
    address op = makeAddr("operator");
    address agentOwner = makeAddr("agentOwner");
    address stranger = makeAddr("stranger");
    PredgeAgentValidatorV2 reg;
    PredgeAgentValidatorV2 regId;
    IdentityMock idr;

    event ValidationRequest(address indexed validatorAddress, uint256 indexed agentId, string requestURI, bytes32 indexed requestHash);
    event ValidationResponse(address indexed validatorAddress, uint256 indexed agentId, bytes32 indexed requestHash, uint8 response, string responseURI, bytes32 responseHash, string tag);
    event RequestRecorded(bytes32 indexed requestHash, bytes32 digest, address indexed requester);
    event ResponseRecorded(bytes32 indexed requestHash, address indexed responder, uint64 respondedAt);

    function setUp() public {
        idr = new IdentityMock();
        idr.set(7, agentOwner);
        reg = new PredgeAgentValidatorV2(safe, op, address(0));
        regId = new PredgeAgentValidatorV2(safe, op, address(idr));
    }

    function _req(PredgeAgentValidatorV2 r, uint256 agent, bytes32 d) internal returns (bytes32 h) {
        vm.prank(op);
        h = r.validationRequest(op, agent, "ipfs://req", d);
    }

    function test_requestHash_isDomainSeparated() public {
        bytes32 d = keccak256("d");
        assertEq(reg.requestHashFor(7, d), keccak256(abi.encode(block.chainid, address(reg), uint256(7), d)));
        assertTrue(reg.requestHashFor(7, d) != regId.requestHashFor(7, d), "differs per registry");
        assertTrue(reg.requestHashFor(7, d) != reg.requestHashFor(8, d), "differs per agent");
        bytes32 onThisChain = reg.requestHashFor(7, d);
        vm.chainId(999);
        assertTrue(reg.requestHashFor(7, d) != onThisChain, "differs per chain");
    }

    /// @dev Olympix 5.3.3: an agent-NFT holder cannot pre-claim another agent's digest; the verdict lands on the right agent.
    function test_request_digestCannotBeSquattedAcrossAgents() public {
        bytes32 d = keccak256("victim digest");
        vm.prank(agentOwner); // owns agent 7, front-runs the digest under its own agent
        bytes32 squat = regId.validationRequest(op, 7, "squat", d);
        vm.prank(op); // the legitimate request for agent 1 still goes through, under its own key
        bytes32 legit = regId.validationRequest(op, 1, "legit", d);
        assertTrue(squat != legit);
        vm.prank(op);
        regId.validationResponse(legit, 100, "", keccak256("v"), "");
        bytes32[] memory hs = new bytes32[](2);
        hs[0] = legit; hs[1] = squat;
        (uint64 n1,) = regId.getSummary(1, hs);
        (uint64 n7,) = regId.getSummary(7, hs);
        assertEq(n1, 1, "verdict counted for the requesting agent");
        assertEq(n7, 0, "nothing credited to the squatter");
    }

    /// @dev Olympix 5.3.10: a pending request answered after a rotation records the key that answered.
    function test_response_afterRotationNamesTheResponder() public {
        bytes32 h = _req(reg, 1, keccak256("pending"));
        address newOp = makeAddr("newOp");
        vm.prank(safe);
        reg.setOperator(newOp);
        vm.expectEmit(true, true, true, true);
        emit ValidationResponse(newOp, 1, h, 100, "", keccak256("a"), "");
        vm.prank(newOp);
        reg.validationResponse(h, 100, "", keccak256("a"), "");
        (address v,,,,,) = reg.getValidationStatus(h);
        assertEq(v, newOp);
    }

    function test_request_response_flow() public {
        bytes32 d = keccak256("d");
        bytes32 h = reg.requestHashFor(7, d);
        vm.expectEmit(true, true, true, true);
        emit ValidationRequest(op, 7, "ipfs://req", h);
        vm.expectEmit(true, true, false, true);
        emit RequestRecorded(h, d, op);
        assertEq(_req(reg, 7, d), h);
        assertEq(reg.requestCount(), 1);
        assertEq(reg.requestURIOf(h), "ipfs://req");
        assertFalse(reg.isValidated(h));
        assertEq(reg.commitLeadTime(h), 0);

        vm.warp(block.timestamp + 60);
        vm.expectEmit(true, true, true, true);
        emit ValidationResponse(op, 7, h, 100, "ipfs://resp", keccak256("a"), "tag");
        vm.expectEmit(true, true, false, true);
        emit ResponseRecorded(h, op, uint64(block.timestamp));
        vm.prank(op);
        reg.validationResponse(h, 100, "ipfs://resp", keccak256("a"), "tag");
        assertTrue(reg.isValidated(h));
        assertEq(reg.commitLeadTime(h), 60);
        assertEq(reg.responseURIOf(h), "ipfs://resp");
        (address v, uint256 a, uint8 r, bytes32 rh, string memory tag, uint256 last) = reg.getValidationStatus(h);
        assertEq(v, op); assertEq(a, 7); assertEq(r, 100); assertEq(rh, keccak256("a")); assertEq(tag, "tag"); assertEq(last, block.timestamp);
    }

    function test_status_pendingShowsRequestTime() public {
        bytes32 h = _req(reg, 1, keccak256("p"));
        (,,,,, uint256 last) = reg.getValidationStatus(h);
        assertEq(last, block.timestamp);
    }

    function test_request_isRestricted_M05() public {
        vm.prank(stranger);
        vm.expectRevert(PredgeAgentValidatorV2.NotAuthorized.selector);
        reg.validationRequest(op, 7, "x", keccak256("d"));
        vm.prank(agentOwner); // no identity registry set: agent owners have no standing
        vm.expectRevert(PredgeAgentValidatorV2.NotAuthorized.selector);
        reg.validationRequest(op, 7, "x", keccak256("d"));
    }

    function test_request_agentOwnerViaIdentityRegistry() public {
        vm.prank(agentOwner);
        bytes32 h = regId.validationRequest(op, 7, "x", keccak256("d"));
        assertEq(h, regId.requestHashFor(7, keccak256("d")));
        vm.prank(agentOwner); // owner of agent 7 cannot request for agent 8 (unknown token -> ownerOf reverts)
        vm.expectRevert(PredgeAgentValidatorV2.NotAuthorized.selector);
        regId.validationRequest(op, 8, "x", keccak256("e"));
        vm.prank(stranger);
        vm.expectRevert(PredgeAgentValidatorV2.NotAuthorized.selector);
        regId.validationRequest(op, 7, "x", keccak256("e"));
        idr.setBroken(true);
        vm.prank(agentOwner);
        vm.expectRevert(PredgeAgentValidatorV2.NotAuthorized.selector);
        regId.validationRequest(op, 7, "x", keccak256("e"));
    }

    function test_request_reverts() public {
        vm.startPrank(op);
        vm.expectRevert(PredgeAgentValidatorV2.ZeroHash.selector);
        reg.validationRequest(op, 1, "x", bytes32(0));
        vm.expectRevert(PredgeAgentValidatorV2.WrongValidator.selector);
        reg.validationRequest(stranger, 1, "x", keccak256("d"));
        reg.validationRequest(op, 1, "x", keccak256("d"));
        vm.expectRevert(PredgeAgentValidatorV2.AlreadyRequested.selector);
        reg.validationRequest(op, 1, "x", keccak256("d"));
        vm.stopPrank();
    }

    function test_response_reverts() public {
        bytes32 h = _req(reg, 1, keccak256("d"));
        vm.prank(stranger);
        vm.expectRevert(Operated.NotOperator.selector);
        reg.validationResponse(h, 1, "", keccak256("a"), "");
        vm.startPrank(op);
        vm.expectRevert(PredgeAgentValidatorV2.BadScore.selector);
        reg.validationResponse(h, 101, "", keccak256("a"), "");
        vm.expectRevert(PredgeAgentValidatorV2.ZeroHash.selector);
        reg.validationResponse(h, 1, "", bytes32(0), "");
        vm.expectRevert(PredgeAgentValidatorV2.NotRequested.selector);
        reg.validationResponse(keccak256("never"), 1, "", keccak256("a"), "");
        reg.validationResponse(h, 0, "", keccak256("a"), "");
        vm.expectRevert(PredgeAgentValidatorV2.AlreadyResponded.selector);
        reg.validationResponse(h, 1, "", keccak256("b"), "");
        vm.stopPrank();
        assertEq(reg.responseCount(), 1);
    }

    function test_rotationNeverRewritesPastVerdict() public {
        bytes32 h = _req(reg, 1, keccak256("d"));
        vm.prank(op);
        reg.validationResponse(h, 100, "", keccak256("a"), "");
        address newOp = makeAddr("new");
        vm.prank(safe);
        reg.setOperator(newOp);
        vm.prank(newOp);
        vm.expectRevert(PredgeAgentValidatorV2.AlreadyResponded.selector);
        reg.validationResponse(h, 0, "", keccak256("z"), "");
        (, , uint8 r, , ,) = reg.getValidationStatus(h);
        assertEq(r, 100);
    }

    function test_getSummary_dedupes_L06() public {
        bytes32 a = _req(reg, 1, keccak256("a"));
        bytes32 b = _req(reg, 1, keccak256("b"));
        bytes32 c = _req(reg, 2, keccak256("c"));
        bytes32 pending = _req(reg, 1, keccak256("p"));
        vm.startPrank(op);
        reg.validationResponse(a, 100, "", keccak256("1"), "");
        reg.validationResponse(b, 0, "", keccak256("2"), "");
        reg.validationResponse(c, 100, "", keccak256("3"), "");
        vm.stopPrank();
        bytes32[] memory hs = new bytes32[](7);
        hs[0] = a; hs[1] = a; hs[2] = a; hs[3] = b; hs[4] = c; hs[5] = pending; hs[6] = keccak256("unknown");
        (uint64 n, uint8 avg) = reg.getSummary(1, hs);
        assertEq(n, 2, "a counted once, not three times");
        assertEq(avg, 50);
        (n, avg) = reg.getSummary(9, hs);
        assertEq(n, 0);
        assertEq(avg, 0);
    }

    function test_getSummary_capped() public {
        vm.expectRevert(PredgeAgentValidatorV2.TooManyHashes.selector);
        reg.getSummary(1, new bytes32[](101));
        reg.getSummary(1, new bytes32[](100));
    }

    function testFuzz_summaryIgnoresDuplicates(uint8 dup) public {
        dup = uint8(bound(dup, 1, 50));
        bytes32 a = _req(reg, 1, keccak256("a"));
        vm.prank(op);
        reg.validationResponse(a, 100, "", keccak256("1"), "");
        bytes32[] memory hs = new bytes32[](dup);
        for (uint256 i; i < dup; ++i) hs[i] = a;
        (uint64 n, uint8 avg) = reg.getSummary(1, hs);
        assertEq(n, 1);
        assertEq(avg, 100);
    }
}

contract AccessTest is Test {
    address safe = makeAddr("safe");
    address op = makeAddr("operator");
    address next = makeAddr("next");
    PredgeSettlementV2 s;
    PredgeAgentValidatorV2 reg;

    event OwnershipTransferStarted(address indexed previousOwner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OperatorUpdated(address indexed previousOperator, address indexed newOperator);

    function setUp() public {
        s = new PredgeSettlementV2(safe);
        reg = new PredgeAgentValidatorV2(safe, op, address(0));
    }

    function mkS(address o) external returns (address) { return address(new PredgeSettlementV2(o)); }
    function mkR(address o, address p) external returns (address) { return address(new PredgeAgentValidatorV2(o, p, address(0))); }

    function test_constructorZeroOwnerOrOperator() public {
        vm.expectRevert(Owned2Step.ZeroAddress.selector);
        this.mkS(address(0));
        vm.expectRevert(Owned2Step.ZeroAddress.selector);
        this.mkR(address(0), op);
        vm.expectRevert(Owned2Step.ZeroAddress.selector);
        this.mkR(safe, address(0));
    }

    function test_deployerHoldsNoRole() public view {
        assertEq(s.owner(), safe);
        assertTrue(s.owner() != address(this));
        assertEq(reg.operator(), op);
    }

    function test_twoStepOwnership() public {
        vm.prank(op);
        vm.expectRevert(Owned2Step.NotOwner.selector);
        s.transferOwnership(next);

        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferStarted(safe, next);
        vm.prank(safe);
        s.transferOwnership(next);
        assertEq(s.owner(), safe, "nomination alone changes nothing");
        assertEq(s.pendingOwner(), next);

        vm.prank(op);
        vm.expectRevert(Owned2Step.NotPendingOwner.selector);
        s.acceptOwnership();

        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferred(safe, next);
        vm.prank(next);
        s.acceptOwnership();
        assertEq(s.owner(), next);
        assertEq(s.pendingOwner(), address(0));

        vm.prank(safe);
        vm.expectRevert(Owned2Step.NotOwner.selector);
        s.transferOwnership(safe);
    }

    function test_nominationCanBeCancelled() public {
        vm.startPrank(safe);
        s.transferOwnership(next);
        s.transferOwnership(address(0));
        vm.stopPrank();
        vm.prank(next);
        vm.expectRevert(Owned2Step.NotPendingOwner.selector);
        s.acceptOwnership();
    }

    function test_noRenounce() public {
        (bool ok,) = address(s).call(abi.encodeWithSignature("renounceOwnership()"));
        assertFalse(ok, "there is no renounceOwnership");
        assertEq(s.owner(), safe);
    }

    function test_setOperator() public {
        address n = makeAddr("n");
        vm.prank(op);
        vm.expectRevert(Owned2Step.NotOwner.selector);
        reg.setOperator(n);
        vm.startPrank(safe);
        vm.expectRevert(Owned2Step.ZeroAddress.selector);
        reg.setOperator(address(0));
        vm.expectEmit(true, true, false, false);
        emit OperatorUpdated(op, n);
        reg.setOperator(n);
        vm.stopPrank();
        assertEq(reg.operator(), n);
        vm.prank(op);
        vm.expectRevert(Operated.NotOperator.selector);
        reg.validationResponse(bytes32(uint256(1)), 1, "", bytes32(uint256(1)), "");
    }
}

contract PredgeSettlementV2Test is Test {
    address safe = makeAddr("safe");
    address payer = makeAddr("payer");
    PredgeSettlementV2 s;

    event Paid(address indexed payer, bytes32 indexed route, uint256 amount, uint256 timestamp, string meta);
    event Withdrawn(address indexed to, uint256 amount);

    function setUp() public {
        s = new PredgeSettlementV2(safe);
        vm.deal(payer, 10 ether);
    }

    function test_pay_and_receive() public {
        vm.expectEmit(true, true, false, true);
        emit Paid(payer, bytes32("r"), 5, block.timestamp, "meta");
        vm.prank(payer);
        s.payForRoute{value: 5}(bytes32("r"), "meta");
        vm.expectEmit(true, true, false, true);
        emit Paid(payer, bytes32("direct"), 7, block.timestamp, "");
        vm.prank(payer);
        (bool ok,) = address(s).call{value: 7}("");
        assertTrue(ok);
        assertEq(address(s).balance, 12);
    }

    function test_zeroPaymentReverts() public {
        vm.expectRevert(PredgeSettlementV2.ZeroPayment.selector);
        s.payForRoute(bytes32("r"), "");
        (bool ok, bytes memory ret) = address(s).call("");
        assertFalse(ok);
        assertEq(bytes4(ret), PredgeSettlementV2.ZeroPayment.selector);
    }

    function test_withdraw_ownerOnly_eventBeforeCall() public {
        vm.prank(payer);
        s.payForRoute{value: 9}(bytes32("r"), "");
        vm.prank(payer);
        vm.expectRevert(Owned2Step.NotOwner.selector);
        s.withdraw(payable(payer));
        vm.expectEmit(true, false, false, true);
        emit Withdrawn(safe, 9);
        vm.prank(safe);
        s.withdraw(payable(safe));
        assertEq(safe.balance, 9);
        assertEq(address(s).balance, 0);
    }

    function test_withdraw_zeroAddressRejected_L05() public {
        vm.prank(payer);
        s.payForRoute{value: 9}(bytes32("r"), "");
        vm.prank(safe);
        vm.expectRevert(Owned2Step.ZeroAddress.selector);
        s.withdraw(payable(address(0)));
        assertEq(address(s).balance, 9, "nothing burned");
    }

    function test_withdraw_failedTransferReverts() public {
        NoReceive bad = new NoReceive();
        vm.prank(safe);
        vm.expectRevert(PredgeSettlementV2.WithdrawFailed.selector);
        s.withdraw(payable(address(bad)));
    }

    function test_forcedValueIsWithdrawable() public {
        vm.deal(address(s), 3 ether); // simulates forced (selfdestruct / coinbase) value
        vm.prank(safe);
        s.withdraw(payable(safe));
        assertEq(safe.balance, 3 ether);
    }
}

contract MockRefundProtocolV2Test is Test {
    MockRefundProtocolV2 m;
    address arbiter = makeAddr("arbiter");
    address a = makeAddr("a");
    address b = makeAddr("b");

    function setUp() public {
        m = new MockRefundProtocolV2(arbiter);
    }

    function mkM(address a_) external returns (address) { return address(new MockRefundProtocolV2(a_)); }

    function test_zeroArbiter() public {
        vm.expectRevert(MockRefundProtocolV2.ZeroAddress.selector);
        this.mkM(address(0));
    }

    function test_record_and_info() public {
        vm.expectRevert(MockRefundProtocolV2.ZeroAddress.selector);
        m.recordPayment(address(0), b, 1, 1);
        vm.expectRevert(MockRefundProtocolV2.ZeroAddress.selector);
        m.recordPayment(a, address(0), 1, 1);
        uint256 id = m.recordPayment(a, b, 5, 100);
        (address p, address q, uint256 amt, uint256 rel) = m.paymentInfo(id);
        assertEq(p, a); assertEq(q, b); assertEq(amt, 5); assertEq(rel, 100);
    }

    function test_refund_guards() public {
        uint256 id = m.recordPayment(a, b, 5, block.timestamp + 10);
        vm.expectRevert(MockRefundProtocolV2.CallerNotArbiter.selector);
        m.refundByArbiter(id);
        vm.startPrank(arbiter);
        vm.expectRevert(MockRefundProtocolV2.UnknownPayment.selector);
        m.refundByArbiter(99);
        m.refundByArbiter(id);
        vm.expectRevert(MockRefundProtocolV2.AlreadyRefunded.selector);
        m.refundByArbiter(id);
        uint256 id2 = m.recordPayment(a, b, 5, block.timestamp + 10);
        vm.warp(block.timestamp + 10);
        vm.expectRevert(MockRefundProtocolV2.AlreadyReleased.selector);
        m.refundByArbiter(id2);
        vm.stopPrank();
        assertEq(m.refundCount(), 1);
    }

    function test_lockup_arbiterOnly() public {
        vm.expectRevert(MockRefundProtocolV2.CallerNotArbiter.selector);
        m.setLockupSeconds(a, 1);
        vm.prank(arbiter);
        m.setLockupSeconds(a, 1);
        assertEq(m.lockupSeconds(a), 1);
    }
}
