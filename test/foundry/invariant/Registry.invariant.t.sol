// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PredgeAgentValidator} from "../../../contracts/PredgeAgentValidator.sol";
import {PredgeSettlement} from "../../../contracts/PredgeSettlement.sol";

contract RegistryHandler is Test {
    PredgeAgentValidator public reg;
    PredgeSettlement public settle;
    address public val;
    address public owner;
    bytes32[] public hashes;
    mapping(bytes32 => uint8) public firstScore;
    mapping(bytes32 => bytes32) public firstHash;
    uint256 public responses;
    uint256 public paid;
    uint256 public withdrawn;

    constructor(PredgeAgentValidator r, PredgeSettlement s, address v, address o) {
        reg = r;
        settle = s;
        val = v;
        owner = o;
    }

    function hashCount() external view returns (uint256) {
        return hashes.length;
    }

    function request(uint8 hSeed, uint256 agentId) external {
        bytes32 h = keccak256(abi.encode(hSeed % 16));
        try reg.validationRequest(val, agentId, "u", h) {
            hashes.push(h);
        } catch {}
    }

    function respond(uint8 hSeed, uint8 score, bytes32 rh) external {
        bytes32 h = keccak256(abi.encode(hSeed % 16));
        score = uint8(bound(score, 0, 100));
        if (rh == bytes32(0)) rh = bytes32(uint256(1));
        vm.warp(block.timestamp + 1);
        vm.prank(val);
        try reg.validationResponse(h, score, "r", rh, "t") {
            firstScore[h] = score;
            firstHash[h] = rh;
            responses++;
        } catch {}
    }

    function pay(uint96 amt, bool direct) external {
        amt = uint96(bound(amt, 1, 10 ether));
        vm.deal(address(this), amt);
        if (direct) {
            (bool ok, ) = address(settle).call{value: amt}("");
            require(ok);
        } else {
            settle.payForRoute{value: amt}(bytes32("r"), "");
        }
        paid += amt;
    }

    function withdraw() external {
        uint256 b = address(settle).balance;
        vm.prank(owner);
        settle.withdraw(payable(address(0xFEE)));
        withdrawn += b;
    }
}

contract RegistryInvariantTest is Test {
    PredgeAgentValidator reg;
    PredgeSettlement settle;
    RegistryHandler h;
    address val = address(0x7A1);
    address owner = address(0x0A);

    function setUp() public {
        vm.warp(1_700_000_000);
        vm.startPrank(owner);
        reg = new PredgeAgentValidator(val);
        settle = new PredgeSettlement();
        vm.stopPrank();
        h = new RegistryHandler(reg, settle, val, owner);
        targetContract(address(h));
    }

    /// A written verdict never changes.
    function invariant_verdictsAreWriteOnce() public view {
        for (uint256 i; i < h.hashCount(); i++) {
            bytes32 x = h.hashes(i);
            if (!reg.isValidated(x)) continue;
            (, , uint8 r, bytes32 rh, , ) = reg.getValidationStatus(x);
            assertEq(r, h.firstScore(x));
            assertEq(rh, h.firstHash(x));
            assertGt(reg.commitLeadTime(x), 0);
        }
    }

    function invariant_responsesNeverExceedRequests() public view {
        assertLe(reg.responseCount(), reg.requestCount());
        assertEq(reg.responseCount(), h.responses());
        assertEq(reg.requestCount(), h.hashCount());
    }

    function invariant_settlementBalance() public view {
        assertEq(address(settle).balance, h.paid() - h.withdrawn());
    }
}
