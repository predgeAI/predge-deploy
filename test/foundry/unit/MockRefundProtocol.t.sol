// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockRefundProtocol} from "../../../contracts/MockRefundProtocol.sol";

contract MockRefundProtocolTest is Test {
    MockRefundProtocol m;
    address arb = makeAddr("arbiter");
    address other = makeAddr("other");

    event RefundByArbiter(uint256 indexed paymentID, address indexed caller);
    event LockupSet(address indexed recipient, uint256 seconds_);

    function setUp() public {
        m = new MockRefundProtocol(arb);
    }

    function test_constructor() public view {
        assertEq(m.arbiter(), arb);
        assertEq(m.refundCount(), 0);
    }

    function test_setArbiter() public {
        vm.prank(arb);
        m.setArbiter(other);
        assertEq(m.arbiter(), other);
        vm.prank(arb);
        vm.expectRevert(MockRefundProtocol.CallerNotAllowed.selector);
        m.setArbiter(arb);
    }

    function test_setArbiter_revert_notArbiter() public {
        vm.prank(other);
        vm.expectRevert(MockRefundProtocol.CallerNotAllowed.selector);
        m.setArbiter(other);
    }

    function test_refundByArbiter() public {
        vm.expectEmit(true, true, false, false, address(m));
        emit RefundByArbiter(5, arb);
        vm.prank(arb);
        m.refundByArbiter(5);
        assertTrue(m.refunded(5));
        assertFalse(m.refunded(6));
        assertEq(m.refundCount(), 1);
        vm.prank(arb);
        m.refundByArbiter(5); // mock does not dedupe; it only records calls
        assertEq(m.refundCount(), 2);
    }

    function test_refundByArbiter_revert_notArbiter() public {
        vm.prank(other);
        vm.expectRevert(MockRefundProtocol.CallerNotAllowed.selector);
        m.refundByArbiter(1);
    }

    function test_setLockupSeconds() public {
        vm.expectEmit(true, false, false, true, address(m));
        emit LockupSet(other, 3600);
        vm.prank(arb);
        m.setLockupSeconds(other, 3600);
        assertEq(m.lockupSeconds(other), 3600);
    }

    function test_setLockupSeconds_revert_notArbiter() public {
        vm.prank(other);
        vm.expectRevert(MockRefundProtocol.CallerNotAllowed.selector);
        m.setLockupSeconds(other, 1);
    }

    function testFuzz_onlyArbiter(address caller, uint256 id) public {
        vm.assume(caller != arb);
        vm.startPrank(caller);
        vm.expectRevert(MockRefundProtocol.CallerNotAllowed.selector);
        m.refundByArbiter(id);
        vm.expectRevert(MockRefundProtocol.CallerNotAllowed.selector);
        m.setLockupSeconds(caller, id);
        vm.expectRevert(MockRefundProtocol.CallerNotAllowed.selector);
        m.setArbiter(caller);
        vm.stopPrank();
    }
}
