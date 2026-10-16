// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice A stand-in for Circle's Refund Protocol, only for exercising the arbiter end to end.
/// It records the calls the arbiter makes so a demo run has something to read back on chain.
contract MockRefundProtocol {
    address public arbiter;
    uint256 public refundCount;
    mapping(uint256 => bool) public refunded;
    mapping(address => uint256) public lockupSeconds;

    event RefundByArbiter(uint256 indexed paymentID, address indexed caller);
    event LockupSet(address indexed recipient, uint256 seconds_);

    error CallerNotAllowed();

    constructor(address arbiter_) {
        arbiter = arbiter_;
    }

    function setArbiter(address arbiter_) external {
        if (msg.sender != arbiter) revert CallerNotAllowed();
        arbiter = arbiter_;
    }

    function refundByArbiter(uint256 paymentID) external {
        if (msg.sender != arbiter) revert CallerNotAllowed();
        refunded[paymentID] = true;
        refundCount += 1;
        emit RefundByArbiter(paymentID, msg.sender);
    }

    function setLockupSeconds(address recipient, uint256 recipientLockupSeconds) external {
        if (msg.sender != arbiter) revert CallerNotAllowed();
        lockupSeconds[recipient] = recipientLockupSeconds;
        emit LockupSet(recipient, recipientLockupSeconds);
    }
}
