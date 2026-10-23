// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AgentJob} from "../../../contracts/AgentJob.sol";
import {PredgeSettlement} from "../../../contracts/PredgeSettlement.sol";
import {PredgeValidatorBond} from "../../../contracts/PredgeValidatorBond.sol";
import {PredgeRefundArbiter} from "../../../contracts/PredgeRefundArbiter.sol";
import {MockRefundProtocol} from "../../../contracts/MockRefundProtocol.sol";
import {FeeOnTransferToken, NoReturnToken, BlacklistUSDC, MockERC20} from "../mocks/MockTokens.sol";

/// All six contracts move value only as the chain's NATIVE token (USDC on Arc). None of them
/// calls an ERC20, so fee-on-transfer, missing-return and blacklist tokens cannot break their
/// accounting. What these tests pin down is the flip side (finding TK-01): ERC20 tokens sent to
/// any of the contracts by mistake are unrecoverable, because there is no sweep function.
contract TokenEdgeCasesTest is Test {
    AgentJob job;
    PredgeSettlement settle;
    PredgeValidatorBond bond;
    PredgeRefundArbiter arb;
    FeeOnTransferToken fot;
    NoReturnToken nrt;
    BlacklistUSDC usdc;
    address user = makeAddr("user");

    function setUp() public {
        job = new AgentJob();
        settle = new PredgeSettlement();
        bond = new PredgeValidatorBond(address(this), address(job), 1 days);
        arb = new PredgeRefundArbiter(address(new MockRefundProtocol(address(0xA))), address(this), 1 days, 1);
        fot = new FeeOnTransferToken(100);
        nrt = new NoReturnToken();
        usdc = new BlacklistUSDC();
        fot.mint(user, 1e24);
        nrt.mint(user, 1e24);
        usdc.mint(user, 1e12);
    }

    function _targets() internal view returns (address[4] memory t) {
        t = [address(job), address(settle), address(bond), address(arb)];
    }

    function test_feeOnTransferToken_arrivesShort_andIsStuck() public {
        address[4] memory t = _targets();
        for (uint256 i; i < 4; i++) {
            vm.prank(user);
            fot.transfer(t[i], 1000);
            assertEq(fot.balanceOf(t[i]), 990, "1% fee burnt in transit");
        }
        // native accounting untouched
        assertEq(address(job).balance + address(settle).balance + address(bond).balance + address(arb).balance, 0);
        assertEq(bond.totalBonded(), 0);
    }

    function test_noReturnToken_transferSucceeds_andIsStuck() public {
        vm.prank(user);
        nrt.transfer(address(settle), 5);
        assertEq(nrt.balanceOf(address(settle)), 5);
        // the only exit is withdraw(), which moves native value only
        settle.withdraw(payable(address(this)));
        assertEq(nrt.balanceOf(address(settle)), 5);
    }

    function test_blacklistUSDC_isIrrelevantToNativeEscrow() public {
        usdc.blacklist(address(job), true);
        vm.prank(user);
        vm.expectRevert(bytes("Blacklistable: account is blacklisted"));
        usdc.transfer(address(job), 1);
        // the native escrow keeps working while the ERC20 blacklist bites
        vm.deal(user, 1 ether);
        vm.prank(user);
        uint256 id = job.createJob{value: 1 ether}(makeAddr("p"), makeAddr("e"), bytes32("s"));
        assertEq(id, 1);
    }

    function test_settlementWithdrawMovesNativeOnly() public {
        vm.prank(user);
        usdc.transfer(address(settle), 1e6);
        vm.deal(address(this), 1 ether);
        settle.payForRoute{value: 1 ether}(bytes32("r"), "");
        settle.withdraw(payable(makeAddr("treasury")));
        assertEq(usdc.balanceOf(address(settle)), 1e6, "USDC (ERC20) stuck: no sweep");
    }

    receive() external payable {}
}
