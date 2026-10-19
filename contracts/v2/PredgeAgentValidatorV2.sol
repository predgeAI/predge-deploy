// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Operated} from "./access/PredgeAccess.sol";

/// @notice The one ERC-721 call the registry needs from an ERC-8004 Identity Registry.
interface IIdentityOwner {
    function ownerOf(uint256 agentId) external view returns (address);
}

/// @title  PredgeAgentValidatorV2
/// @notice An ERC-8004 Validation Registry shaped log of validation requests and verdicts, with
///         one property enforced by the chain: a request is timestamped BEFORE its response, and a
///         response is written once and never changes.
///
///         What this contract does NOT do, so nobody reads more into it than is there:
///           * It does not verify the ed25519 attestation. The operator verifies it off-chain and
///             commits `responseHash`, the keccak256 of the signed bytes.
///           * It is not linked to `PredgeValidatorBondV2`. A registry response is a statement; the
///             bonded, slashable verdict is the bond's `Scored` event and the job it settled.
///             Consumers that want the bonded one must read the bond.
///
///         Authorisation (fixes the v1 permissionless `validationRequest`): a request may be made
///         by the operator, or, when an Identity Registry address was set at construction, by the
///         current owner of the agent NFT. With no identity registry only the operator may
///         request.
///
///         Domain separation: the caller supplies an acceptance-test DIGEST and the registry
///         derives `requestHash = keccak256(abi.encode(block.chainid, address(this), digest))`.
///         The same digest therefore yields a different request on every chain and registry, so a
///         request or verdict cannot be replayed across deployments. This is the one deviation from
///         the ERC-8004 reference signature: the fourth argument is the digest, and the derived
///         hash is returned and emitted in the canonical event position. Use `requestHashFor` to
///         compute it off-chain, and use that value as the `AgentJobV2.specHash`.
///
/// @dev    Roles: `owner` (Safe) rotates the operator; `operator` (hot key) answers requests.
///         Rotating the operator never rewrites a past verdict.
contract PredgeAgentValidatorV2 is Operated {
    struct Validation {
        address validator; // the operator that was current when the request was made
        uint256 agentId;
        bytes32 responseHash;
        uint64 requestedAt;
        uint64 respondedAt; // 0 while pending
        uint8 response; // 0-100
        bool hasResponse;
        string tag;
    }

    /// @notice Optional ERC-8004 Identity Registry (the agent NFT). Zero = only the operator requests.
    address public immutable identityRegistry;

    uint64 public requestCount;
    uint64 public responseCount;

    /// @dev `getSummary` is O(n^2) in the number of hashes (it dedupes); cap the input.
    uint256 public constant MAX_SUMMARY = 100;

    mapping(bytes32 => Validation) private _v;
    mapping(bytes32 => string) public requestURIOf;
    mapping(bytes32 => string) public responseURIOf;

    event ValidationRequest(address indexed validatorAddress, uint256 indexed agentId, string requestURI, bytes32 indexed requestHash);
    event ValidationResponse(
        address indexed validatorAddress,
        uint256 indexed agentId,
        bytes32 indexed requestHash,
        uint8 response,
        string responseURI,
        bytes32 responseHash,
        string tag
    );
    /// @notice Extra context the canonical events lack: who asked, and the digest behind the hash.
    event RequestRecorded(bytes32 indexed requestHash, bytes32 digest, address indexed requester);
    /// @notice Extra context the canonical event lacks: who answered, and when.
    event ResponseRecorded(bytes32 indexed requestHash, address indexed responder, uint64 respondedAt);

    error NotAuthorized();
    error WrongValidator();
    error ZeroHash();
    error AlreadyRequested();
    error NotRequested();
    error AlreadyResponded();
    error BadScore();
    error TooManyHashes();

    /// @param owner_            the Safe
    /// @param operator_         the hot key that answers requests
    /// @param identityRegistry_ optional ERC-8004 Identity Registry; zero disables agent-owner requests
    constructor(address owner_, address operator_, address identityRegistry_) Operated(owner_, operator_) {
        identityRegistry = identityRegistry_;
    }

    /// @notice The request hash this registry derives for an acceptance-test digest.
    function requestHashFor(bytes32 digest) public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), digest));
    }

    /// @notice Record a validation request before the outcome is knowable.
    /// @param validatorAddress must equal the current `operator` (kept for ERC-8004 compatibility)
    /// @param agentId          the agent under validation (the NFT id when an identity registry is set)
    /// @param requestURI       pointer to the signed acceptance test
    /// @param digest           keccak256 of the signed acceptance-test bytes; must be non-zero
    /// @return requestHash     the domain-separated hash under which the request is stored
    function validationRequest(address validatorAddress, uint256 agentId, string calldata requestURI, bytes32 digest)
        external
        returns (bytes32 requestHash)
    {
        if (digest == bytes32(0)) revert ZeroHash();
        if (msg.sender != operator && !_isAgentOwner(agentId)) revert NotAuthorized();
        if (validatorAddress != operator) revert WrongValidator();
        requestHash = requestHashFor(digest);
        Validation storage v = _v[requestHash];
        if (v.requestedAt != 0) revert AlreadyRequested();

        v.validator = validatorAddress;
        v.agentId = agentId;
        v.requestedAt = uint64(block.timestamp);
        requestURIOf[requestHash] = requestURI;
        requestCount += 1;

        emit ValidationRequest(validatorAddress, agentId, requestURI, requestHash);
        emit RequestRecorded(requestHash, digest, msg.sender);
    }

    /// @notice Record the verdict, once, for a request that exists. Operator only.
    /// @param response 0-100 (Predge: 100 delivered, 0 failed, 50 void)
    function validationResponse(
        bytes32 requestHash,
        uint8 response,
        string calldata responseURI,
        bytes32 responseHash,
        string calldata tag
    ) external onlyOperator {
        if (response > 100) revert BadScore();
        if (responseHash == bytes32(0)) revert ZeroHash();
        Validation storage v = _v[requestHash];
        if (v.requestedAt == 0) revert NotRequested();
        if (v.hasResponse) revert AlreadyResponded();

        v.response = response;
        v.responseHash = responseHash;
        v.respondedAt = uint64(block.timestamp);
        v.hasResponse = true;
        v.tag = tag;
        responseURIOf[requestHash] = responseURI;
        responseCount += 1;

        emit ValidationResponse(v.validator, v.agentId, requestHash, response, responseURI, responseHash, tag);
        emit ResponseRecorded(requestHash, msg.sender, uint64(block.timestamp));
    }

    /// @notice ERC-8004 `getValidationStatus`.
    function getValidationStatus(bytes32 requestHash)
        external
        view
        returns (address validatorAddress, uint256 agentId, uint8 response, bytes32 responseHash, string memory tag, uint256 lastUpdate)
    {
        Validation storage v = _v[requestHash];
        return (v.validator, v.agentId, v.response, v.responseHash, v.tag, v.respondedAt != 0 ? v.respondedAt : v.requestedAt);
    }

    /// @notice True once a verdict is permanently recorded.
    function isValidated(bytes32 requestHash) external view returns (bool) {
        return _v[requestHash].hasResponse;
    }

    /// @notice Seconds the request stayed committed before its verdict; 0 while pending.
    function commitLeadTime(bytes32 requestHash) external view returns (uint64) {
        Validation storage v = _v[requestHash];
        if (!v.hasResponse) return 0;
        return v.respondedAt - v.requestedAt;
    }

    /// @notice ERC-8004 `getSummary` for one agent over the supplied hashes. A hash that appears
    ///         more than once is counted once.
    function getSummary(uint256 agentId, bytes32[] calldata requestHashes)
        external
        view
        returns (uint64 count, uint8 averageResponse)
    {
        uint256 n = requestHashes.length;
        if (n > MAX_SUMMARY) revert TooManyHashes();
        uint256 sum;
        for (uint256 i = 0; i < n; i++) {
            bool seen;
            for (uint256 k = 0; k < i; k++) {
                if (requestHashes[k] == requestHashes[i]) {
                    seen = true;
                    break;
                }
            }
            if (seen) continue;
            Validation storage v = _v[requestHashes[i]];
            if (v.hasResponse && v.agentId == agentId) {
                sum += v.response;
                count += 1;
            }
        }
        averageResponse = count == 0 ? 0 : uint8(sum / count);
    }

    function _isAgentOwner(uint256 agentId) private view returns (bool) {
        if (identityRegistry == address(0)) return false;
        try IIdentityOwner(identityRegistry).ownerOf(agentId) returns (address o) {
            return o == msg.sender;
        } catch {
            return false;
        }
    }
}
