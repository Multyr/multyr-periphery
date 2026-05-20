// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { FeeCollectorUpkeep } from "@multyr-periphery/periphery/automation/FeeCollectorUpkeep.sol";

/// @title DeployFeeCollectorUpkeep -- FeeCollectorUpkeep standalone deploy (Chainlink Automation)
/// @notice Deploys FeeCollectorUpkeep, registers the vault share token, and transfers ownership
///         to the timelock in a single atomic broadcast.
///         Replaces legacy monorepo script/DeployFeeCollectorUpkeep.s.sol.
/// @dev CRITICAL (v9 mainnet incident 2026-04-06): addToken(vault) MUST be called BEFORE
///      transferOwnership(timelock). If ownership is transferred first, addToken requires a
///      timelock proposal to execute -- fees will not distribute until the next governance cycle.
///      This script enforces the correct order atomically.
/// @custom:chain-id 42161 (Arbitrum One -- enforced at runtime)
/// @custom:env-vars FEE_COLLECTOR_ADDRESS, VAULT_ADDRESS, DISTRIBUTE_INTERVAL (259200 = 3 days),
///                  TIMELOCK_ADDRESS
/// @custom:post-deploy 1) Register FeeCollectorUpkeep on Chainlink Automation Network
///                     2) Verify: cast call <upkeep> "checkUpkeep(bytes)(bool,bytes)" 0x
/// @custom:replaces script/DeployFeeCollectorUpkeep.s.sol (legacy monorepo path)
contract DeployFeeCollectorUpkeep is Script {

    uint256 constant ARBITRUM_ONE_CHAIN_ID = 42161;

    function run() external {
        require(
            block.chainid == ARBITRUM_ONE_CHAIN_ID,
            "WRONG_CHAIN: DeployFeeCollectorUpkeep is Arbitrum-only (chainId 42161)"
        );
        address feeCollector = vm.envAddress("FEE_COLLECTOR_ADDRESS");
        address vault = vm.envAddress("VAULT_ADDRESS");
        uint64 interval = uint64(vm.envUint("DISTRIBUTE_INTERVAL"));
        address timelock = vm.envAddress("TIMELOCK_ADDRESS");

        console.log("");
        console.log("================================================================");
        console.log("   DEPLOY FEE COLLECTOR UPKEEP");
        console.log("================================================================");
        console.log("");
        console.log("FeeCollector:", feeCollector);
        console.log("Vault (share token):", vault);
        console.log("Interval (seconds):", interval);
        console.log("Timelock (owner):", timelock);
        console.log("");

        vm.startBroadcast();

        // 1. Deploy FeeCollectorUpkeep (deployer is initial owner)
        FeeCollectorUpkeep upkeep =
            new FeeCollectorUpkeep(feeCollector, address(0), interval);
        console.log("FeeCollectorUpkeep deployed:", address(upkeep));

        // 2. Register vault as token to distribute
        upkeep.addToken(vault);
        console.log("  Token added:", vault);

        // 3. Transfer ownership to timelock
        upkeep.transferOwnership(timelock);
        console.log("  Ownership transferred to:", timelock);

        vm.stopBroadcast();

        console.log("");
        console.log("================================================================");
        console.log("  DONE - Register on Chainlink Automation");
        console.log("================================================================");
        console.log("");
        console.log("Next steps:");
        console.log("  1. Register FeeCollectorUpkeep on Chainlink Automation");
        console.log("  2. Verify: cast call", address(upkeep), "\"checkUpkeep(bytes)(bool,bytes)\" 0x");
        console.log("");
    }
}
