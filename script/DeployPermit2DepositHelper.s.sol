// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { Permit2DepositHelper } from "@multyr-periphery/periphery/Permit2DepositHelper.sol";

/// @title DeployPermit2DepositHelper -- Permit2 deposit integration standalone deploy
/// @notice Deploys Permit2DepositHelper, enabling gas-less deposit UX via EIP-2612 signatures.
///         Standalone periphery canonical script. Previously bundled in DeployCoreIntegrated (core Phase 4).
///         Safe to redeploy: Permit2DepositHelper is stateless (immutables only).
/// @dev Constructor: (permit2, vault, asset). Verifies vault.asset() == asset at deploy time.
///      No owner, no roles -- permissionless, immutable after deploy.
/// @custom:chain-id 42161 (Arbitrum One -- enforced at runtime)
/// @custom:env-vars DEPLOYER_PRIVATE_KEY, VAULT_ADDRESS,
///                  USDC_ADDRESS (opt, default: 0xaf88d065e77c8cC2239327C5EDb3A432268e5831)
/// @custom:post-deploy No wiring required. Permit2DepositHelper is self-contained.
///                     Frontend/SDK: set permit2Helper address in deposit flow.
contract DeployPermit2DepositHelper is Script {

    uint256 constant ARBITRUM_ONE_CHAIN_ID = 42161;

    // Canonical Arbitrum addresses
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant USDC_ARBITRUM = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    function run() external returns (Permit2DepositHelper helper) {
        require(
            block.chainid == ARBITRUM_ONE_CHAIN_ID,
            "WRONG_CHAIN: DeployPermit2DepositHelper is Arbitrum-only (chainId 42161)"
        );

        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer   = vm.addr(deployerPk);
        address vault      = vm.envAddress("VAULT_ADDRESS");
        address usdc       = vm.envOr("USDC_ADDRESS", USDC_ARBITRUM);

        require(vault != address(0), "VAULT_ADDRESS required");
        require(usdc  != address(0), "USDC_ADDRESS required");

        console.log("================================================================");
        console.log("   DEPLOY PERMIT2 DEPOSIT HELPER");
        console.log("================================================================");
        console.log("Deployer: ", deployer);
        console.log("Vault:    ", vault);
        console.log("USDC:     ", usdc);
        console.log("Permit2:  ", PERMIT2);
        console.log("================================================================");

        vm.startBroadcast(deployerPk);

        // Constructor: (permit2_, vault_, asset_)
        // Verifies vault.asset() == usdc at deploy time (reverts on mismatch)
        helper = new Permit2DepositHelper(PERMIT2, vault, usdc);

        vm.stopBroadcast();

        console.log("Permit2DepositHelper deployed:", address(helper));
        console.log("");
        console.log("No wiring required. Update frontend/SDK permit2Helper address.");
    }
}
