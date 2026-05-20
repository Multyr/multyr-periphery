// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script, console2 } from "forge-std/Script.sol";
import { IncentivesEngine } from "@multyr-core/core/modules/IncentivesEngine.sol";
import { IIncentivesEngine } from "@multyr-core/interfaces/IIncentivesEngine.sol";
import { IRewardsPayoutManager } from "@multyr-core/interfaces/IRewardsPayoutManager.sol";
import { RewardsPayoutManager } from "@multyr-periphery/periphery/rewards/RewardsPayoutManager.sol";

/// @title DeployIncentivesEngine -- IncentivesEngine + RewardsPayoutManager standalone deploy
/// @notice Deploys the tranche-based incentives system and wires it to CoreVault.
///         Replaces legacy monorepo script/DeployIncentivesEngine.s.sol.
///         Idempotent: safe to redeploy (wiring via timelock post-deploy).
/// @dev IncentivesEngine (core module) + RewardsPayoutManager (periphery rewards).
///      Governance transferred to timelock at end of deploy (deployer is initial governance).
/// @custom:chain-id 42161 (Arbitrum One -- enforced at runtime)
/// @custom:env-vars CORE_VAULT, TIMELOCK, TREASURY, USDC, DEPLOYER_PK
/// @custom:post-deploy 1) Timelock: AdminModule.setIncentivesEngine(<engine>)
///                     2) Timelock: AdminModule.setRewardsPayoutManager(<payout>)
///                     3) Timelock: RewardsPayoutManager.setSharesMintAuthority(coreVault)
///                     4) Treasury: USDC.approve(<rewardsPayoutManager>, type(uint256).max)
/// @custom:replaces script/DeployIncentivesEngine.s.sol (legacy monorepo path)
contract DeployIncentivesEngine is Script {

    uint256 constant ARBITRUM_ONE_CHAIN_ID = 42161;

    function run() external {
        require(
            block.chainid == ARBITRUM_ONE_CHAIN_ID,
            "WRONG_CHAIN: DeployIncentivesEngine is Arbitrum-only (chainId 42161)"
        );
        // Read env
        address coreVault = vm.envAddress("CORE_VAULT");
        address timelock = vm.envAddress("TIMELOCK");
        address treasury = vm.envAddress("TREASURY");
        address usdc = vm.envAddress("USDC");
        uint256 deployerPk = vm.envUint("DEPLOYER_PK");
        address deployer = vm.addr(deployerPk);

        console2.log("=== Deploy IncentivesEngine + RewardsPayoutManager ===");
        console2.log("CoreVault:", coreVault);
        console2.log("Timelock:", timelock);
        console2.log("Treasury:", treasury);
        console2.log("USDC:", usdc);
        console2.log("Deployer:", deployer);

        vm.startBroadcast(deployerPk);

        // ─────────────────────────────────────────────────────────────
        // Step 1: Deploy IncentivesEngine with default params
        // ─────────────────────────────────────────────────────────────

        IIncentivesEngine.IncentiveParams memory params = IIncentivesEngine.IncentiveParams({
            cliffDays: 30,
            fullDays: 180,
            vestingDays: 180,
            bmaxWad: uint128(3e16), // 3% APY max bonus
            rewardMode: IIncentivesEngine.RewardMode.VaultShares,
            active: true,
            effectiveFrom: uint64(block.timestamp)
        });

        IncentivesEngine engine = new IncentivesEngine(
            coreVault,
            treasury,
            deployer, // deployer as initial governance, transfer to timelock after wiring
            params
        );
        console2.log("IncentivesEngine deployed at:", address(engine));

        // ─────────────────────────────────────────────────────────────
        // Step 2: Deploy RewardsPayoutManager
        // ─────────────────────────────────────────────────────────────

        RewardsPayoutManager payout = new RewardsPayoutManager(
            address(engine),
            usdc,
            deployer, // deployer as initial governance
            treasury
        );
        console2.log("RewardsPayoutManager deployed at:", address(payout));

        // ─────────────────────────────────────────────────────────────
        // Step 3: Wire RewardsPayoutManager to CoreVault
        // ─────────────────────────────────────────────────────────────

        payout.setSharesMintAuthority(coreVault);
        console2.log("RewardsPayoutManager.sharesMintAuthority set to CoreVault");

        // ─────────────────────────────────────────────────────────────
        // Step 4: Transfer governance to timelock
        // ─────────────────────────────────────────────────────────────

        engine.transferGovernance(timelock);
        console2.log("IncentivesEngine governance transferred to timelock");

        payout.transferGovernance(timelock);
        console2.log("RewardsPayoutManager governance transferred to timelock");

        // Validate governance transfer via IRewardsPayoutManager interface
        require(
            IRewardsPayoutManager(address(payout)).governance() == timelock,
            "SANITY: RewardsPayoutManager governance != timelock after transfer"
        );

        vm.stopBroadcast();

        // ─────────────────────────────────────────────────────────────
        // Post-deploy instructions (requires timelock)
        // ─────────────────────────────────────────────────────────────

        console2.log("");
        console2.log("=== POST-DEPLOY (via timelock/Safe) ===");
        console2.log("1. AdminModule.setIncentivesEngine(", address(engine), ")");
        console2.log("2. AdminModule.setRewardsPayoutManager(", address(payout), ")");
        console2.log("3. Treasury: approve RewardsPayoutManager for USDC spending");
        console2.log("   USDC.approve(", address(payout), ", type(uint256).max)");
        console2.log("");
        console2.log("=== ADDRESSES ===");
        console2.log("IncentivesEngine:", address(engine));
        console2.log("RewardsPayoutManager:", address(payout));
    }
}
