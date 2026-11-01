// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice DEMO / TEST ONLY stand-in for a Refund Protocol. It holds NO funds and moves NO
///         money: `refundByArbiter` only flips a flag and emits an event, so a "refund" here
///         proves the arbiter made the call and nothing more. It exposes the payment parties the
///         v2 arbiter binds evidence to. Anyone can create a payment record; that is intended for
///         demos and is the reason this contract must never be treated as a payment rail.
contract MockRefundProtocolV2 {
    struct Payment {
        address payer;
        address payee;
        uint256 amount;
        uint256 releaseTimestamp;
        bool refunded;
    }

    address public immutable arbiter;
    uint256 public paymentCount;
    uint256 public refundCount;
    mapping(uint256 => Payment) public payments;
    mapping(address => uint256) public lockupSeconds;

    event PaymentRecorded(uint256 indexed paymentID, address indexed payer, address indexed payee, uint256 amount, uint256 releaseTimestamp);
    event RefundByArbiter(uint256 indexed paymentID, address indexed caller);
    event LockupSet(address indexed recipient, uint256 lockupSeconds);

    error CallerNotArbiter();
    error UnknownPayment();
    error AlreadyRefunded();
    error AlreadyReleased();
    error ZeroAddress();

    constructor(address arbiter_) {
        if (arbiter_ == address(0)) revert ZeroAddress();
        arbiter = arbiter_;
    }

    /// @notice Record a payment's parties (no value moves). Demo only.
    function recordPayment(address payer, address payee, uint256 amount, uint256 releaseTimestamp)
        external
        returns (uint256 paymentID)
    {
        if (payer == address(0) || payee == address(0)) revert ZeroAddress();
        paymentID = ++paymentCount;
        payments[paymentID] = Payment(payer, payee, amount, releaseTimestamp, false);
        emit PaymentRecorded(paymentID, payer, payee, amount, releaseTimestamp);
    }

    function paymentInfo(uint256 paymentID)
        external
        view
        returns (address payer, address payee, uint256 amount, uint256 releaseTimestamp)
    {
        Payment storage p = payments[paymentID];
        return (p.payer, p.payee, p.amount, p.releaseTimestamp);
    }

    function refundByArbiter(uint256 paymentID) external {
        if (msg.sender != arbiter) revert CallerNotArbiter();
        Payment storage p = payments[paymentID];
        if (p.payee == address(0)) revert UnknownPayment();
        if (p.refunded) revert AlreadyRefunded();
        if (block.timestamp >= p.releaseTimestamp) revert AlreadyReleased();
        p.refunded = true;
        refundCount += 1;
        emit RefundByArbiter(paymentID, msg.sender);
    }

    function setLockupSeconds(address recipient, uint256 recipientLockupSeconds) external {
        if (msg.sender != arbiter) revert CallerNotArbiter();
        lockupSeconds[recipient] = recipientLockupSeconds;
        emit LockupSet(recipient, recipientLockupSeconds);
    }
}
