// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {PredgeRefundArbiterV2} from "../../contracts/v2/PredgeRefundArbiterV2.sol";
import {CircleRefundProtocolAdapter} from "../../contracts/v2/adapters/CircleRefundProtocolAdapter.sol";
import {MockCircleRefundProtocol} from "../../contracts/v2/mocks/MockCircleRefundProtocol.sol";
import {MockUSDC} from "../../contracts/v2/mocks/MockUSDC.sol";

/// @notice PredgeRefundArbiterV2 (unchanged, as deployed) driving a Circle-shaped Refund Protocol
///         through CircleRefundProtocolAdapter. Parameters mirror the live Arc config: 1-day window,
///         5 USDC native bond floor, 0 bps.
contract CircleRefundAdapterTest is Test {
    address internal safe = makeAddr("safe");
    address internal op = makeAddr("operator");
    address internal buyer = makeAddr("buyerAgent");
    address internal seller = makeAddr("sellerAgent");
    address internal stranger = makeAddr("stranger");

    uint64 internal constant WINDOW = 1 days;
    uint256 internal constant MIN_BOND = 5e18; // 5 USDC in Arc native wei
    uint16 internal constant BPS = 0;
    uint256 internal constant SCALE = 1e12; // USDC 6 decimals -> 18
    uint256 internal constant LOCKUP = 20 days; // > WINDOW + RESOLUTION_TIMEOUT (15 days)
    uint256 internal constant PRICE = 10e6; // 10 USDC

    bytes32 internal constant EV_BUYER = keccak256("terms+delivery hash, buyer");
    bytes32 internal constant EV_SELLER = keccak256("terms+delivery hash, seller");
    bytes32 internal constant EV_COUNTER = keccak256("counter evidence");

    MockUSDC internal usdc;
    MockCircleRefundProtocol internal circle;
    CircleRefundProtocolAdapter internal adapter;
    PredgeRefundArbiterV2 internal arb;

    function setUp() public {
        vm.warp(1_762_000_000);
        usdc = new MockUSDC();
        adapter = new CircleRefundProtocolAdapter(SCALE);
        circle = new MockCircleRefundProtocol(address(adapter), address(usdc));
        arb = new PredgeRefundArbiterV2(safe, op, address(adapter), WINDOW, MIN_BOND, BPS);
        adapter.bind(address(circle), address(arb));

        vm.prank(safe);
        arb.setLockupSeconds(seller, LOCKUP); // Safe -> Predge arbiter -> adapter -> Circle

        vm.deal(op, 100 ether);
        usdc.mint(buyer, 100e6);
        vm.prank(buyer);
        usdc.approve(address(circle), type(uint256).max);
    }

    // ---------- helpers ----------

    function _pay() internal returns (uint256 id) {
        id = circle.nonce();
        vm.prank(buyer);
        circle.pay(seller, PRICE, buyer);
    }

    function _fileBoth(uint256 id) internal {
        vm.prank(buyer);
        arb.fileEvidence(id, EV_BUYER);
        vm.prank(seller);
        arb.fileEvidence(id, EV_SELLER);
    }

    function _rule(uint256 id, address from, bytes32 ev, PredgeRefundArbiterV2.Direction d) internal {
        vm.prank(op);
        arb.rule{value: MIN_BOND}(id, from, ev, d);
    }

    function _refunded(uint256 id) internal view returns (bool r) {
        (,,,,, r) = circle.payments(id);
    }

    // ---------- wiring ----------

    function test_wiring() public view {
        assertEq(circle.arbiter(), address(adapter));
        assertEq(address(arb.refundProtocol()), address(adapter));
        assertEq(address(adapter.circle()), address(circle));
        assertEq(adapter.predgeArbiter(), address(arb));
        assertEq(circle.lockupSeconds(seller), LOCKUP);
    }

    function test_bind_onceOnly_deployerOnly() public {
        vm.expectRevert(CircleRefundProtocolAdapter.AlreadyBound.selector);
        adapter.bind(address(circle), address(arb));

        CircleRefundProtocolAdapter a2 = new CircleRefundProtocolAdapter(SCALE);
        vm.prank(stranger);
        vm.expectRevert(CircleRefundProtocolAdapter.NotDeployer.selector);
        a2.bind(address(circle), address(arb));
        // Circle's arbiter is the first adapter, not a2
        vm.expectRevert(CircleRefundProtocolAdapter.NotCircleArbiter.selector);
        a2.bind(address(circle), address(arb));
        // Predge arbiter points to the first adapter, not a2
        MockCircleRefundProtocol c2 = new MockCircleRefundProtocol(address(a2), address(usdc));
        vm.expectRevert(CircleRefundProtocolAdapter.ArbiterNotWired.selector);
        a2.bind(address(c2), address(arb));
        vm.expectRevert(CircleRefundProtocolAdapter.NotBound.selector);
        a2.paymentInfo(0);
    }

    function test_paymentInfo_mapsCircleFields() public {
        uint256 id = _pay();
        assertEq(id, 0, "Circle ids start at 0");
        (address payer, address payee, uint256 amount, uint256 release) = adapter.paymentInfo(id);
        assertEq(payer, buyer, "payer = refundTo");
        assertEq(payee, seller, "payee = to");
        assertEq(amount, PRICE * SCALE, "6 -> 18 decimals");
        assertEq(release, block.timestamp + LOCKUP);
        (payer, payee, amount, release) = adapter.paymentInfo(99);
        assertEq(payee, address(0), "unknown payment reads as zero");
    }

    function test_onlyPredgeArbiterCanDriveCircle() public {
        uint256 id = _pay();
        vm.prank(stranger);
        vm.expectRevert(CircleRefundProtocolAdapter.NotPredgeArbiter.selector);
        adapter.refundByArbiter(id);
        vm.prank(op);
        vm.expectRevert(CircleRefundProtocolAdapter.NotPredgeArbiter.selector);
        adapter.refundByArbiter(id);
        vm.prank(stranger);
        vm.expectRevert(MockCircleRefundProtocol.CallerNotAllowed.selector);
        circle.refundByArbiter(id);
        vm.prank(stranger);
        vm.expectRevert(CircleRefundProtocolAdapter.NotPredgeArbiter.selector);
        adapter.setLockupSeconds(seller, 1);
    }

    // ---------- 1. happy path: release ----------

    function test_release_sellerPaidAfterLockup() public {
        uint256 id = _pay();
        _fileBoth(id);
        _rule(id, seller, EV_SELLER, PredgeRefundArbiterV2.Direction.Release);

        vm.warp(block.timestamp + WINDOW);
        arb.finalize(id);
        assertEq(uint8(arb.rulings(id).status), uint8(PredgeRefundArbiterV2.Status.Finalized));
        assertFalse(_refunded(id));
        assertEq(arb.credit(op), MIN_BOND, "bond back to operator");

        vm.warp(block.timestamp + LOCKUP);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(seller);
        circle.withdraw(ids);
        assertEq(usdc.balanceOf(seller), PRICE);
        assertEq(usdc.balanceOf(address(circle)), 0);

        uint256 before = op.balance;
        vm.prank(op);
        arb.withdraw();
        assertEq(op.balance - before, MIN_BOND);
    }

    // ---------- 2. refund on verdict ----------

    function test_refundOnVerdict_buyerGetsUsdcBack() public {
        uint256 id = _pay();
        _fileBoth(id);
        _rule(id, buyer, EV_BUYER, PredgeRefundArbiterV2.Direction.Refund);

        vm.warp(block.timestamp + WINDOW);
        arb.finalize(id);
        assertTrue(_refunded(id));
        assertEq(usdc.balanceOf(buyer), 100e6, "buyer whole again");
        assertEq(circle.balances(seller), 0);

        vm.warp(block.timestamp + LOCKUP);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(MockCircleRefundProtocol.PaymentRefunded.selector, id));
        circle.withdraw(ids);
    }

    // ---------- 3. dispute ----------

    function test_dispute_releaseOverturnedToRefund() public {
        uint256 id = _pay();
        _fileBoth(id);
        _rule(id, seller, EV_SELLER, PredgeRefundArbiterV2.Direction.Release);

        vm.prank(seller);
        vm.expectRevert(PredgeRefundArbiterV2.NotHarmedParty.selector);
        arb.dispute(id, EV_COUNTER);

        vm.prank(buyer);
        arb.dispute(id, EV_COUNTER);
        vm.warp(block.timestamp + WINDOW);
        vm.expectRevert(PredgeRefundArbiterV2.BadStatus.selector);
        arb.finalize(id); // frozen

        vm.prank(safe);
        arb.resolve(id, PredgeRefundArbiterV2.Direction.Refund);
        assertEq(uint8(arb.rulings(id).status), uint8(PredgeRefundArbiterV2.Status.Overturned));
        assertTrue(_refunded(id));
        assertEq(usdc.balanceOf(buyer), 100e6);
        assertEq(arb.credit(buyer), MIN_BOND, "operator bond to the harmed buyer");
        assertEq(arb.overturnCount(), 1);
    }

    function test_dispute_refundUpheld() public {
        uint256 id = _pay();
        _fileBoth(id);
        _rule(id, buyer, EV_BUYER, PredgeRefundArbiterV2.Direction.Refund);
        vm.prank(seller);
        arb.dispute(id, EV_COUNTER);
        vm.prank(safe);
        arb.resolve(id, PredgeRefundArbiterV2.Direction.Refund);
        assertEq(uint8(arb.rulings(id).status), uint8(PredgeRefundArbiterV2.Status.Finalized));
        assertTrue(_refunded(id));
        assertEq(arb.credit(op), MIN_BOND);
    }

    // ---------- edge cases from the gap analysis ----------

    function test_sellerRefundsFirst_finalizeStillSucceeds() public {
        uint256 id = _pay();
        _fileBoth(id);
        _rule(id, buyer, EV_BUYER, PredgeRefundArbiterV2.Direction.Refund);
        vm.prank(seller);
        circle.refundByRecipient(id);
        vm.warp(block.timestamp + WINDOW);
        arb.finalize(id); // adapter treats "already refunded" as done
        assertEq(uint8(arb.rulings(id).status), uint8(PredgeRefundArbiterV2.Status.Finalized));
        assertEq(usdc.balanceOf(buyer), 100e6);
    }

    function test_refundedPayment_notArbitrable() public {
        uint256 id = _pay();
        vm.prank(seller);
        circle.refundByRecipient(id);
        vm.prank(buyer);
        vm.expectRevert(PredgeRefundArbiterV2.NotAParty.selector);
        arb.fileEvidence(id, EV_BUYER);
    }

    function test_zeroLockup_ruleRefused() public {
        address other = makeAddr("noLockupSeller");
        uint256 id = circle.nonce();
        vm.prank(buyer);
        circle.pay(other, PRICE, buyer);
        vm.prank(buyer);
        arb.fileEvidence(id, EV_BUYER);
        vm.prank(op);
        vm.expectRevert(PredgeRefundArbiterV2.LockupTooShort.selector);
        arb.rule{value: MIN_BOND}(id, buyer, EV_BUYER, PredgeRefundArbiterV2.Direction.Refund);
    }

    function test_lockupCap_circle180dBelowPredge365d() public {
        vm.prank(safe);
        vm.expectRevert(MockCircleRefundProtocol.LockupSecondsExceedsMax.selector);
        arb.setLockupSeconds(seller, 200 days);
    }

    function test_refundToChangedAfterRuling_refundGoesToNewAddress() public {
        address newTo = makeAddr("buyerTreasury");
        uint256 id = _pay();
        _fileBoth(id);
        _rule(id, buyer, EV_BUYER, PredgeRefundArbiterV2.Direction.Refund);
        vm.prank(buyer);
        circle.updateRefundTo(id, newTo);
        vm.warp(block.timestamp + WINDOW);
        arb.finalize(id);
        assertEq(usdc.balanceOf(newTo), PRICE, "Circle pays the current refundTo");
        assertEq(arb.rulings(id).payer, buyer, "Predge keeps the payer snapshotted at ruling");
    }

    // ---------- the 6-line demo log ----------

    function test_demoLog() public {
        uint256 id = _pay();
        console2.log("[1/6] PAY      buyer-agent -> RefundProtocol (Circle interface): 10.00 USDC to seller-agent, id", id, "lockup 20d");
        _fileBoth(id);
        console2.log("[2/6] EVIDENCE buyer + seller filed hashes of terms and delivery with Predge");
        _rule(id, buyer, EV_BUYER, PredgeRefundArbiterV2.Direction.Refund);
        console2.log("[3/6] VERDICT  Predge operator: REFUND (delivery did not meet the fixed terms), 5 USDC bond posted");
        console2.log("[4/6] WINDOW   24h challenge window open; seller may dispute to the owner Safe");
        vm.warp(block.timestamp + WINDOW);
        arb.finalize(id);
        console2.log("[5/6] FINALIZE no dispute -> Predge arbiter -> adapter -> RefundProtocol.refundByArbiter");
        console2.log("[6/6] RESULT   buyer USDC back (6dp):", usdc.balanceOf(buyer) - 90e6, "refunded:", _refunded(id));
        assertTrue(_refunded(id));
    }
}
