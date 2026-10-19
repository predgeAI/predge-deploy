// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Owned2Step} from "./access/PredgeAccess.sol";

/// @title  PredgeSettlementV2
/// @notice Receipt layer for Predge's pay-per-call data API: an agent pays for a route in the
///         chain's native token and this contract emits a `Paid` receipt.
/// @dev    Amounts are in native wei of the chain (on Arc the native token is USDC with 18
///         decimals at the protocol level; the ERC-20 interface of Arc's USDC uses 6, so never
///         mix the two units). The owner (a Safe) withdraws accumulated payments to a non-zero
///         address; there is no other admin power and no upgrade path. Forced value (selfdestruct
///         or coinbase) is included in `withdraw`, so it cannot be stranded.
contract PredgeSettlementV2 is Owned2Step {
    /// @param payer     who paid
    /// @param route     keccak256 of the route id
    /// @param amount    native wei paid
    /// @param timestamp block time
    /// @param meta      optional request reference
    event Paid(address indexed payer, bytes32 indexed route, uint256 amount, uint256 timestamp, string meta);
    event Withdrawn(address indexed to, uint256 amount);

    error ZeroPayment();
    error WithdrawFailed();

    /// @param owner_ the Safe that may withdraw
    constructor(address owner_) Owned2Step(owner_) {}

    /// @notice Pay for a route; emits a `Paid` receipt.
    function payForRoute(bytes32 route, string calldata meta) external payable {
        if (msg.value == 0) revert ZeroPayment();
        emit Paid(msg.sender, route, msg.value, block.timestamp, meta);
    }

    /// @notice Owner withdraws the whole balance to `to`. Reverts for the zero address.
    function withdraw(address payable to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = address(this).balance;
        emit Withdrawn(to, bal);
        (bool ok,) = to.call{value: bal}("");
        if (!ok) revert WithdrawFailed();
    }

    /// @notice A bare transfer still produces a receipt, under the route `bytes32("direct")`.
    receive() external payable {
        if (msg.value == 0) revert ZeroPayment();
        emit Paid(msg.sender, bytes32("direct"), msg.value, block.timestamp, "");
    }
}
