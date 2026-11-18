// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PredgeRefundArbiterV2} from "../../contracts/v2/PredgeRefundArbiterV2.sol";
import {PredgeJobEscrow} from "../../contracts/v2/demo/PredgeJobEscrow.sol";

/// @notice DEMO ONLY, UNAUDITED, TESTNET ONLY. Simulates the job escrow deploy (no --broadcast), to read the gas
///         on Arc testnet. The real deploy goes through demo/job-escrow/cli.mjs, which has the network guards.
///         Env: OWNER, OPERATOR required; USDC, WINDOW, MIN_BOND optional.
contract DeployJobEscrowDemo is Script {
    function run() external {
        address owner = vm.envAddress("OWNER");
        address operator = vm.envAddress("OPERATOR");
        address usdc = vm.envOr("USDC", address(0x3600000000000000000000000000000000000000));
        uint64 window = uint64(vm.envOr("WINDOW", uint256(3600)));
        uint256 minBond = vm.envOr("MIN_BOND", uint256(1e18));

        vm.startBroadcast();
        PredgeJobEscrow escrow = new PredgeJobEscrow(usdc);
        PredgeRefundArbiterV2 arb = new PredgeRefundArbiterV2(owner, operator, address(escrow), window, minBond, 0);
        escrow.bind(address(arb));
        vm.stopBroadcast();

        console2.log("escrow ", address(escrow));
        console2.log("arbiter", address(arb));
        console2.log("USDC scale", escrow.amountScale());
    }
}
