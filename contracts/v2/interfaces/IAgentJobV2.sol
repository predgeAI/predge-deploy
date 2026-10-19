// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The slice of `AgentJobV2` that other Predge contracts read and drive.
interface IAgentJobV2 {
    /// @dev Forward-only, except that `Open` and `Submitted` may each end in `Expired`.
    enum State {
        None,
        Open,
        Submitted,
        Completed,
        Rejected,
        Expired
    }

    struct Job {
        address client; // pays; refunded on reject / expiry
        address provider; // does the work; paid on complete
        address evaluator; // the only address that can complete or reject
        uint256 escrow; // native value held for this job until it ends
        uint64 expiredAt; // the provider must submit strictly before this
        uint64 submittedAt; // 0 until submitted
        State state;
        bool hashedOnChain; // true if the deliverable hash was computed on-chain from submitted bytes
        bytes32 specHash; // the committed acceptance test (the Predge requestHash)
        bytes32 deliverable; // sha256 of the provider's output (zero until submitted)
        bytes32 reason; // the evaluator's attestation commitment (zero until decided)
    }

    function getJob(uint256 jobId) external view returns (Job memory);
    function complete(uint256 jobId, bytes32 reason, bytes calldata optParams) external;
    function reject(uint256 jobId, bytes32 reason, bytes calldata optParams) external;
}
