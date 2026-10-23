// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PredgeSettlement} from "../../../contracts/PredgeSettlement.sol";
import {ToggleReceiver, Reenterer, ForceSend} from "../utils/Actors.sol";

contract PredgeSettlementTest is Test {
    PredgeSettlement s;
    address owner = makeAddr("owner");
    address payer = makeAddr("payer");
    address payable treasury = payable(makeAddr("treasury"));
    bytes32 constant ROUTE = keccak256("v1/wallets/{address}");

    event Paid(address indexed payer, bytes32 indexed route, uint256 amount, uint256 timestamp, string meta);
    event Withdrawn(address indexed to, uint256 amount);

    function setUp() public {
        vm.prank(owner);
        s = new PredgeSettlement();
        vm.deal(payer, 100 ether);
    }

    function test_constructor_owner() public view {
        assertEq(s.owner(), owner);
    }

    function test_payForRoute_emitsReceipt() public {
        vm.expectEmit(true, true, false, true, address(s));
        emit Paid(payer, ROUTE, 1 ether, block.timestamp, "0xabc");
        vm.prank(payer);
        s.payForRoute{value: 1 ether}(ROUTE, "0xabc");
        assertEq(address(s).balance, 1 ether);
    }

    function test_payForRoute_revert_zero() public {
        vm.prank(payer);
        vm.expectRevert(PredgeSettlement.ZeroPayment.selector);
        s.payForRoute(ROUTE, "");
    }

    function test_receive_emitsDirectReceipt() public {
        vm.expectEmit(true, true, false, true, address(s));
        emit Paid(payer, bytes32("direct"), 2 ether, block.timestamp, "");
        vm.prank(payer);
        (bool ok, ) = address(s).call{value: 2 ether}("");
        assertTrue(ok);
        assertEq(address(s).balance, 2 ether);
    }

    function test_receive_revert_zero() public {
        vm.prank(payer);
        (bool ok, bytes memory ret) = address(s).call("");
        assertFalse(ok);
        assertEq(bytes4(ret), PredgeSettlement.ZeroPayment.selector);
    }

    function test_fallback_unknownSelectorReverts() public {
        vm.prank(payer);
        (bool ok, ) = address(s).call{value: 1}(hex"deadbeef");
        assertFalse(ok, "no fallback: calldata with value is rejected");
    }

    function test_withdraw_sendsWholeBalance() public {
        vm.prank(payer);
        s.payForRoute{value: 3 ether}(ROUTE, "");
        vm.expectEmit(true, false, false, true, address(s));
        emit Withdrawn(treasury, 3 ether);
        vm.prank(owner);
        s.withdraw(treasury);
        assertEq(treasury.balance, 3 ether);
        assertEq(address(s).balance, 0);
    }

    function test_withdraw_includesForceSentValue() public {
        new ForceSend{value: 5 ether}(payable(address(s)));
        vm.prank(owner);
        s.withdraw(treasury);
        assertEq(treasury.balance, 5 ether);
    }

    function test_withdraw_zeroBalanceOk() public {
        vm.expectEmit(true, false, false, true, address(s));
        emit Withdrawn(treasury, 0);
        vm.prank(owner);
        s.withdraw(treasury);
    }

    function test_withdraw_revert_notOwner() public {
        vm.prank(payer);
        vm.expectRevert(PredgeSettlement.NotOwner.selector);
        s.withdraw(payable(payer));
    }

    function test_withdraw_revert_recipientRejects() public {
        ToggleReceiver r = new ToggleReceiver();
        r.setAccept(false);
        vm.prank(payer);
        s.payForRoute{value: 1 ether}(ROUTE, "");
        vm.prank(owner);
        vm.expectRevert(PredgeSettlement.WithdrawFailed.selector);
        s.withdraw(payable(address(r)));
        assertEq(address(s).balance, 1 ether);
    }

    function test_withdraw_reentrancyIsHarmless() public {
        Reenterer r = new Reenterer();
        r.arm(address(s), abi.encodeCall(PredgeSettlement.withdraw, (payable(address(r)))));
        vm.prank(payer);
        s.payForRoute{value: 1 ether}(ROUTE, "");
        vm.prank(owner);
        s.withdraw(payable(address(r)));
        assertFalse(r.reentrySucceeded(), "re-entrant withdraw is NotOwner");
        assertEq(address(r).balance, 1 ether);
    }

    /// Finding PS-01 (informational): withdraw accepts address(0); the call succeeds and the
    /// balance is burnt. There is also no ownership transfer, so a lost owner key strands funds.
    function test_finding_withdrawToZeroBurns() public {
        vm.prank(payer);
        s.payForRoute{value: 1 ether}(ROUTE, "");
        vm.prank(owner);
        s.withdraw(payable(address(0)));
        assertEq(address(s).balance, 0);
        assertEq(address(0).balance, 1 ether);
    }

    function testFuzz_payments_accumulate_thenWithdraw(uint64[5] memory amts) public {
        uint256 total;
        for (uint256 i; i < 5; i++) {
            uint256 a = bound(amts[i], 1, 10 ether);
            vm.prank(payer);
            if (i % 2 == 0) s.payForRoute{value: a}(bytes32(i), "m");
            else {
                (bool ok, ) = address(s).call{value: a}("");
                assertTrue(ok);
            }
            total += a;
        }
        assertEq(address(s).balance, total);
        vm.prank(owner);
        s.withdraw(treasury);
        assertEq(treasury.balance, total);
    }

    function testFuzz_withdraw_onlyOwner(address caller) public {
        vm.assume(caller != owner);
        vm.prank(caller);
        vm.expectRevert(PredgeSettlement.NotOwner.selector);
        s.withdraw(payable(caller));
    }
}
