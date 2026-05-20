// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { PeripheryUpkeepAdapterV2 } from
    "@multyr-periphery/periphery/automation/PeripheryUpkeepAdapterV2.sol";

/// @title DeployPeripheryUpkeepAdapter -- Phase 10 Chainlink Automation adapter deploy
/// @notice Deploys PeripheryUpkeepAdapterV2, the shared multi-vault automation keeper for the
///         fee pipeline: OpsCollectorV2.splitAll() -> FeeDistributorV2.fundEpochPayout().
///         Permissionless, stateless (immutables only), no owner or roles.
///         Run after DeployPeripheryRewards (Phase 8 + 9.5 must be complete first).
/// @dev Constructor: (opsCollector_, feeDistributor_)
///      Pipeline priority: SPLIT > FUND (deterministic, re-checks state before executing).
///      No state to migrate on redeploy -- safe to replace at any time.
/// @custom:chain-id 42161 (Arbitrum One -- enforced at runtime)
/// @custom:env-vars DEPLOYER_PRIVATE_KEY, OPS_COLLECTOR_ADDRESS, FEE_DISTRIBUTOR_ADDRESS
/// @custom:post-deploy 1) Register PeripheryUpkeepAdapterV2 on Chainlink Automation Network
///                     2) Fund upkeep with LINK
///                     3) Verify: cast call <adapter> "checkUpkeep(bytes)(bool,bytes)" 0x
contract DeployPeripheryUpkeepAdapter is Script {

    uint256 constant ARBITRUM_ONE_CHAIN_ID = 42161;

    function run() external returns (PeripheryUpkeepAdapterV2 adapter) {
        require(
            block.chainid == ARBITRUM_ONE_CHAIN_ID,
            "WRONG_CHAIN: DeployPeripheryUpkeepAdapter is Arbitrum-only (chainId 42161)"
        );

        uint256 deployerPk     = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer       = vm.addr(deployerPk);
        address opsCollector   = vm.envAddress("OPS_COLLECTOR_ADDRESS");
        address feeDistributor = vm.envAddress("FEE_DISTRIBUTOR_ADDRESS");

        require(opsCollector   != address(0), "OPS_COLLECTOR_ADDRESS required");
        require(feeDistributor != address(0), "FEE_DISTRIBUTOR_ADDRESS required");

        console.log("================================================================");
        console.log("   DEPLOY PERIPHERY UPKEEP ADAPTER V2 (Phase 10)");
        console.log("================================================================");
        console.log("Deployer:       ", deployer);
        console.log("OpsCollectorV2: ", opsCollector);
        console.log("FeeDistributorV2:", feeDistributor);
        console.log("================================================================");

        vm.startBroadcast(deployerPk);

        // constructor(address opsCollector_, address feeDistributor_)
        // Permissionless -- no owner, no roles
        adapter = new PeripheryUpkeepAdapterV2(opsCollector, feeDistributor);

        vm.stopBroadcast();

        console.log("PeripheryUpkeepAdapterV2 deployed:", address(adapter));
        console.log("");
        console.log("NEXT STEPS:");
        console.log("  1. Register on Chainlink Automation Network");
        console.log("  2. Fund upkeep with LINK");
        console.log("  3. Verify: cast call", address(adapter), "\"checkUpkeep(bytes)(bool,bytes)\" 0x");
    }
}
