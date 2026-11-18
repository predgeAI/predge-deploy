// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PredgeRefundArbiterV2 as Arb} from "../../contracts/v2/PredgeRefundArbiterV2.sol";
import {PredgeJobEscrow as Escrow} from "../../contracts/v2/demo/PredgeJobEscrow.sol";
import {Operated, Owned2Step} from "../../contracts/v2/access/PredgeAccess.sol";
import {MockUSDC} from "../../contracts/v2/mocks/MockUSDC.sol";

/// @dev Configurable decimals; the rest of the ERC-20 surface is not needed for constructor tests.
contract TokenWithDecimals {
    uint8 public immutable decimals;

    constructor(uint8 d) {
        decimals = d;
    }
}

/// @dev A plain 6-decimal token whose transfers can be overridden, unlike MockUSDC.
contract OverridableToken {
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external virtual returns (bool) {
        return _move(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external virtual returns (bool) {
        allowance[from][msg.sender] -= amount;
        return _move(from, to, amount);
    }

    function _move(address from, address to, uint256 amount) internal returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Re-enters the escrow from inside a transfer, as a hostile token or hook would.
contract ReentrantUSDC is OverridableToken {
    Escrow public target;
    uint256 public targetId;
    bool public reentered;
    bool public reentryFailed;

    function arm(Escrow t, uint256 id) external {
        target = t;
        targetId = id;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        if (address(target) != address(0) && !reentered) {
            reentered = true;
            try target.settle(targetId) {} catch {
                reentryFailed = true;
            }
        }
        return _move(msg.sender, to, amount);
    }
}

/// @dev Reports failure rather than reverting.
contract FalseReturningUSDC is OverridableToken {
    function transferFrom(address, address, uint256) external pure override returns (bool) {
        return false;
    }
}

abstract contract EscrowBase is Test {
    address internal owner = makeAddr("ownerSafe");
    address internal op = makeAddr("operator");
    address internal buyer = makeAddr("buyerAgent");
    address internal refundTo = makeAddr("refundWallet");
    address internal seller = makeAddr("sellerAgent");
    address internal stranger = makeAddr("stranger");

    uint64 internal constant WINDOW = 1 hours;
    uint64 internal constant RESOLUTION = 14 days;
    uint256 internal constant MIN_BOND = 5e18; // 5 USDC in Arc native wei
    uint256 internal constant PRICE = 10e6; // 10 USDC, 6 decimals
    uint64 internal constant DELIVERY = 1 hours;

    bytes32 internal constant SPEC = keccak256("job spec");
    bytes32 internal constant EV_REFUND_TO = keccak256("delivery record, refundTo");
    bytes32 internal constant EV_SELLER = keccak256("delivery record, seller");
    bytes32 internal constant COUNTER = keccak256("counter evidence");
    bytes32 internal constant DELIVERY_HASH = keccak256("delivery");
    bytes32 internal constant ATT_A = keccak256("attestation A");
    bytes32 internal constant ATT_B = keccak256("attestation B");

    MockUSDC internal usdc;
    Escrow internal escrow;
    Arb internal arb;

    function setUp() public virtual {
        vm.warp(1_762_000_000);
        usdc = new MockUSDC();
        _deploy(usdc, 0);
    }

    function _deploy(MockUSDC token, uint16 bps) internal {
        escrow = new Escrow(address(token));
        arb = new Arb(owner, op, address(escrow), WINDOW, MIN_BOND, bps);
        escrow.bind(address(arb));
        vm.deal(op, 1_000e18);
        token.mint(buyer, 5_000e6);
        vm.prank(buyer);
        token.approve(address(escrow), type(uint256).max);
    }

    function _pay() internal returns (uint256 id) {
        vm.prank(buyer);
        id = escrow.pay(seller, PRICE, refundTo, SPEC, uint64(block.timestamp) + DELIVERY);
    }

    function _deliver(uint256 id) internal {
        vm.prank(seller);
        escrow.markDelivered(id, DELIVERY_HASH);
    }

    function _file(uint256 id) internal {
        vm.prank(refundTo);
        arb.fileEvidence(id, EV_REFUND_TO);
        vm.prank(seller);
        arb.fileEvidence(id, EV_SELLER);
    }

    function _rule(uint256 id, Arb.Direction d) internal {
        vm.prank(op);
        arb.rule{value: MIN_BOND}(id, refundTo, EV_REFUND_TO, d);
    }

    /// @dev Pay, deliver, evidence, record, rule: the full road to an open window.
    function _ruled(Arb.Direction d, bytes32 att) internal returns (uint256 id) {
        id = _pay();
        _deliver(id);
        _file(id);
        vm.prank(op);
        escrow.recordVerdict(id, att, d);
        _rule(id, d);
    }

    function _pastWindow() internal {
        vm.warp(block.timestamp + WINDOW);
    }

    function _state(uint256 id) internal view returns (Escrow.State) {
        return escrow.jobs(id).state;
    }

    function _assertReleased(uint256 id) internal view {
        assertEq(uint8(_state(id)), uint8(Escrow.State.Released), "state Released");
        assertEq(usdc.balanceOf(seller), PRICE, "seller paid");
        assertEq(usdc.balanceOf(refundTo), 0, "refundTo unpaid");
        assertEq(usdc.balanceOf(address(escrow)), 0, "escrow empty");
        assertEq(escrow.totalHeld(), 0, "totalHeld zero");
    }

    function _assertRefunded(uint256 id) internal view {
        assertEq(uint8(_state(id)), uint8(Escrow.State.Refunded), "state Refunded");
        assertEq(usdc.balanceOf(refundTo), PRICE, "refundTo paid");
        assertEq(usdc.balanceOf(seller), 0, "seller unpaid");
        assertEq(usdc.balanceOf(address(escrow)), 0, "escrow empty");
        assertEq(escrow.totalHeld(), 0, "totalHeld zero");
    }
}

contract JobEscrowWiringTest is EscrowBase {
    function test_demoNoticeIsOnChain() public view {
        assertEq(escrow.DEMO_NOTICE(), "DEMO ONLY. UNAUDITED. TESTNET ONLY. Not for real funds.");
    }

    function test_constructor_refusesMainnets() public {
        uint256[4] memory mainnets = [uint256(1), 5042, 8453, 42161]; // Ethereum, Arc, Base, Arbitrum
        for (uint256 i; i < mainnets.length; i++) {
            vm.chainId(mainnets[i]);
            vm.expectRevert(abi.encodeWithSelector(Escrow.ChainNotAllowed.selector, mainnets[i]));
            new Escrow(address(usdc));
        }
    }

    function test_constructor_allowsArcTestnetAndAnvil() public {
        vm.chainId(5042002);
        new Escrow(address(usdc));
        vm.chainId(31337);
        new Escrow(address(usdc));
    }

    function test_constructor_refusesZeroTokenAndTooManyDecimals() public {
        vm.expectRevert(Escrow.ZeroAddress.selector);
        new Escrow(address(0));
        TokenWithDecimals t = new TokenWithDecimals(19);
        vm.expectRevert(abi.encodeWithSelector(Escrow.BadDecimals.selector, uint8(19)));
        new Escrow(address(t));
    }

    function test_bind_deployerOnlyOnceAndChecksWiring() public {
        vm.expectRevert(Escrow.AlreadyBound.selector);
        escrow.bind(address(arb));

        Escrow e2 = new Escrow(address(usdc));
        vm.prank(stranger);
        vm.expectRevert(Escrow.NotDeployer.selector);
        e2.bind(address(arb));
        vm.expectRevert(Escrow.ZeroAddress.selector);
        e2.bind(address(0));
        // `arb` drives the first escrow, not e2
        vm.expectRevert(Escrow.ArbiterNotWired.selector);
        e2.bind(address(arb));
    }

    function test_bind_refusesWindowThatCannotFitTheLockup() public {
        Escrow e2 = new Escrow(address(usdc));
        // 2 days + 14 days = the 16-day lockup exactly: a ruling could never pass LockupTooShort.
        Arb a2 = new Arb(owner, op, address(e2), 2 days, MIN_BOND, 0);
        vm.expectRevert(Escrow.LockupTooShort.selector);
        e2.bind(address(a2));
    }

    function test_pay_beforeBindReverts() public {
        Escrow e2 = new Escrow(address(usdc));
        vm.prank(buyer);
        vm.expectRevert(Escrow.NotBound.selector);
        e2.pay(seller, PRICE, refundTo, SPEC, uint64(block.timestamp) + 1);
    }

    function test_onlyArbiterDrivesProtocolSide() public {
        uint256 id = _pay();
        vm.prank(stranger);
        vm.expectRevert(Escrow.NotArbiter.selector);
        escrow.refundByArbiter(id);
        vm.prank(owner); // not even the arbiter's owner, directly
        vm.expectRevert(Escrow.NotArbiter.selector);
        escrow.refundByArbiter(id);
        vm.prank(stranger);
        vm.expectRevert(Escrow.NotArbiter.selector);
        escrow.setLockupSeconds(seller, 30 days);
    }

    function test_setLockup_viaArbiter_laterPaymentsOnly() public {
        uint256 first = _pay();
        vm.prank(owner);
        arb.setLockupSeconds(seller, 30 days);
        uint256 second = _pay();
        assertEq(escrow.jobs(first).releaseAt, block.timestamp + 16 days, "existing job unchanged");
        assertEq(escrow.jobs(second).releaseAt, block.timestamp + 30 days, "new lockup applied");
    }

    function test_setLockup_arbiterBoundStillApplies() public {
        vm.prank(owner);
        vm.expectRevert(Arb.BadParams.selector);
        arb.setLockupSeconds(seller, 14 days);
    }
}

contract JobEscrowDecimalsTest is EscrowBase {
    function test_scaleIs1e12ForSixDecimals() public view {
        assertEq(usdc.decimals(), 6);
        assertEq(escrow.amountScale(), 1e12);
        assertEq(escrow.maxAmount(), 1_000e6);
    }

    function test_paymentInfo_reports18dp_jobStores6dp() public {
        uint256 id = _pay();
        (address payer, address payee, uint256 amount, uint256 release) = escrow.paymentInfo(id);
        assertEq(payer, refundTo, "payer is refundTo, not the caller");
        assertEq(payee, seller);
        assertEq(amount, 10e18, "10 USDC in native wei");
        assertEq(release, block.timestamp + 16 days);
        assertEq(escrow.jobs(id).amount, 10e6, "10 USDC in token units");
        assertEq(usdc.balanceOf(address(escrow)), 10e6);
    }

    function test_amountWrittenIn18dp_isRefused() public {
        usdc.mint(buyer, 10e18);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Escrow.AmountTooLarge.selector, 1_000e6));
        escrow.pay(seller, 10e18, refundTo, SPEC, uint64(block.timestamp) + DELIVERY);
    }

    /// @dev Bond bps act on the scaled amount. Without the 1e12, 50% of 10 USDC would be 5e6 wei, about
    ///      nothing, and the floor would hide the bug; a bond above the floor shows it.
    function test_bondBps_workOnScaledAmount() public {
        uint256 id;
        usdc = new MockUSDC();
        _deploy(usdc, 10_000); // 100% of the payment
        vm.prank(buyer);
        id = escrow.pay(seller, 20e6, refundTo, SPEC, uint64(block.timestamp) + DELIVERY);
        (,, uint256 scaled,) = escrow.paymentInfo(id);
        assertEq(arb.requiredBond(scaled), 20e18, "100% of 20 USDC is 20e18 wei, above the 5e18 floor");
        vm.prank(refundTo);
        arb.fileEvidence(id, EV_REFUND_TO);
        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(Arb.BondTooSmall.selector, 20e18));
        arb.rule{value: 20e18 - 1}(id, refundTo, EV_REFUND_TO, Arb.Direction.Refund);
    }

    function test_settlement_paysExactTokenUnits() public {
        uint256 amount = 1_234_567; // 1.234567 USDC
        vm.prank(buyer);
        uint256 id = escrow.pay(seller, amount, refundTo, SPEC, uint64(block.timestamp) + DELIVERY);
        _file(id);
        _rule(id, Arb.Direction.Release);
        _pastWindow();
        escrow.settle(id);
        assertEq(usdc.balanceOf(seller), amount, "not scaled on the way out");
    }

    function testFuzz_scaleAcrossDecimals(uint8 decimals) public {
        decimals = uint8(bound(decimals, 0, 18));
        TokenWithDecimals t = new TokenWithDecimals(decimals);
        Escrow e = new Escrow(address(t));
        assertEq(e.amountScale(), 10 ** (18 - uint256(decimals)));
        assertEq(e.maxAmount(), 1_000 * 10 ** uint256(decimals));
    }

    function testFuzz_payAmount_roundTrips(uint256 amount) public {
        amount = bound(amount, 1, 1_000e6);
        vm.prank(buyer);
        uint256 id = escrow.pay(seller, amount, refundTo, SPEC, uint64(block.timestamp) + DELIVERY);
        (,, uint256 scaled,) = escrow.paymentInfo(id);
        assertEq(scaled, amount * 1e12);
        _file(id);
        _rule(id, Arb.Direction.Refund);
        _pastWindow();
        escrow.settle(id);
        assertEq(usdc.balanceOf(refundTo), amount);
    }
}

contract JobEscrowPayTest is EscrowBase {
    function test_pay_recordsJobAndPullsFunds() public {
        uint64 by = uint64(block.timestamp) + DELIVERY;
        vm.expectEmit(true, true, true, true);
        emit Escrow.JobPaid(1, buyer, seller, refundTo, PRICE, SPEC, by, uint64(block.timestamp) + 16 days);
        uint256 id = _pay();
        assertEq(id, 1, "ids start at 1");
        Escrow.Job memory j = escrow.jobs(id);
        assertEq(j.buyer, buyer);
        assertEq(j.seller, seller);
        assertEq(j.refundTo, refundTo);
        assertEq(j.specHash, SPEC);
        assertEq(j.paidAt, block.timestamp);
        assertEq(j.deliverBy, by);
        assertEq(uint8(j.state), uint8(Escrow.State.Funded));
        assertFalse(j.delivered);
        assertEq(escrow.totalHeld(), PRICE);
        assertEq(usdc.balanceOf(buyer), 5_000e6 - PRICE);
    }

    function test_pay_validation() public {
        uint64 by = uint64(block.timestamp) + DELIVERY;
        vm.startPrank(buyer);
        vm.expectRevert(Escrow.ZeroAddress.selector);
        escrow.pay(address(0), PRICE, refundTo, SPEC, by);
        vm.expectRevert(Escrow.ZeroAddress.selector);
        escrow.pay(seller, PRICE, address(0), SPEC, by);
        vm.expectRevert(Escrow.ZeroAmount.selector);
        escrow.pay(seller, 0, refundTo, SPEC, by);
        vm.expectRevert(Escrow.ZeroHash.selector);
        escrow.pay(seller, PRICE, refundTo, bytes32(0), by);
        vm.expectRevert(Escrow.BadDeadline.selector);
        escrow.pay(seller, PRICE, refundTo, SPEC, uint64(block.timestamp));
        vm.expectRevert(Escrow.BadDeadline.selector);
        escrow.pay(seller, PRICE, refundTo, SPEC, uint64(block.timestamp) + 1 days + 1);
        vm.stopPrank();
    }

    function test_pay_refusesPartiesTheArbiterCouldNeverRuleOn() public {
        uint64 by = uint64(block.timestamp) + DELIVERY;
        vm.startPrank(buyer);
        vm.expectRevert(Escrow.BadParties.selector);
        escrow.pay(buyer, PRICE, refundTo, SPEC, by); // paying yourself
        vm.expectRevert(Escrow.BadParties.selector);
        escrow.pay(seller, PRICE, seller, SPEC, by); // refund to the seller
        vm.expectRevert(Escrow.BadParties.selector);
        escrow.pay(op, PRICE, refundTo, SPEC, by); // operator as seller
        vm.expectRevert(Escrow.BadParties.selector);
        escrow.pay(seller, PRICE, op, SPEC, by); // operator as refund wallet
        vm.stopPrank();
    }

    function test_pay_maxAmountBoundary() public {
        uint64 by = uint64(block.timestamp) + DELIVERY;
        vm.startPrank(buyer);
        escrow.pay(seller, 1_000e6, refundTo, SPEC, by);
        vm.expectRevert(abi.encodeWithSelector(Escrow.AmountTooLarge.selector, 1_000e6));
        escrow.pay(seller, 1_000e6 + 1, refundTo, SPEC, by);
        vm.stopPrank();
    }

    function test_pay_tokenReturningFalseReverts() public {
        FalseReturningUSDC bad = new FalseReturningUSDC();
        Escrow e = new Escrow(address(bad));
        Arb a = new Arb(owner, op, address(e), WINDOW, MIN_BOND, 0);
        e.bind(address(a));
        vm.prank(buyer);
        vm.expectRevert(Escrow.TransferFailed.selector);
        e.pay(seller, PRICE, refundTo, SPEC, uint64(block.timestamp) + DELIVERY);
    }

    function test_paymentInfo_unknownJobReadsZero() public view {
        (address payer, address payee, uint256 amount, uint256 release) = escrow.paymentInfo(99);
        assertEq(payer, address(0));
        assertEq(payee, address(0));
        assertEq(amount, 0);
        assertEq(release, 0);
    }

    function test_markDelivered_sellerOnlyOnce() public {
        uint256 id = _pay();
        vm.prank(buyer);
        vm.expectRevert(Escrow.NotSeller.selector);
        escrow.markDelivered(id, DELIVERY_HASH);
        vm.prank(seller);
        vm.expectRevert(Escrow.ZeroHash.selector);
        escrow.markDelivered(id, bytes32(0));
        _deliver(id);
        assertTrue(escrow.jobs(id).delivered);
        assertEq(escrow.jobs(id).deliveryHash, DELIVERY_HASH);
        vm.prank(seller);
        vm.expectRevert(Escrow.AlreadyDelivered.selector);
        escrow.markDelivered(id, DELIVERY_HASH);
    }
}

contract JobEscrowHappyPathTest is EscrowBase {
    function test_delivered_release_paysSellerAutomatically() public {
        uint256 id = _ruled(Arb.Direction.Release, ATT_A);
        assertEq(usdc.balanceOf(seller), 0, "nothing moves at the ruling");
        _pastWindow();
        vm.prank(stranger); // the keeper can be anybody
        escrow.settle(id);
        _assertReleased(id);
        assertEq(uint8(arb.rulings(id).status), uint8(Arb.Status.Finalized));
    }

    function test_release_bondGoesBackToOperator() public {
        uint256 before = op.balance;
        uint256 id = _ruled(Arb.Direction.Release, ATT_A);
        assertEq(op.balance, before - MIN_BOND, "bond posted");
        _pastWindow();
        escrow.settle(id);
        assertEq(arb.credit(op), MIN_BOND, "bond credited");
        vm.prank(op);
        arb.withdraw();
        assertEq(op.balance, before, "bond returned");
        assertEq(arb.totalBonded(), 0);
    }

    function test_settle_beforeWindowCloses_reverts() public {
        uint256 id = _ruled(Arb.Direction.Release, ATT_A);
        vm.warp(block.timestamp + WINDOW - 1);
        vm.expectRevert(Arb.WindowOpen.selector);
        escrow.settle(id);
        assertEq(usdc.balanceOf(seller), 0);
    }

    function test_settle_withoutRuling_reverts() public {
        uint256 id = _pay();
        vm.expectRevert(abi.encodeWithSelector(Escrow.NotSettleable.selector, id));
        escrow.settle(id);
    }

    function test_settle_twice_reverts() public {
        uint256 id = _ruled(Arb.Direction.Release, ATT_A);
        _pastWindow();
        escrow.settle(id);
        vm.expectRevert(abi.encodeWithSelector(Escrow.NotActive.selector, id));
        escrow.settle(id);
        assertEq(usdc.balanceOf(seller), PRICE, "paid once");
    }

    function test_finalizeCalledDirectlyOnArbiter_settleStillPays() public {
        uint256 id = _ruled(Arb.Direction.Release, ATT_A);
        _pastWindow();
        arb.finalize(id); // someone other than the keeper; a Release moves nothing here
        assertEq(usdc.balanceOf(seller), 0);
        escrow.settle(id);
        _assertReleased(id);
    }

    function test_jobsAreIndependent() public {
        uint256 a = _ruled(Arb.Direction.Release, ATT_A);
        uint256 b = _ruled(Arb.Direction.Refund, ATT_B);
        _pastWindow();
        escrow.settle(a);
        assertEq(usdc.balanceOf(address(escrow)), PRICE, "b's money still held");
        assertEq(escrow.totalHeld(), PRICE);
        escrow.settle(b);
        assertEq(usdc.balanceOf(seller), PRICE);
        assertEq(usdc.balanceOf(refundTo), PRICE);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_reentrantTokenCannotDoublePay() public {
        ReentrantUSDC t = new ReentrantUSDC();
        Escrow e = new Escrow(address(t));
        Arb a = new Arb(owner, op, address(e), WINDOW, MIN_BOND, 0);
        e.bind(address(a));
        t.mint(buyer, 2 * PRICE);
        vm.startPrank(buyer);
        t.approve(address(e), type(uint256).max);
        uint256 id = e.pay(seller, PRICE, refundTo, SPEC, uint64(block.timestamp) + DELIVERY);
        e.pay(seller, PRICE, refundTo, SPEC, uint64(block.timestamp) + DELIVERY); // a second job's money to steal
        vm.stopPrank();
        vm.prank(refundTo);
        a.fileEvidence(id, EV_REFUND_TO);
        vm.prank(op);
        a.rule{value: MIN_BOND}(id, refundTo, EV_REFUND_TO, Arb.Direction.Release);
        vm.warp(block.timestamp + WINDOW);
        t.arm(e, id);
        e.settle(id);
        assertTrue(t.reentered(), "reentry attempted");
        assertTrue(t.reentryFailed(), "reentry refused");
        assertEq(t.balanceOf(seller), PRICE, "paid once");
        assertEq(t.balanceOf(address(e)), PRICE, "other job's money intact");
    }
}

contract JobEscrowRefundTest is EscrowBase {
    function test_notDelivered_refund_goesToRefundToNotBuyer() public {
        uint256 id = _ruled(Arb.Direction.Refund, ATT_A);
        uint256 buyerBefore = usdc.balanceOf(buyer);
        _pastWindow();
        vm.prank(stranger);
        escrow.settle(id);
        _assertRefunded(id);
        assertEq(usdc.balanceOf(buyer), buyerBefore, "the caller of pay gets nothing back");
    }

    function test_refund_viaDirectFinalize_thenSettleIsNotActive() public {
        uint256 id = _ruled(Arb.Direction.Refund, ATT_A);
        _pastWindow();
        arb.finalize(id);
        _assertRefunded(id);
        vm.expectRevert(abi.encodeWithSelector(Escrow.NotActive.selector, id));
        escrow.settle(id);
    }

    function test_refund_worksEvenThoughSellerClaimedDelivery() public {
        uint256 id = _ruled(Arb.Direction.Refund, ATT_A); // _ruled marks delivered
        assertTrue(escrow.jobs(id).delivered);
        _pastWindow();
        escrow.settle(id);
        _assertRefunded(id);
    }

    function test_refund_withoutDeliveryClaim() public {
        uint256 id = _pay();
        _file(id);
        _rule(id, Arb.Direction.Refund);
        _pastWindow();
        escrow.settle(id);
        _assertRefunded(id);
    }

    function test_afterRefund_jobReadsZeroToArbiter() public {
        uint256 id = _ruled(Arb.Direction.Refund, ATT_A);
        _pastWindow();
        escrow.settle(id);
        (, address payee,,) = escrow.paymentInfo(id);
        assertEq(payee, address(0));
    }
}

contract JobEscrowDisputeTest is EscrowBase {
    function test_dispute_freezesSettlement() public {
        uint256 id = _ruled(Arb.Direction.Release, ATT_A);
        vm.prank(refundTo);
        arb.dispute(id, COUNTER);
        _pastWindow();
        vm.expectRevert(abi.encodeWithSelector(Escrow.NotSettleable.selector, id));
        escrow.settle(id);
        vm.expectRevert(Arb.BadStatus.selector);
        arb.finalize(id);
        assertEq(usdc.balanceOf(address(escrow)), PRICE, "held");
    }

    /// @dev Release overturned: the buyer's side was right. Refund executes inside `resolve`.
    function test_releaseOverturned_refundsAndBondGoesToDisputer() public {
        uint256 id = _ruled(Arb.Direction.Release, ATT_A);
        vm.prank(refundTo);
        arb.dispute(id, COUNTER);
        vm.prank(owner);
        arb.resolve(id, Arb.Direction.Refund);
        _assertRefunded(id);
        assertEq(uint8(arb.rulings(id).status), uint8(Arb.Status.Overturned));
        assertEq(arb.credit(refundTo), MIN_BOND, "bond to the harmed party");
        assertEq(arb.credit(op), 0, "operator loses it");
        vm.expectRevert(abi.encodeWithSelector(Escrow.NotActive.selector, id));
        escrow.settle(id);
    }

    /// @dev Refund overturned: the seller was right. The stored direction still says Refund, and the
    ///      seller must be the one paid. This is the trap the plan warns about.
    function test_refundOverturned_paysSellerAndBondGoesToSeller() public {
        uint256 id = _ruled(Arb.Direction.Refund, ATT_A);
        vm.prank(seller);
        arb.dispute(id, COUNTER);
        vm.prank(owner);
        arb.resolve(id, Arb.Direction.Release);
        assertEq(usdc.balanceOf(address(escrow)), PRICE, "resolve moves nothing on a final Release");
        Arb.Ruling memory r = arb.rulings(id);
        assertEq(uint8(r.status), uint8(Arb.Status.Overturned));
        assertEq(uint8(r.direction), uint8(Arb.Direction.Refund), "the stored direction is the original one");
        vm.prank(stranger);
        escrow.settle(id);
        _assertReleased(id);
        assertEq(arb.credit(seller), MIN_BOND, "bond to the harmed party");
    }

    function test_releaseDisputedAndUpheld_paysSeller() public {
        uint256 id = _ruled(Arb.Direction.Release, ATT_A);
        vm.prank(refundTo);
        arb.dispute(id, COUNTER);
        vm.prank(owner);
        arb.resolve(id, Arb.Direction.Release);
        escrow.settle(id);
        _assertReleased(id);
        assertEq(arb.credit(op), MIN_BOND, "operator keeps its bond");
    }

    function test_refundDisputedAndUpheld_refunds() public {
        uint256 id = _ruled(Arb.Direction.Refund, ATT_A);
        vm.prank(seller);
        arb.dispute(id, COUNTER);
        vm.prank(owner);
        arb.resolve(id, Arb.Direction.Refund);
        _assertRefunded(id);
        assertEq(arb.credit(op), MIN_BOND);
    }

    function test_dispute_onlyHarmedParty() public {
        uint256 rel = _ruled(Arb.Direction.Release, ATT_A);
        // The caller of pay is not a party when refundTo differs: refundTo disputes.
        vm.prank(buyer);
        vm.expectRevert(Arb.NotHarmedParty.selector);
        arb.dispute(rel, COUNTER);
        vm.prank(seller); // the seller is not harmed by a Release
        vm.expectRevert(Arb.NotHarmedParty.selector);
        arb.dispute(rel, COUNTER);

        uint256 ref = _ruled(Arb.Direction.Refund, ATT_B);
        vm.prank(refundTo); // refundTo is not harmed by a Refund
        vm.expectRevert(Arb.NotHarmedParty.selector);
        arb.dispute(ref, COUNTER);
    }

    function test_dispute_afterWindow_reverts_thenSettles() public {
        uint256 id = _ruled(Arb.Direction.Release, ATT_A);
        _pastWindow();
        vm.prank(refundTo);
        vm.expectRevert(Arb.WindowClosed.selector);
        arb.dispute(id, COUNTER);
        escrow.settle(id);
        _assertReleased(id);
    }

    function test_resolve_ownerOnly() public {
        uint256 id = _ruled(Arb.Direction.Release, ATT_A);
        vm.prank(refundTo);
        arb.dispute(id, COUNTER);
        vm.prank(op);
        vm.expectRevert(Owned2Step.NotOwner.selector);
        arb.resolve(id, Arb.Direction.Refund);
    }

    function test_ownerSilent_voided_deliveredGoesToSellerAtBackstop() public {
        uint256 id = _ruled(Arb.Direction.Refund, ATT_A);
        vm.prank(seller);
        arb.dispute(id, COUNTER);
        vm.warp(block.timestamp + RESOLUTION);
        vm.prank(owner);
        vm.expectRevert(Arb.ResolutionExpired.selector);
        arb.resolve(id, Arb.Direction.Refund);
        arb.expire(id);
        assertEq(uint8(arb.rulings(id).status), uint8(Arb.Status.Voided));
        assertEq(arb.credit(op), MIN_BOND, "bond back to the staker");
        vm.expectRevert(abi.encodeWithSelector(Escrow.NotSettleable.selector, id));
        escrow.settle(id);
        vm.expectRevert(Escrow.BackstopNotReached.selector);
        escrow.releaseAfterBackstop(id);
        vm.warp(escrow.jobs(id).releaseAt);
        escrow.releaseAfterBackstop(id);
        _assertReleased(id);
    }

    function test_ownerSilent_voided_undeliveredGoesBackToRefundTo() public {
        uint256 id = _pay();
        _file(id);
        _rule(id, Arb.Direction.Release);
        vm.prank(refundTo);
        arb.dispute(id, COUNTER);
        vm.warp(block.timestamp + RESOLUTION);
        arb.expire(id);
        vm.prank(stranger);
        escrow.refundAfterDeadline(id);
        _assertRefunded(id);
    }

    /// @dev The worst timing the arbiter allows: ruled on its last possible second, disputed on the last second
    ///      of the window, resolved on the last second of the resolution period. A refund must still execute.
    function testFuzz_latestPossibleRulingAndDispute_refundStillExecutes(uint32 disputeDelay, uint32 resolveDelay) public {
        uint256 id = _pay();
        _deliver(id);
        _file(id);
        uint64 releaseAt = escrow.jobs(id).releaseAt;
        vm.warp(uint256(releaseAt) - WINDOW - RESOLUTION - 1);
        _rule(id, Arb.Direction.Release);
        vm.warp(block.timestamp + bound(disputeDelay, 0, WINDOW - 1));
        vm.prank(refundTo);
        arb.dispute(id, COUNTER);
        vm.warp(block.timestamp + bound(resolveDelay, 0, RESOLUTION - 1));
        assertLt(block.timestamp, releaseAt, "the whole dispute ends before the backstop");
        vm.prank(owner);
        arb.resolve(id, Arb.Direction.Refund);
        _assertRefunded(id);
    }
}

contract JobEscrowDeadlineTest is EscrowBase {
    function test_noDelivery_refundAfterDeadline_byAnyone() public {
        uint256 id = _pay();
        vm.warp(escrow.jobs(id).deliverBy + 1);
        vm.prank(stranger);
        escrow.refundAfterDeadline(id);
        _assertRefunded(id);
    }

    function test_refundAfterDeadline_boundary() public {
        uint256 id = _pay();
        vm.warp(escrow.jobs(id).deliverBy);
        vm.expectRevert(Escrow.DeadlineNotPassed.selector);
        escrow.refundAfterDeadline(id);
        vm.warp(block.timestamp + 1);
        escrow.refundAfterDeadline(id);
        _assertRefunded(id);
    }

    function test_markDelivered_boundary() public {
        uint256 id = _pay();
        vm.warp(escrow.jobs(id).deliverBy); // on the deadline is in time
        _deliver(id);
        uint256 late = _pay();
        vm.warp(escrow.jobs(late).deliverBy + 1);
        vm.prank(seller);
        vm.expectRevert(Escrow.DeadlinePassed.selector);
        escrow.markDelivered(late, DELIVERY_HASH);
    }

    function test_deliveryClaim_blocksDeadlineRefund() public {
        uint256 id = _pay();
        _deliver(id);
        vm.warp(escrow.jobs(id).deliverBy + 1);
        vm.expectRevert(Escrow.AlreadyDelivered.selector);
        escrow.refundAfterDeadline(id);
    }

    function test_liveRuling_blocksDeadlineRefund() public {
        uint256 id = _pay();
        _file(id);
        _rule(id, Arb.Direction.Release);
        vm.warp(escrow.jobs(id).deliverBy + 1);
        vm.expectRevert(abi.encodeWithSelector(Escrow.RulingPending.selector, id));
        escrow.refundAfterDeadline(id);
    }

    function test_ruling_blocksLaterDeliveryClaim() public {
        uint256 id = _pay();
        _file(id);
        _rule(id, Arb.Direction.Refund);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(Escrow.AlreadyRuled.selector, id));
        escrow.markDelivered(id, DELIVERY_HASH);
    }

    function test_backstop_deliveredNeverRuled_paysSellerAtReleaseAt() public {
        uint256 id = _pay();
        _deliver(id);
        vm.warp(uint256(escrow.jobs(id).releaseAt) - 1);
        vm.expectRevert(Escrow.BackstopNotReached.selector);
        escrow.releaseAfterBackstop(id);
        vm.warp(block.timestamp + 1);
        vm.prank(stranger);
        escrow.releaseAfterBackstop(id);
        _assertReleased(id);
    }

    function test_backstop_undeliveredSellerCanNeverTakeTheMoney() public {
        uint256 id = _pay();
        vm.warp(uint256(escrow.jobs(id).releaseAt) + 365 days);
        vm.prank(seller);
        vm.expectRevert(Escrow.NotDelivered.selector);
        escrow.releaseAfterBackstop(id);
        escrow.refundAfterDeadline(id); // the buyer's way out is still open, however late
        _assertRefunded(id);
    }

    function test_backstop_blockedByLiveRuling() public {
        uint256 id = _ruled(Arb.Direction.Refund, ATT_A);
        vm.warp(escrow.jobs(id).releaseAt);
        vm.expectRevert(abi.encodeWithSelector(Escrow.RulingPending.selector, id));
        escrow.releaseAfterBackstop(id);
        // Nobody finalized in 16 days. The refund is now impossible (the interface's promise) so the ruling
        // cannot be carried out, and only `expire` remains; the seller then collects.
        vm.expectRevert(Escrow.RefundTooLate.selector);
        escrow.settle(id);
        arb.expire(id);
        escrow.releaseAfterBackstop(id);
        _assertReleased(id);
    }

    function test_rulingTooLate_revertsLockupTooShort_jobFallsToBackstop() public {
        uint256 id = _pay();
        _deliver(id);
        _file(id);
        uint64 releaseAt = escrow.jobs(id).releaseAt;
        vm.warp(uint256(releaseAt) - WINDOW - RESOLUTION); // one second past the last allowed moment
        vm.prank(op);
        vm.expectRevert(Arb.LockupTooShort.selector);
        arb.rule{value: MIN_BOND}(id, refundTo, EV_REFUND_TO, Arb.Direction.Refund);
        vm.warp(releaseAt);
        escrow.releaseAfterBackstop(id);
        _assertReleased(id);
    }

    function test_rulingStaysPossibleWellAfterTheDeliveryDeadline() public {
        vm.prank(buyer);
        uint256 id = escrow.pay(seller, PRICE, refundTo, SPEC, uint64(block.timestamp) + 1 days); // the longest allowed
        _file(id);
        vm.warp(escrow.jobs(id).deliverBy + 22 hours);
        _rule(id, Arb.Direction.Refund);
        assertEq(uint8(arb.rulings(id).status), uint8(Arb.Status.Ruled));
    }
}

/// @notice On-chain the signer of a ruling is the operator key: `recordVerdict` and `rule` both check it.
///         The ed25519 signature of the API verdict is checked by the relayer, off chain; those wrong-key
///         cases are in test/job-escrow-verdict.test.mjs.
contract JobEscrowWrongSignerTest is EscrowBase {
    function test_recordVerdict_onlyOperator() public {
        uint256 id = _pay();
        address[4] memory wrong = [stranger, buyer, seller, owner];
        for (uint256 i; i < wrong.length; i++) {
            vm.prank(wrong[i]);
            vm.expectRevert(Escrow.NotOperator.selector);
            escrow.recordVerdict(id, ATT_A, Arb.Direction.Release);
        }
        assertEq(escrow.attestationJob(ATT_A), 0, "nothing recorded");
    }

    function test_rule_onlyOperator() public {
        uint256 id = _pay();
        _file(id);
        address[4] memory wrong = [stranger, refundTo, seller, owner];
        for (uint256 i; i < wrong.length; i++) {
            vm.deal(wrong[i], MIN_BOND);
            vm.prank(wrong[i]);
            vm.expectRevert(Operated.NotOperator.selector);
            arb.rule{value: MIN_BOND}(id, refundTo, EV_REFUND_TO, Arb.Direction.Release);
        }
        assertEq(uint8(arb.rulings(id).status), uint8(Arb.Status.None));
    }

    function test_rotatedOperator_oldKeyRefused_newKeyWorks() public {
        uint256 id = _pay();
        _file(id);
        address next = makeAddr("newOperator");
        vm.deal(next, MIN_BOND);
        vm.prank(owner);
        arb.setOperator(next);

        vm.prank(op);
        vm.expectRevert(Escrow.NotOperator.selector);
        escrow.recordVerdict(id, ATT_A, Arb.Direction.Refund);
        vm.prank(op);
        vm.expectRevert(Operated.NotOperator.selector);
        arb.rule{value: MIN_BOND}(id, refundTo, EV_REFUND_TO, Arb.Direction.Refund);

        vm.startPrank(next);
        escrow.recordVerdict(id, ATT_A, Arb.Direction.Refund);
        arb.rule{value: MIN_BOND}(id, refundTo, EV_REFUND_TO, Arb.Direction.Refund);
        vm.stopPrank();
        _pastWindow();
        escrow.settle(id);
        _assertRefunded(id);
    }

    function test_forgedEvidenceHash_cannotBeRuledOn() public {
        uint256 id = _pay();
        _file(id);
        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(Arb.NoEvidenceFiled.selector, id, refundTo));
        arb.rule{value: MIN_BOND}(id, refundTo, keccak256("not what was filed"), Arb.Direction.Refund);
    }

    function test_fileEvidence_onlyParties_callerOfPayIsNotOne() public {
        uint256 id = _pay();
        vm.prank(stranger);
        vm.expectRevert(Arb.NotAParty.selector);
        arb.fileEvidence(id, EV_REFUND_TO);
        vm.prank(buyer); // refundTo differs from the caller of pay
        vm.expectRevert(Arb.NotAParty.selector);
        arb.fileEvidence(id, EV_REFUND_TO);
    }

    function test_operatorRotatedOntoAParty_cannotRule() public {
        uint256 id = _pay();
        _file(id);
        vm.prank(owner);
        arb.setOperator(seller); // bad, but the arbiter still refuses
        vm.deal(seller, MIN_BOND);
        vm.prank(seller);
        vm.expectRevert(Arb.OperatorIsParty.selector);
        arb.rule{value: MIN_BOND}(id, seller, EV_SELLER, Arb.Direction.Release);
    }
}

contract JobEscrowReplayTest is EscrowBase {
    function test_verdictReplayedOnAnotherJob_reverts() public {
        uint256 a = _pay();
        uint256 b = _pay();
        vm.startPrank(op);
        escrow.recordVerdict(a, ATT_A, Arb.Direction.Refund);
        vm.expectRevert(abi.encodeWithSelector(Escrow.VerdictReplayed.selector, ATT_A, a));
        escrow.recordVerdict(b, ATT_A, Arb.Direction.Refund);
        vm.stopPrank();
        assertEq(escrow.attestationJob(ATT_A), a);
        assertEq(escrow.verdicts(b).attestationHash, bytes32(0));
    }

    function test_sameVerdictSameJobTwice_reverts() public {
        uint256 a = _pay();
        vm.startPrank(op);
        escrow.recordVerdict(a, ATT_A, Arb.Direction.Refund);
        vm.expectRevert(abi.encodeWithSelector(Escrow.VerdictReplayed.selector, ATT_A, a));
        escrow.recordVerdict(a, ATT_A, Arb.Direction.Refund);
        vm.stopPrank();
    }

    function test_secondVerdictForSameJob_reverts() public {
        uint256 a = _pay();
        vm.startPrank(op);
        escrow.recordVerdict(a, ATT_A, Arb.Direction.Refund);
        vm.expectRevert(abi.encodeWithSelector(Escrow.VerdictAlreadyRecorded.selector, a));
        escrow.recordVerdict(a, ATT_B, Arb.Direction.Release); // the operator cannot flip it either
        vm.stopPrank();
        assertEq(uint8(escrow.verdicts(a).direction), uint8(Arb.Direction.Refund));
    }

    function test_ruleTwice_reverts() public {
        uint256 id = _ruled(Arb.Direction.Refund, ATT_A);
        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(Arb.AlreadyRuled.selector, id));
        arb.rule{value: MIN_BOND}(id, refundTo, EV_REFUND_TO, Arb.Direction.Release);
    }

    function test_verdictAfterRuling_reverts() public {
        uint256 id = _pay();
        _file(id);
        _rule(id, Arb.Direction.Refund);
        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(Escrow.AlreadyRuled.selector, id));
        escrow.recordVerdict(id, ATT_A, Arb.Direction.Refund);
    }

    function test_replayAfterSettlement_cannotReachTheMoney() public {
        uint256 id = _ruled(Arb.Direction.Release, ATT_A);
        _pastWindow();
        escrow.settle(id);

        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(Escrow.NotActive.selector, id));
        escrow.recordVerdict(id, ATT_B, Arb.Direction.Refund);
        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(Arb.AlreadyRuled.selector, id));
        arb.rule{value: MIN_BOND}(id, refundTo, EV_REFUND_TO, Arb.Direction.Refund);
        vm.expectRevert(abi.encodeWithSelector(Escrow.NotActive.selector, id));
        escrow.settle(id);
        vm.expectRevert(abi.encodeWithSelector(Escrow.NotActive.selector, id));
        escrow.refundAfterDeadline(id);
        vm.expectRevert(abi.encodeWithSelector(Escrow.NotActive.selector, id));
        escrow.releaseAfterBackstop(id);
    }

    function test_jobRefundedByDeadline_cannotBeRuledOrEvidenced() public {
        uint256 id = _pay();
        vm.warp(escrow.jobs(id).deliverBy + 1);
        escrow.refundAfterDeadline(id);
        vm.prank(refundTo);
        vm.expectRevert(Arb.NotAParty.selector);
        arb.fileEvidence(id, EV_REFUND_TO);
        vm.prank(op);
        vm.expectRevert(Arb.UnknownPayment.selector);
        arb.rule{value: MIN_BOND}(id, refundTo, EV_REFUND_TO, Arb.Direction.Release);
    }

    function test_recordVerdict_validation() public {
        uint256 id = _pay();
        vm.startPrank(op);
        vm.expectRevert(Escrow.ZeroHash.selector);
        escrow.recordVerdict(id, bytes32(0), Arb.Direction.Refund);
        vm.expectRevert(Escrow.BadDirection.selector);
        escrow.recordVerdict(id, ATT_A, Arb.Direction.None);
        vm.expectRevert(abi.encodeWithSelector(Escrow.NotActive.selector, 99));
        escrow.recordVerdict(99, ATT_A, Arb.Direction.Refund);
        vm.stopPrank();
    }
}

/// @dev Random walks over every entry point, with the money tracked independently of the contract.
contract JobEscrowHandler is Test {
    Escrow internal immutable escrow;
    Arb internal immutable arb;
    MockUSDC internal immutable usdc;
    address internal immutable owner;
    address internal immutable op;
    address internal immutable buyer;
    address internal immutable refundTo;
    address internal immutable seller;

    uint256[] public ids;
    /// @dev Sum of payments into jobs that reached Funded.
    uint256 public paidIn;

    constructor(Escrow e, Arb a, MockUSDC u, address owner_, address op_, address buyer_, address refundTo_, address seller_) {
        escrow = e;
        arb = a;
        usdc = u;
        owner = owner_;
        op = op_;
        buyer = buyer_;
        refundTo = refundTo_;
        seller = seller_;
    }

    function _pick(uint256 seed) private view returns (uint256) {
        return ids[seed % ids.length];
    }

    function idsLength() external view returns (uint256) {
        return ids.length;
    }

    function pay(uint256 amount, uint64 delay) external {
        amount = bound(amount, 1, 1_000e6);
        vm.prank(buyer);
        uint256 id = escrow.pay(seller, amount, refundTo, keccak256("s"), uint64(block.timestamp) + uint64(bound(delay, 1, 1 days)));
        ids.push(id);
        paidIn += amount;
    }

    function deliver(uint256 seed) external {
        if (ids.length == 0) return;
        vm.prank(seller);
        try escrow.markDelivered(_pick(seed), keccak256("d")) {} catch {}
    }

    function rule(uint256 seed, bool refund) external {
        if (ids.length == 0) return;
        uint256 id = _pick(seed);
        vm.prank(refundTo);
        try arb.fileEvidence(id, keccak256("e")) {} catch {}
        vm.deal(op, 10e18);
        vm.prank(op);
        try arb.rule{value: 5e18}(id, refundTo, keccak256("e"), refund ? Arb.Direction.Refund : Arb.Direction.Release) {} catch {}
    }

    function dispute(uint256 seed, bool asSeller) external {
        if (ids.length == 0) return;
        vm.prank(asSeller ? seller : refundTo);
        try arb.dispute(_pick(seed), keccak256("c")) {} catch {}
    }

    function resolve(uint256 seed, bool refund) external {
        if (ids.length == 0) return;
        vm.prank(owner);
        try arb.resolve(_pick(seed), refund ? Arb.Direction.Refund : Arb.Direction.Release) {} catch {}
    }

    function settle(uint256 seed) external {
        if (ids.length == 0) return;
        try escrow.settle(_pick(seed)) {} catch {}
    }

    function finalizeDirect(uint256 seed) external {
        if (ids.length == 0) return;
        try arb.finalize(_pick(seed)) {} catch {}
    }

    function expire(uint256 seed) external {
        if (ids.length == 0) return;
        try arb.expire(_pick(seed)) {} catch {}
    }

    function refundAfterDeadline(uint256 seed) external {
        if (ids.length == 0) return;
        try escrow.refundAfterDeadline(_pick(seed)) {} catch {}
    }

    function releaseAfterBackstop(uint256 seed) external {
        if (ids.length == 0) return;
        try escrow.releaseAfterBackstop(_pick(seed)) {} catch {}
    }

    function warp(uint32 by) external {
        vm.warp(block.timestamp + bound(by, 1, 3 days));
    }
}

contract JobEscrowInvariantTest is EscrowBase {
    JobEscrowHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new JobEscrowHandler(escrow, arb, usdc, owner, op, buyer, refundTo, seller);
        usdc.mint(buyer, 10_000_000e6);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    /// forge-config: ci.invariant.runs = 128
    /// forge-config: ci.invariant.depth = 64
    function invariant_escrowHoldsExactlyWhatIsOwed() public view {
        assertEq(usdc.balanceOf(address(escrow)), escrow.totalHeld(), "balance == totalHeld");
        uint256 held;
        for (uint256 i; i < handler.idsLength(); i++) {
            Escrow.Job memory j = escrow.jobs(handler.ids(i));
            if (j.state == Escrow.State.Funded) held += j.amount;
        }
        assertEq(held, escrow.totalHeld(), "sum of Funded jobs == totalHeld");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    /// forge-config: ci.invariant.runs = 128
    /// forge-config: ci.invariant.depth = 64
    function invariant_noMoneyCreatedOrLost() public view {
        assertEq(
            usdc.balanceOf(seller) + usdc.balanceOf(refundTo) + usdc.balanceOf(address(escrow)),
            handler.paidIn(),
            "everything paid in is with the seller, the refund wallet or the escrow"
        );
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    /// forge-config: ci.invariant.runs = 128
    /// forge-config: ci.invariant.depth = 64
    function invariant_finalRulingsMatchWhereTheMoneyWent() public view {
        for (uint256 i; i < handler.idsLength(); i++) {
            uint256 id = handler.ids(i);
            Escrow.State s = escrow.jobs(id).state;
            Arb.Ruling memory r = arb.rulings(id);
            bool finalRefund = (r.status == Arb.Status.Finalized && r.direction == Arb.Direction.Refund)
                || (r.status == Arb.Status.Overturned && r.direction == Arb.Direction.Release);
            bool finalRelease = (r.status == Arb.Status.Finalized && r.direction == Arb.Direction.Release)
                || (r.status == Arb.Status.Overturned && r.direction == Arb.Direction.Refund);
            if (finalRefund) assertEq(uint8(s), uint8(Escrow.State.Refunded), "final Refund is paid at once");
            if (finalRelease) assertTrue(s == Escrow.State.Released || s == Escrow.State.Funded, "final Release never refunds");
        }
    }
}
