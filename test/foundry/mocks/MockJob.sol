// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Programmable stand-in for AgentJob's `jobs(uint256)` getter, so the bond can be
///         driven through job states the real AgentJob only reaches via its own flow.
contract MockJob {
    struct J {
        address client;
        address provider;
        address evaluator;
        uint96 escrow;
        bytes32 specHash;
        bytes32 deliverable;
        bytes32 reason;
        uint8 state;
    }

    mapping(uint256 => J) internal _j;

    function set(uint256 id, address provider, address evaluator, bytes32 specHash, bytes32 deliverable, uint8 state) external {
        _j[id] = J(address(0xC11E), provider, evaluator, 0, specHash, deliverable, bytes32(0), state);
    }

    function jobs(uint256 id)
        external
        view
        returns (address, address, address, uint96, bytes32, bytes32, bytes32, uint8)
    {
        J storage j = _j[id];
        return (j.client, j.provider, j.evaluator, j.escrow, j.specHash, j.deliverable, j.reason, j.state);
    }
}
