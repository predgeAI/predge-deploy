// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AgentJobV2} from "../../contracts/v2/AgentJobV2.sol";
import {PredgeValidatorBondV2} from "../../contracts/v2/PredgeValidatorBondV2.sol";
import {PredgeRefundArbiterV2} from "../../contracts/v2/PredgeRefundArbiterV2.sol";
import {MockRefundProtocolV2} from "../../contracts/v2/mocks/MockRefundProtocolV2.sol";
import {Owned2Step} from "../../contracts/v2/access/PredgeAccess.sol";

/// @notice Constructor guards and constants, tested in named test functions with NO setUp.
/// @dev    Olympix mutation run on c47ed42: four constructor-guard mutants (`== address(0)` -> `!=`,
///         `bondBps_ > MAX_BPS` -> `<`, `evaluationWindow_ == 0` -> `!=`) were reported as surviving although
///         they make every deployment revert. In our suites they only broke `setUp()`, which a runner that
///         attributes kills to named test functions does not count. Here every deployment happens inside a
///         test function, so such a mutant fails a named test.
contract ConstructorGuardsTest is Test {
    address internal safe = makeAddr("safe");
    address internal op = makeAddr("operator");

    function mkJob(uint64 w) external returns (address) {
        return address(new AgentJobV2(w));
    }

    function mkBond(address j, uint16 bps) external returns (address) {
        return address(new PredgeValidatorBondV2(safe, op, j, 1, bps));
    }

    function mkArb(address rp, uint16 bps) external returns (address) {
        return address(new PredgeRefundArbiterV2(safe, op, rp, 1 hours, 1, bps));
    }

    function test_job_constructorGuard() public {
        vm.expectRevert(AgentJobV2.BadWindow.selector);
        this.mkJob(0);
        AgentJobV2 j = AgentJobV2(this.mkJob(1));
        assertEq(j.evaluationWindow(), 1, "a non-zero window deploys");
    }

    function test_bond_constructorGuards() public {
        address j = this.mkJob(1 days);
        vm.expectRevert(Owned2Step.ZeroAddress.selector);
        this.mkBond(address(0), 0);
        PredgeValidatorBondV2 b = PredgeValidatorBondV2(this.mkBond(j, 0));
        assertEq(address(b.job()), j, "a non-zero job deploys");
        assertEq(PredgeValidatorBondV2(this.mkBond(j, 10_000)).bondBps(), 10_000);
        vm.expectRevert(PredgeValidatorBondV2.BadParams.selector);
        this.mkBond(j, 10_001);
    }

    function test_arbiter_constructorGuards() public {
        address rp = address(new MockRefundProtocolV2(address(this)));
        vm.expectRevert(Owned2Step.ZeroAddress.selector);
        this.mkArb(address(0), 0);
        PredgeRefundArbiterV2 a = PredgeRefundArbiterV2(this.mkArb(rp, 0));
        assertEq(address(a.refundProtocol()), rp, "a non-zero refund protocol deploys");
        assertEq(PredgeRefundArbiterV2(this.mkArb(rp, 500)).bondBps(), 500, "bps below the cap deploys");
        assertEq(PredgeRefundArbiterV2(this.mkArb(rp, 10_000)).bondBps(), 10_000, "bps at the cap deploys");
        vm.expectRevert(PredgeRefundArbiterV2.BadParams.selector);
        this.mkArb(rp, 10_001);
    }

    function test_arbiter_constants() public {
        address rp = address(new MockRefundProtocolV2(address(this)));
        PredgeRefundArbiterV2 a = PredgeRefundArbiterV2(this.mkArb(rp, 0));
        assertEq(a.RESOLUTION_TIMEOUT(), 14 days);
        assertEq(a.MIN_WINDOW(), 1 hours);
        assertEq(a.MAX_WINDOW(), 30 days);
        assertEq(a.MAX_LOCKUP(), 365 days);
    }
}
