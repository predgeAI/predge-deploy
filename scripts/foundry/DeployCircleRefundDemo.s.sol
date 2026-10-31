// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PredgeRefundArbiterV2} from "../../contracts/v2/PredgeRefundArbiterV2.sol";
import {CircleRefundProtocolAdapter} from "../../contracts/v2/adapters/CircleRefundProtocolAdapter.sol";
import {MockCircleRefundProtocol} from "../../contracts/v2/mocks/MockCircleRefundProtocol.sol";

/// @notice Demo deploy for Arc TESTNET: adapter -> Refund Protocol -> PredgeRefundArbiterV2 -> bind.
///         Simulate first (no --broadcast). Env:
///           OWNER, OPERATOR       required; Predge arbiter owner (Safe or EOA) and operator key
///           USDC                  ERC-20 the Refund Protocol escrows (Arc testnet USDC by default)
///           CIRCLE_RP             optional: an existing Circle RefundProtocol whose `arbiter` is the
///                                 adapter address this script will create. If unset, Predge's own
///                                 MockCircleRefundProtocol is deployed instead.
///           AMOUNT_SCALE          default 1e12 (USDC 6dp -> Arc native 18dp)
///           WINDOW, MIN_BOND, BPS default 86400, 5e18, 0 (the live Arc v2.1 config)
contract DeployCircleRefundDemo is Script {
    function run() external {
        address owner = vm.envAddress("OWNER");
        address operator = vm.envAddress("OPERATOR");
        address usdc = vm.envOr("USDC", address(0x3600000000000000000000000000000000000000));
        address circleRp = vm.envOr("CIRCLE_RP", address(0));
        uint256 scale = vm.envOr("AMOUNT_SCALE", uint256(1e12));
        uint64 window = uint64(vm.envOr("WINDOW", uint256(86400)));
        uint256 minBond = vm.envOr("MIN_BOND", uint256(5e18));
        uint16 bps = uint16(vm.envOr("BPS", uint256(0)));

        vm.startBroadcast();
        CircleRefundProtocolAdapter adapter = new CircleRefundProtocolAdapter(scale);
        if (circleRp == address(0)) {
            circleRp = address(new MockCircleRefundProtocol(address(adapter), usdc));
        }
        PredgeRefundArbiterV2 arb = new PredgeRefundArbiterV2(owner, operator, address(adapter), window, minBond, bps);
        adapter.bind(circleRp, address(arb));
        vm.stopBroadcast();

        console2.log("adapter        ", address(adapter));
        console2.log("refundProtocol ", circleRp);
        console2.log("predgeArbiter  ", address(arb));
        console2.log("next: OWNER calls predgeArbiter.setLockupSeconds(seller, >15 days, <=180 days)");
    }
}
