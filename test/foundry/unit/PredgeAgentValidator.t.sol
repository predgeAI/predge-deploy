// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PredgeAgentValidator} from "../../../contracts/PredgeAgentValidator.sol";

contract PredgeAgentValidatorTest is Test {
    PredgeAgentValidator reg;
    address owner = makeAddr("owner");
    address val = makeAddr("validator");
    address val2 = makeAddr("validator2");
    address stranger = makeAddr("stranger");
    bytes32 constant H = keccak256("acceptance-test");
    bytes32 constant RH = keccak256("attestation");

    event ValidationRequest(address indexed validatorAddress, uint256 indexed agentId, string requestURI, bytes32 indexed requestHash);
    event ValidationResponse(address indexed validatorAddress, uint256 indexed agentId, bytes32 indexed requestHash, uint8 response, string responseURI, bytes32 responseHash, string tag);
    event ValidatorUpdated(address indexed previousValidator, address indexed newValidator);

    function setUp() public {
        vm.warp(1_700_000_000);
        vm.prank(owner);
        reg = new PredgeAgentValidator(val);
    }

    function _req(bytes32 h, uint256 agentId) internal {
        reg.validationRequest(val, agentId, "ipfs://req", h);
    }

    function _resp(bytes32 h, uint8 score) internal {
        vm.prank(val);
        reg.validationResponse(h, score, "ipfs://resp", RH, "predge/commit-before-outcome");
    }

    // ───────────── constructor / admin ─────────────
    function test_constructor() public view {
        assertEq(reg.owner(), owner);
        assertEq(reg.validator(), val);
        assertEq(reg.requestCount(), 0);
        assertEq(reg.responseCount(), 0);
    }

    function test_constructor_revert_zeroValidator() public {
        vm.expectRevert(PredgeAgentValidator.ZeroAddress.selector);
        new PredgeAgentValidator(address(0));
    }

    function test_setValidator() public {
        vm.expectEmit(true, true, false, false, address(reg));
        emit ValidatorUpdated(val, val2);
        vm.prank(owner);
        reg.setValidator(val2);
        assertEq(reg.validator(), val2);
    }

    function test_setValidator_revert_notOwner() public {
        vm.prank(val);
        vm.expectRevert(PredgeAgentValidator.NotOwner.selector);
        reg.setValidator(val2);
    }

    function test_setValidator_revert_zero() public {
        vm.prank(owner);
        vm.expectRevert(PredgeAgentValidator.ZeroAddress.selector);
        reg.setValidator(address(0));
    }

    // ───────────── validationRequest ─────────────
    function test_request_records() public {
        vm.expectEmit(true, true, true, true, address(reg));
        emit ValidationRequest(val, 7, "ipfs://req", H);
        vm.prank(stranger);
        _req(H, 7);
        assertEq(reg.requestCount(), 1);
        assertEq(reg.requestURIOf(H), "ipfs://req");
        (address v, uint256 a, uint8 r, bytes32 rh, string memory tag, uint256 last) = reg.getValidationStatus(H);
        assertEq(v, val);
        assertEq(a, 7);
        assertEq(r, 0);
        assertEq(rh, bytes32(0));
        assertEq(tag, "");
        assertEq(last, block.timestamp, "lastUpdate = requestedAt while pending");
        assertFalse(reg.isValidated(H));
        assertEq(reg.commitLeadTime(H), 0);
    }

    function test_request_revert_zeroHash() public {
        vm.expectRevert(PredgeAgentValidator.ZeroHash.selector);
        _req(bytes32(0), 1);
    }

    function test_request_revert_wrongValidator() public {
        vm.expectRevert(PredgeAgentValidator.NotValidator.selector);
        reg.validationRequest(val2, 1, "", H);
    }

    function test_request_revert_duplicate() public {
        _req(H, 1);
        vm.expectRevert(PredgeAgentValidator.AlreadyRequested.selector);
        _req(H, 2);
    }

    /// BUG (AV-01): validationRequest is permissionless and first-writer-wins, so anyone who sees
    /// a pending request in the mempool can front-run it with the same requestHash and a
    /// different agentId / requestURI. The honest request then reverts AlreadyRequested and the
    /// validator's eventual verdict is attributed (in events and getSummary) to the squatter's
    /// agentId. The honest requester should be able to bind requestHash to its own agentId.
    function test_BUG_request_frontRunSquatsRequestHash() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        reg.validationRequest(val, 666, "ipfs://attacker", H); // front-run
        vm.prank(stranger);
        _req(H, 7); // the honest agent's request: should succeed, reverts AlreadyRequested
        (, uint256 agentId, , , , ) = reg.getValidationStatus(H);
        assertEq(agentId, 7, "verdict bound to squatter's agentId");
    }

    // ───────────── validationResponse ─────────────
    function test_response_records() public {
        _req(H, 7);
        vm.warp(block.timestamp + 100);
        vm.expectEmit(true, true, true, true, address(reg));
        emit ValidationResponse(val, 7, H, 100, "ipfs://resp", RH, "predge/commit-before-outcome");
        _resp(H, 100);
        assertEq(reg.responseCount(), 1);
        assertTrue(reg.isValidated(H));
        assertEq(reg.commitLeadTime(H), 100);
        assertEq(reg.responseURIOf(H), "ipfs://resp");
        (, , uint8 r, bytes32 rh, string memory tag, uint256 last) = reg.getValidationStatus(H);
        assertEq(r, 100);
        assertEq(rh, RH);
        assertEq(tag, "predge/commit-before-outcome");
        assertEq(last, block.timestamp, "lastUpdate = respondedAt");
    }

    function test_response_zeroScoreIsRealVerdict() public {
        _req(H, 1);
        _resp(H, 0);
        assertTrue(reg.isValidated(H));
    }

    function test_response_revert_notValidator() public {
        _req(H, 1);
        vm.prank(stranger);
        vm.expectRevert(PredgeAgentValidator.NotValidator.selector);
        reg.validationResponse(H, 100, "", RH, "");
    }

    function testFuzz_response_revert_badScore(uint8 score) public {
        score = uint8(bound(score, 101, 255));
        _req(H, 1);
        vm.prank(val);
        vm.expectRevert(PredgeAgentValidator.BadScore.selector);
        reg.validationResponse(H, score, "", RH, "");
    }

    function test_response_boundaryScore100ok_101reverts() public {
        _req(H, 1);
        vm.prank(val);
        vm.expectRevert(PredgeAgentValidator.BadScore.selector);
        reg.validationResponse(H, 101, "", RH, "");
        _resp(H, 100);
    }

    function test_response_revert_zeroResponseHash() public {
        _req(H, 1);
        vm.prank(val);
        vm.expectRevert(PredgeAgentValidator.ZeroHash.selector);
        reg.validationResponse(H, 100, "", bytes32(0), "");
    }

    function test_response_revert_notRequested() public {
        vm.prank(val);
        vm.expectRevert(PredgeAgentValidator.NotRequested.selector);
        reg.validationResponse(H, 100, "", RH, "");
    }

    function test_response_revert_alreadyResponded_cannotFlip() public {
        _req(H, 1);
        _resp(H, 100);
        vm.prank(val);
        vm.expectRevert(PredgeAgentValidator.AlreadyResponded.selector);
        reg.validationResponse(H, 0, "", keccak256("flip"), "");
        (, , uint8 r, , , ) = reg.getValidationStatus(H);
        assertEq(r, 100);
    }

    function test_rotation_oldValidatorLocked_newCanAnswer_pastVerdictKept() public {
        bytes32 h2 = keccak256("second");
        _req(H, 1);
        _resp(H, 100);
        _req(h2, 1); // requested under old validator
        vm.prank(owner);
        reg.setValidator(val2);
        vm.prank(val);
        vm.expectRevert(PredgeAgentValidator.NotValidator.selector);
        reg.validationResponse(h2, 0, "", RH, "");
        vm.prank(val2);
        reg.validationResponse(h2, 0, "", RH, "");
        (address v, , , , , ) = reg.getValidationStatus(h2);
        assertEq(v, val, "stored validator stays the one named at request time");
        (, , uint8 r, , , ) = reg.getValidationStatus(H);
        assertEq(r, 100);
        // after rotation, a request naming the old validator is rejected
        vm.expectRevert(PredgeAgentValidator.NotValidator.selector);
        reg.validationRequest(val, 1, "", keccak256("third"));
    }

    /// BUG (AV-02, low): commitLeadTime's NatSpec promises "Non-zero on every answered request",
    /// but a request and its response in the same block give 0: commit-before-outcome is not
    /// enforced as strictly-before by the chain.
    function test_BUG_commitLeadTime_zeroWhenSameBlock() public {
        _req(H, 1);
        _resp(H, 100);
        assertGt(reg.commitLeadTime(H), 0, "same-block response gives zero lead time");
    }

    // ───────────── getSummary ─────────────
    function test_getSummary_filtersByAgentAndAnswered() public {
        bytes32[] memory hs = new bytes32[](5);
        for (uint256 i; i < 5; i++) hs[i] = keccak256(abi.encode(i));
        _req(hs[0], 1);
        _resp(hs[0], 100);
        _req(hs[1], 1);
        _resp(hs[1], 50);
        _req(hs[2], 1); // pending
        _req(hs[3], 2);
        _resp(hs[3], 0); // other agent
        // hs[4] never requested
        (uint64 n, uint8 avg) = reg.getSummary(1, hs);
        assertEq(n, 2);
        assertEq(avg, 75);
        (n, avg) = reg.getSummary(2, hs);
        assertEq(n, 1);
        assertEq(avg, 0);
        (n, avg) = reg.getSummary(3, hs);
        assertEq(n, 0);
        assertEq(avg, 0);
        (n, avg) = reg.getSummary(1, new bytes32[](0));
        assertEq(n, 0);
    }

    function test_getSummary_roundsDown() public {
        bytes32[] memory hs = new bytes32[](3);
        uint8[3] memory s = [uint8(100), 0, 0];
        for (uint256 i; i < 3; i++) {
            hs[i] = keccak256(abi.encode(i));
            _req(hs[i], 9);
            _resp(hs[i], s[i]);
        }
        (uint64 n, uint8 avg) = reg.getSummary(9, hs);
        assertEq(n, 3);
        assertEq(avg, 33);
    }

    /// Duplicate hashes in the input are each counted (caller-controlled; informational).
    function test_getSummary_countsDuplicates() public {
        _req(H, 1);
        _resp(H, 100);
        bytes32[] memory hs = new bytes32[](3);
        hs[0] = H;
        hs[1] = H;
        hs[2] = H;
        (uint64 n, ) = reg.getSummary(1, hs);
        assertEq(n, 3);
    }

    function testFuzz_getSummary_averageMatches(uint8[8] memory scores, uint8 count) public {
        count = uint8(bound(count, 1, 8));
        bytes32[] memory hs = new bytes32[](count);
        uint256 sum;
        for (uint256 i; i < count; i++) {
            uint8 sc = uint8(bound(scores[i], 0, 100));
            hs[i] = keccak256(abi.encode("f", i));
            _req(hs[i], 5);
            _resp(hs[i], sc);
            sum += sc;
        }
        (uint64 n, uint8 avg) = reg.getSummary(5, hs);
        assertEq(n, count);
        assertEq(avg, uint8(sum / count));
        assertLe(avg, 100);
    }

    function testFuzz_requestThenResponse_writeOnce(bytes32 h, uint256 agentId, uint8 score, bytes32 rh, uint32 dt) public {
        vm.assume(h != bytes32(0) && rh != bytes32(0));
        score = uint8(bound(score, 0, 100));
        reg.validationRequest(val, agentId, "u", h);
        vm.warp(block.timestamp + dt);
        vm.prank(val);
        reg.validationResponse(h, score, "r", rh, "t");
        assertEq(reg.commitLeadTime(h), dt);
        vm.prank(val);
        vm.expectRevert(PredgeAgentValidator.AlreadyResponded.selector);
        reg.validationResponse(h, score, "r", rh, "t");
    }
}
