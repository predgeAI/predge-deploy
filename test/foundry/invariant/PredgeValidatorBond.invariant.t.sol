// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AgentJob} from "../../../contracts/AgentJob.sol";
import {PredgeValidatorBond} from "../../../contracts/PredgeValidatorBond.sol";

contract BondHandler is Test {
    AgentJob public job;
    PredgeValidatorBond public bond;
    address public val;
    address internal provider = address(0xBEEF);
    address internal client = address(0xC1);
    uint64 public window;

    bytes32[] public reqs;
    mapping(bytes32 => uint256) public exits; // slashes + reclaims
    uint256 public totalIn;
    uint256 public totalOut;
    bool public earlyReclaim;
    bool public honestSlashed;
    bool public unauthorizedSucceeded;

    constructor(AgentJob j, PredgeValidatorBond b, address v, uint64 w) {
        job = j;
        bond = b;
        val = v;
        window = w;
    }

    function reqCount() external view returns (uint256) {
        return reqs.length;
    }

    function _req(uint256 seed) internal view returns (bytes32) {
        return reqs.length == 0 ? bytes32(0) : reqs[seed % reqs.length];
    }

    function open(uint96 amt, bytes32 expected) external {
        if (expected == bytes32(0)) expected = bytes32(uint256(1));
        amt = uint96(bound(amt, 1, 10 ether));
        bytes32 r = keccak256(abi.encode("req", reqs.length));
        vm.deal(client, 1 ether);
        vm.prank(client);
        uint256 id = job.createJob{value: 1}(provider, val, r);
        vm.deal(val, val.balance + amt);
        vm.prank(val);
        bond.stakeAndCommit{value: amt}(r, expected, id);
        reqs.push(r);
        totalIn += amt;
    }

    function submit(uint256 seed, bool matchExpected, bytes32 other) external {
        bytes32 r = _req(seed);
        if (r == bytes32(0)) return;
        (bytes32 expected, , , , , , uint256 id, ) = bond.stakes(r);
        vm.prank(provider);
        try job.submit(id, matchExpected ? expected : other, "") {} catch {}
    }

    function score(uint256 seed, bool pass) external {
        bytes32 r = _req(seed);
        if (r == bytes32(0)) return;
        vm.prank(val);
        try bond.recordScore(r, pass ? 100 : 0) {} catch {}
    }

    function challenge(uint256 seed, address who) external {
        bytes32 r = _req(seed);
        if (r == bytes32(0) || who.code.length > 0 || uint160(who) < 0x10000) return;
        bool lie = bond.wouldSlash(r);
        (, uint96 b, , , , , , ) = bond.stakes(r);
        uint256 before = who.balance;
        vm.prank(who);
        try bond.challenge(r) {
            if (!lie) honestSlashed = true;
            exits[r]++;
            totalOut += b;
            assertEq(who.balance, before + b);
        } catch {}
    }

    function reclaim(uint256 seed) external {
        bytes32 r = _req(seed);
        if (r == bytes32(0)) return;
        (, uint96 b, , , , , , uint64 scoredAt) = bond.stakes(r);
        vm.prank(val);
        try bond.reclaim(r) {
            if (block.timestamp < uint256(scoredAt) + window) earlyReclaim = true;
            exits[r]++;
            totalOut += b;
        } catch {}
    }

    function intruderReclaim(uint256 seed, address who) external {
        bytes32 r = _req(seed);
        if (r == bytes32(0) || who == val) return;
        vm.prank(who);
        try bond.reclaim(r) {
            unauthorizedSucceeded = true;
        } catch {}
        vm.prank(who);
        try bond.recordScore(r, 100) {
            unauthorizedSucceeded = true;
        } catch {}
    }

    function warp(uint32 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 3 days));
    }
}

contract PredgeValidatorBondInvariantTest is Test {
    AgentJob job;
    PredgeValidatorBond bond;
    BondHandler h;
    address val = address(0x7A1);

    function setUp() public {
        vm.warp(1_700_000_000);
        job = new AgentJob();
        bond = new PredgeValidatorBond(val, address(job), 1 days);
        h = new BondHandler(job, bond, val, 1 days);
        targetContract(address(h));
    }

    function invariant_balanceCoversTotalBonded() public view {
        assertEq(address(bond).balance, bond.totalBonded());
    }

    function invariant_totalBondedIsSumOfOpenBonds() public view {
        uint256 sum;
        for (uint256 i; i < h.reqCount(); i++) {
            (, uint96 b, , , , bool closed, , ) = bond.stakes(h.reqs(i));
            if (closed) assertEq(b, 0, "closed stake keeps bond");
            else sum += b;
        }
        assertEq(sum, bond.totalBonded());
    }

    function invariant_conservation() public view {
        assertEq(h.totalIn(), h.totalOut() + address(bond).balance);
    }

    function invariant_noDoubleExit() public view {
        for (uint256 i; i < h.reqCount(); i++) assertLe(h.exits(h.reqs(i)), 1);
    }

    function invariant_noReclaimInsideWindow() public view {
        assertFalse(h.earlyReclaim());
    }

    function invariant_honestVerdictNeverSlashed() public view {
        assertFalse(h.honestSlashed());
    }

    function invariant_onlyValidatorScoresAndReclaims() public view {
        assertFalse(h.unauthorizedSucceeded());
    }
}
