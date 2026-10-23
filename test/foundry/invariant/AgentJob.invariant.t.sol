// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AgentJob} from "../../../contracts/AgentJob.sol";

contract AgentJobHandler is Test {
    AgentJob public job;
    address[3] internal clients = [address(0xC1), address(0xC2), address(0xC3)];
    address[3] internal providers = [address(0xA1), address(0xA2), address(0xA3)];
    address[2] internal evaluators = [address(0xE1), address(0xE2)];

    uint256 public deposited;
    uint256 public paidOut;
    uint256 public refunded;
    mapping(uint256 => uint256) public settlements; // per job: successful complete+reject
    mapping(uint256 => uint8) public lastState;
    bool public regressed;
    bool public unauthorizedSucceeded;

    constructor(AgentJob j) {
        job = j;
    }

    function _id(uint256 seed) internal view returns (uint256) {
        uint256 n = job.jobCount();
        return n == 0 ? 1 : bound(seed, 1, n);
    }

    function _track(uint256 id) internal {
        (AgentJob.State s, , , , ) = job.jobState(id);
        if (uint8(s) < lastState[id]) regressed = true;
        lastState[id] = uint8(s);
    }

    function create(uint256 c, uint256 p, uint256 e, uint96 amt) external {
        amt = uint96(bound(amt, 1, 100 ether));
        address client = clients[c % 3];
        vm.deal(client, client.balance + amt);
        vm.prank(client);
        uint256 id = job.createJob{value: amt}(providers[p % 3], evaluators[e % 2], keccak256(abi.encode(id_(), c)));
        deposited += amt;
        _track(id);
    }

    function id_() internal view returns (uint256) {
        return job.jobCount() + 1;
    }

    function submit(uint256 seed, bytes32 d) external {
        uint256 id = _id(seed);
        (, address provider, , , , , , ) = job.jobs(id);
        vm.prank(provider);
        try job.submit(id, d, "") {} catch {}
        _track(id);
    }

    function complete(uint256 seed, bytes32 r) external {
        uint256 id = _id(seed);
        (, address provider, address evaluator, uint96 esc, , , , ) = job.jobs(id);
        uint256 before = provider.balance;
        vm.prank(evaluator);
        try job.complete(id, r, "") {
            settlements[id]++;
            paidOut += esc;
            assertEq(provider.balance, before + esc);
        } catch {}
        _track(id);
    }

    function reject(uint256 seed, bytes32 r) external {
        uint256 id = _id(seed);
        (address client, , address evaluator, uint96 esc, , , , ) = job.jobs(id);
        uint256 before = client.balance;
        vm.prank(evaluator);
        try job.reject(id, r, "") {
            settlements[id]++;
            refunded += esc;
            assertEq(client.balance, before + esc);
        } catch {}
        _track(id);
    }

    /// Random non-evaluator tries to settle; random non-provider tries to submit.
    function intruder(uint256 seed, address who, bool pass) external {
        uint256 id = _id(seed);
        (, address provider, address evaluator, , , , , ) = job.jobs(id);
        if (who == evaluator || who == provider) return;
        vm.startPrank(who);
        try job.submit(id, bytes32("x"), "") {
            unauthorizedSucceeded = true;
        } catch {}
        if (pass) {
            try job.complete(id, bytes32("x"), "") {
                unauthorizedSucceeded = true;
            } catch {}
        } else {
            try job.reject(id, bytes32("x"), "") {
                unauthorizedSucceeded = true;
            } catch {}
        }
        vm.stopPrank();
        _track(id);
    }
}

contract AgentJobInvariantTest is Test {
    AgentJob job;
    AgentJobHandler h;

    function setUp() public {
        job = new AgentJob();
        h = new AgentJobHandler(job);
        targetContract(address(h));
    }

    /// Contract balance == sum of escrow of jobs not yet settled.
    function invariant_balanceEqualsOutstandingEscrow() public view {
        uint256 sum;
        for (uint256 i = 1; i <= job.jobCount(); i++) {
            (AgentJob.State s, , , , uint96 esc) = job.jobState(i);
            if (s == AgentJob.State.Open || s == AgentJob.State.Submitted) sum += esc;
            else assertEq(esc, 0, "settled job keeps escrow");
        }
        assertEq(address(job).balance, sum);
    }

    function invariant_valueConserved() public view {
        assertEq(h.deposited(), h.paidOut() + h.refunded() + address(job).balance);
    }

    function invariant_settledAtMostOnce() public view {
        for (uint256 i = 1; i <= job.jobCount(); i++) assertLe(h.settlements(i), 1);
    }

    function invariant_stateOnlyForward() public view {
        assertFalse(h.regressed());
    }

    function invariant_onlyRolesAct() public view {
        assertFalse(h.unauthorizedSucceeded());
    }
}
