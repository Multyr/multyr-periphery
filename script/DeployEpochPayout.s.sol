// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { EpochPayout } from "@multyr-periphery/periphery/rewards/EpochPayout.sol";

/// @title DeployEpochPayout -- EpochPayout standalone redeploy (incident response / upgrade)
/// @notice Deploys a new EpochPayout (Merkle-based epoch distributor) for USDC rewards.
///         Use for incident response when EpochPayout must be replaced without redeploying
///         the full Phase 8 bundle.
///         Replaces RedeployEpochPayout legacy script.
/// @dev EpochPayout is Ownable2Step. Deployer is initial owner.
///      After deploy: FeeDistributorV2.setEpochPayout(<newEpochPayout>) required via governance.
///      All existing epoch Merkle roots are lost on redeploy -- notify off-chain indexer.
/// @custom:chain-id 42161 (Arbitrum One -- enforced at runtime)
/// @custom:env-vars DEPLOYER_PRIVATE_KEY,
///                  USDC_ADDRESS (opt, default: 0xaf88d065e77c8cC2239327C5EDb3A432268e5831),
///                  TIMELOCK_ADDRESS (opt -- if set, ownership transferred to timelock at deploy)
/// @custom:post-deploy 1) Governance: FeeDistributorV2.setEpochPayout(<newEpochPayout>)
///                     2) Transfer ownership: EpochPayout.transferOwnership(timelock)
///                        (or set TIMELOCK_ADDRESS env var for atomic transfer at deploy)
///                     3) Notify off-chain indexer of new EpochPayout address
/// @custom:replaces RedeployEpochPayout legacy script (archived)
contract DeployEpochPayout is Script {

    uint256 constant ARBITRUM_ONE_CHAIN_ID = 42161;

    // Canonical Arbitrum USDC
    address constant USDC_ARBITRUM = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    function run() external returns (EpochPayout epochPayout) {
        require(
            block.chainid == ARBITRUM_ONE_CHAIN_ID,
            "WRONG_CHAIN: DeployEpochPayout is Arbitrum-only (chainId 42161)"
        );

        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer   = vm.addr(deployerPk);
        address usdc       = vm.envOr("USDC_ADDRESS", USDC_ARBITRUM);
        address timelock   = vm.envOr("TIMELOCK_ADDRESS", address(0));

        require(usdc != address(0), "USDC_ADDRESS required");

        console.log("================================================================");
        console.log("   DEPLOY EPOCH PAYOUT (standalone -- incident response)");
        console.log("================================================================");
        console.log("Deployer:  ", deployer);
        console.log("USDC:      ", usdc);
        if (timelock != address(0)) {
            console.log("Timelock:  ", timelock);
            console.log("           Ownership will be transferred to timelock at deploy.");
        } else {
            console.log("Timelock:  not set -- transfer ownership manually post-deploy");
        }
        console.log("================================================================");

        vm.startBroadcast(deployerPk);

        // constructor(address payoutToken_) Ownable()
        epochPayout = new EpochPayout(usdc);
        console.log("EpochPayout deployed:", address(epochPayout));

        if (timelock != address(0)) {
            epochPayout.transferOwnership(timelock);
            console.log("  Ownership transferred to timelock:", timelock);
        }

        vm.stopBroadcast();

        console.log("");
        console.log("NEXT STEPS:");
        console.log("  1. Governance: FeeDistributorV2.setEpochPayout(", address(epochPayout), ")");
        if (timelock == address(0)) {
            console.log("  2. EpochPayout.transferOwnership(<timelock>)");
        }
        console.log("  3. Notify off-chain indexer of new EpochPayout address");
    }
}
