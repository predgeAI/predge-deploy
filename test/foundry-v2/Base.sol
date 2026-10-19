// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AgentJobV2} from "../../contracts/v2/AgentJobV2.sol";
import {IAgentJobV2} from "../../contracts/v2/interfaces/IAgentJobV2.sol";
import {PredgeValidatorBondV2} from "../../contracts/v2/PredgeValidatorBondV2.sol";
import {PredgeRefundArbiterV2} from "../../contracts/v2/PredgeRefundArbiterV2.sol";
import {MockRefundProtocolV2} from "../../contracts/v2/mocks/MockRefundProtocolV2.sol";

/// @dev A receiver with no receive/fallback: any value sent to it reverts.
contract NoReceive {
    function callWithdraw(address target) external {
        (bool ok, bytes memory ret) = target.call(abi.encodeWithSignature("withdraw()"));
        if (!ok) {
            assembly { revert(add(ret, 32), mload(ret)) }
        }
    }
}

/// @dev Re-enters `withdraw()` on receipt; used to prove the credit is zeroed before the call.
contract ReentrantReceiver {
    address public target;
    bool public reentered;
    bool public reenterFailed;

    function set(address t) external { target = t; }
    function go() external { (bool ok,) = target.call(abi.encodeWithSignature("withdraw()")); require(ok, "outer"); }
    receive() external payable {
        reentered = true;
        (bool ok,) = target.call(abi.encodeWithSignature("withdraw()"));
        reenterFailed = !ok;
    }
}

abstract contract Base is Test {
    address internal safe = makeAddr("safe");
    address internal op = makeAddr("operator");
    address internal client = makeAddr("client");
    address internal provider = makeAddr("provider");
    address internal stranger = makeAddr("stranger");

    uint64 internal constant EVAL_WINDOW = 3 days;
    uint64 internal constant WINDOW = 1 days;
    uint256 internal constant MIN_BOND = 1e15;
    uint16 internal constant BPS = 10_000;

    AgentJobV2 internal job;
    PredgeValidatorBondV2 internal bond;

    function _deployJobAndBond() internal {
        job = new AgentJobV2(EVAL_WINDOW);
        bond = new PredgeValidatorBondV2(safe, op, address(job), WINDOW, MIN_BOND, BPS);
        vm.deal(op, 1_000 ether);
        vm.deal(client, 1_000 ether);
        vm.deal(provider, 10 ether);
        vm.deal(stranger, 10 ether);
    }

    function _spec(uint256 n) internal pure returns (bytes32) {
        return keccak256(abi.encode("spec", n));
    }

    function _commitment(bytes32 expected, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encode(expected, salt));
    }

    /// @dev client opens a job whose evaluator is the bond contract.
    function _newJob(uint256 n, uint256 escrow) internal returns (uint256 id, bytes32 spec) {
        spec = _spec(n);
        vm.prank(client);
        id = job.createJob{value: escrow}(provider, address(bond), spec, uint64(block.timestamp + 7 days));
    }

    function _stake(bytes32 spec, bytes32 expected, bytes32 salt, uint256 id, uint256 value) internal {
        vm.prank(op);
        bond.stakeAndCommit{value: value}(spec, _commitment(expected, salt), id);
    }

    function _submit(uint256 id, bytes32 deliverable) internal {
        vm.prank(provider);
        job.submit(id, deliverable, "");
    }

    function _score(bytes32 spec, uint8 score, bytes32 expected, bytes32 salt) internal {
        vm.prank(op);
        bond.recordScore(spec, score, expected, salt, keccak256("reason"));
    }
}
