// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IRefundProtocolV2} from "../PredgeRefundArbiterV2.sol";
import {ICircleRefundProtocol} from "../interfaces/ICircleRefundProtocol.sol";

interface IPredgeRefundArbiterView {
    function refundProtocol() external view returns (address);
}

/// @title  CircleRefundProtocolAdapter
/// @notice Lets an unchanged `PredgeRefundArbiterV2` act as the arbiter of Circle's Refund Protocol.
///         The adapter is the address set as `arbiter` in Circle's constructor; it accepts write calls
///         only from the one Predge arbiter bound to it, and it translates the read side:
///
///           Predge `paymentInfo`         <- Circle `payments(id)`
///             payer                      <- refundTo (who a refund is paid to)
///             payee                      <- to
///             amount                     <- amount * amountScale   (USDC 6 decimals -> native wei)
///             releaseTimestamp           <- releaseTimestamp
///
///         A payment that does not exist, is already refunded, or has been partly withdrawn reads as
///         all-zero, so no evidence can be filed and no ruling can be made on it.
///
///         Wiring is a three-way cycle (Circle needs the adapter address, the Predge arbiter needs the
///         adapter address, the adapter needs both), so the adapter is deployed first and `bind` is
///         called once by its deployer after the other two exist. `bind` checks both directions of the
///         wiring and can never be called again.
///
/// @dev    Holds no funds and has no owner. It does not expose Circle's `earlyWithdrawByArbiter`,
///         `depositArbiterFunds` or `withdrawArbiterFunds`: a refund is paid only from the recipient's
///         balance inside Circle's contract. If that balance cannot cover it, Circle reverts, the
///         Predge `finalize`/`resolve` reverts with it, and the ruling can only be voided by `expire`.
contract CircleRefundProtocolAdapter is IRefundProtocolV2 {
    address public immutable deployer;
    /// @notice Multiplier from the token's units to the native wei the Predge bond is sized in
    ///         (1e12 on Arc: USDC ERC-20 has 6 decimals, native USDC gas has 18).
    uint256 public immutable amountScale;

    ICircleRefundProtocol public circle;
    address public predgeArbiter;

    event Bound(address indexed circle, address indexed predgeArbiter);
    event RefundForwarded(uint256 indexed paymentID);
    event RefundAlreadyDone(uint256 indexed paymentID);
    event LockupForwarded(address indexed recipient, uint256 lockupSeconds);

    error ZeroAddress();
    error ZeroScale();
    error NotDeployer();
    error AlreadyBound();
    error NotBound();
    error NotCircleArbiter();
    error ArbiterNotWired();
    error NotPredgeArbiter();

    constructor(uint256 amountScale_) {
        if (amountScale_ == 0) revert ZeroScale();
        deployer = msg.sender;
        amountScale = amountScale_;
    }

    /// @notice One-time wiring, deployer only. Requires `circle_.arbiter() == this` and
    ///         `predgeArbiter_.refundProtocol() == this`.
    function bind(address circle_, address predgeArbiter_) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (address(circle) != address(0)) revert AlreadyBound();
        if (circle_ == address(0) || predgeArbiter_ == address(0)) revert ZeroAddress();
        if (ICircleRefundProtocol(circle_).arbiter() != address(this)) revert NotCircleArbiter();
        if (IPredgeRefundArbiterView(predgeArbiter_).refundProtocol() != address(this)) revert ArbiterNotWired();
        circle = ICircleRefundProtocol(circle_);
        predgeArbiter = predgeArbiter_;
        emit Bound(circle_, predgeArbiter_);
    }

    modifier onlyPredgeArbiter() {
        if (msg.sender != predgeArbiter || predgeArbiter == address(0)) revert NotPredgeArbiter();
        _;
    }

    /// @inheritdoc IRefundProtocolV2
    function paymentInfo(uint256 paymentID)
        external
        view
        returns (address payer, address payee, uint256 amount, uint256 releaseTimestamp)
    {
        if (address(circle) == address(0)) revert NotBound();
        (address to, uint256 amt, uint256 release, address refundTo, uint256 withdrawn, bool refunded) =
            circle.payments(paymentID);
        if (to == address(0) || refunded || withdrawn != 0) return (address(0), address(0), 0, 0);
        return (refundTo, to, amt * amountScale, release);
    }

    /// @notice Forward a Predge refund to Circle. If the payment was already refunded (for example the
    ///         recipient called `refundByRecipient` during the window), the outcome the ruling asks for
    ///         already holds, so this returns instead of reverting.
    function refundByArbiter(uint256 paymentID) external onlyPredgeArbiter {
        (,,,,, bool refunded) = circle.payments(paymentID);
        if (refunded) {
            emit RefundAlreadyDone(paymentID);
            return;
        }
        emit RefundForwarded(paymentID);
        circle.refundByArbiter(paymentID);
    }

    /// @notice Forward a lockup change. Predge's own bound is (window + 14 days, 365 days]; Circle's
    ///         cap of 180 days also applies and reverts above it.
    function setLockupSeconds(address recipient, uint256 recipientLockupSeconds) external onlyPredgeArbiter {
        emit LockupForwarded(recipient, recipientLockupSeconds);
        circle.setLockupSeconds(recipient, recipientLockupSeconds);
    }
}
