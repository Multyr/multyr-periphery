// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { ReferralBinding }       from "@multyr-periphery/periphery/referral/ReferralBinding.sol";
import { PartnerRegistry }       from "@multyr-periphery/periphery/partner/PartnerRegistry.sol";
import { EpochPayout }           from "@multyr-periphery/periphery/rewards/EpochPayout.sol";
import { FeeDistributorV2 }      from "@multyr-periphery/periphery/rewards/FeeDistributorV2.sol";
import { OpsCollectorV2 }        from "@multyr-periphery/periphery/ops/OpsCollectorV2.sol";
import { DepositRouter }         from "@multyr-periphery/periphery/router/DepositRouter.sol";

/// @title DeployPeripheryRewards -- Phase 8 periphery rewards bundle (6 contracts)
/// @notice Deploys all Phase 8 periphery contracts in strict dependency order:
///         1. ReferralBinding  (immutable governance = timelock)
///         2. PartnerRegistry  (deployer owner -- transfer in Phase 9.5)
///         3. EpochPayout      (payoutToken = USDC, deployer owner)
///         4. FeeDistributorV2 (asset=USDC, epochPayout, maxFundPerEpoch, minDelay, initialEpochId)
///         5. OpsCollectorV2   (underlying=USDC, opsWallet, feeDistributor, opsBps)
///         6. DepositRouter    (vault, USDC, permit2, referralBinding)
///         Replaces legacy DeployPeriphery.s.sol. Ownership transfers happen in Phase 9.5 (NOT here).
/// @dev All Ownable2Step contracts deploy with deployer as initial owner.
///      Phase 9.5 governance actions (timelock proposals) required post-deploy.
///      OpsCollectorV2: vault share tokens added via addVault() in Phase 9.5 (not in constructor).
///      FeeDistributorV2: vault-agnostic, serves all vaults via OpsCollectorV2 pipeline.
/// @custom:chain-id 42161 (Arbitrum One -- enforced at runtime)
/// @custom:env-vars DEPLOYER_PRIVATE_KEY, VAULT_ADDRESS, TIMELOCK_ADDRESS, OPS_WALLET_ADDRESS,
///                  PERMIT2_ADDRESS (opt, default: 0x000000000022D473030F116dDEE9F6B43aC78BA3),
///                  USDC_ADDRESS (opt, default: 0xaf88d065e77c8cC2239327C5EDb3A432268e5831),
///                  OPS_BPS (opt, default 5000 = 50%), MAX_FUND_PER_EPOCH (opt, default 50000e6),
///                  MIN_DELAY_BETWEEN_FUNDS (opt, default 86400 = 1 day),
///                  INITIAL_EPOCH_ID (opt, default 1)
/// @custom:post-deploy Phase 9.5 governance actions (via timelock):
///                     1) OpsCollectorV2.transferOwnership(timelock)  -- Ownable2Step: proposer
///                     2) FeeDistributorV2.transferOwnership(timelock) -- Ownable2Step: proposer
///                     3) EpochPayout.transferOwnership(timelock)     -- Ownable2Step: proposer
///                     4) PartnerRegistry.transferOwnership(timelock) -- Ownable2Step: proposer
///                     5) Timelock: ReferralBinding.setRouter(depositRouter, true)
///                     6) Governance proposal: FeeCollector.setParams(treasury, opsCollector, safetyReserve, treasuryBps, safetyBps)
///                     7) OpsCollectorV2.addVault(coreVault) -- registers vault share token
///                     Phase 10: Deploy PeripheryUpkeepAdapterV2 (separate script)
/// @custom:replaces script/DeployPeriphery.s.sol (legacy monorepo path -- archived post-01b)
contract DeployPeripheryRewards is Script {

    uint256 constant ARBITRUM_ONE_CHAIN_ID = 42161;

    // Canonical Arbitrum addresses
    address constant PERMIT2_DEFAULT      = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant USDC_ARBITRUM        = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    // Defaults
    uint16  constant DEFAULT_OPS_BPS              = 5000;  // 50% ops, 50% growth
    uint256 constant DEFAULT_MAX_FUND_PER_EPOCH   = 50_000e6; // 50k USDC
    uint256 constant DEFAULT_MIN_DELAY            = 86400; // 1 day
    uint32  constant DEFAULT_INITIAL_EPOCH_ID     = 1;

    struct PeripheryRewardsResult {
        ReferralBinding    referralBinding;
        PartnerRegistry    partnerRegistry;
        EpochPayout        epochPayout;
        FeeDistributorV2   feeDistributor;
        OpsCollectorV2     opsCollector;
        DepositRouter      depositRouter;
    }

    function run() external returns (PeripheryRewardsResult memory result) {
        require(
            block.chainid == ARBITRUM_ONE_CHAIN_ID,
            "WRONG_CHAIN: DeployPeripheryRewards is Arbitrum-only (chainId 42161)"
        );

        uint256 deployerPk  = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer    = vm.addr(deployerPk);
        address vault       = vm.envAddress("VAULT_ADDRESS");
        address timelock    = vm.envAddress("TIMELOCK_ADDRESS");
        address opsWallet   = vm.envAddress("OPS_WALLET_ADDRESS");
        address permit2     = vm.envOr("PERMIT2_ADDRESS",   PERMIT2_DEFAULT);
        address usdc        = vm.envOr("USDC_ADDRESS",      USDC_ARBITRUM);
        uint16  opsBps      = uint16(vm.envOr("OPS_BPS",            uint256(DEFAULT_OPS_BPS)));
        uint256 maxFund     = vm.envOr("MAX_FUND_PER_EPOCH",        DEFAULT_MAX_FUND_PER_EPOCH);
        uint256 minDelay    = vm.envOr("MIN_DELAY_BETWEEN_FUNDS",   DEFAULT_MIN_DELAY);
        uint32  initialEpoch = uint32(vm.envOr("INITIAL_EPOCH_ID", uint256(DEFAULT_INITIAL_EPOCH_ID)));

        require(vault     != address(0), "VAULT_ADDRESS required");
        require(timelock  != address(0), "TIMELOCK_ADDRESS required");
        require(opsWallet != address(0), "OPS_WALLET_ADDRESS required");

        console.log("================================================================");
        console.log("   DEPLOY PERIPHERY REWARDS (Phase 8 bundle -- 6 contracts)");
        console.log("================================================================");
        console.log("Deployer:   ", deployer);
        console.log("Vault:      ", vault);
        console.log("Timelock:   ", timelock);
        console.log("OpsWallet:  ", opsWallet);
        console.log("USDC:       ", usdc);
        console.log("Permit2:    ", permit2);
        console.log("OpsBps:     ", opsBps);
        console.log("MaxFund:    ", maxFund);
        console.log("MinDelay:   ", minDelay);
        console.log("InitEpoch:  ", initialEpoch);
        console.log("================================================================");

        vm.startBroadcast(deployerPk);

        // ----------------------------------------------------------------
        // 1. ReferralBinding -- immutable governance = timelock
        //    constructor(address governance_)
        // ----------------------------------------------------------------
        result.referralBinding = new ReferralBinding(timelock);
        console.log("[1] ReferralBinding:  ", address(result.referralBinding));

        // ----------------------------------------------------------------
        // 2. PartnerRegistry -- no-arg constructor, deployer = initial owner
        //    constructor() Ownable()
        // ----------------------------------------------------------------
        result.partnerRegistry = new PartnerRegistry();
        console.log("[2] PartnerRegistry:  ", address(result.partnerRegistry));

        // ----------------------------------------------------------------
        // 3. EpochPayout -- payoutToken = USDC, deployer = initial owner
        //    constructor(address payoutToken_) Ownable()
        // ----------------------------------------------------------------
        result.epochPayout = new EpochPayout(usdc);
        console.log("[3] EpochPayout:      ", address(result.epochPayout));

        // ----------------------------------------------------------------
        // 4. FeeDistributorV2 -- vault-agnostic, first arg = asset (USDC)
        //    constructor(address asset_, address epochPayout_,
        //                uint256 maxFundPerEpoch_, uint256 minDelayBetweenFunds_,
        //                uint32 initialEpochId_) Ownable()
        // ----------------------------------------------------------------
        result.feeDistributor = new FeeDistributorV2(
            usdc,
            address(result.epochPayout),
            maxFund,
            minDelay,
            initialEpoch
        );
        console.log("[4] FeeDistributorV2: ", address(result.feeDistributor));

        // ----------------------------------------------------------------
        // 5. OpsCollectorV2 -- first arg = underlying asset (USDC)
        //    constructor(address underlying_, address opsWallet_,
        //                address feeDistributor_, uint16 opsBps_) Ownable()
        //    NOTE: vault share tokens added via addVault() in Phase 9.5
        // ----------------------------------------------------------------
        result.opsCollector = new OpsCollectorV2(
            usdc,
            opsWallet,
            address(result.feeDistributor),
            opsBps
        );
        console.log("[5] OpsCollectorV2:   ", address(result.opsCollector));

        // ----------------------------------------------------------------
        // 6. DepositRouter -- wires vault + asset + permit2 + referralBinding
        //    constructor(address vault_, address asset_, address permit2_,
        //                address referralBinding_)
        // ----------------------------------------------------------------
        result.depositRouter = new DepositRouter(
            vault,
            usdc,
            permit2,
            address(result.referralBinding)
        );
        console.log("[6] DepositRouter:    ", address(result.depositRouter));

        vm.stopBroadcast();

        console.log("");
        console.log("================================================================");
        console.log("PHASE 9.5 ACTIONS REQUIRED (via timelock/governance):");
        console.log("  1) OpsCollectorV2.transferOwnership(timelock)");
        console.log("  2) FeeDistributorV2.transferOwnership(timelock)");
        console.log("  3) EpochPayout.transferOwnership(timelock)");
        console.log("  4) PartnerRegistry.transferOwnership(timelock)");
        console.log("  5) ReferralBinding.setRouter(depositRouter=", address(result.depositRouter), ", true)");
        console.log("  6) FeeCollector.setParams(..., opsCollector=", address(result.opsCollector), ", ...)");
        console.log("  7) OpsCollectorV2.addVault(vault=", vault, ")");
        console.log("PHASE 10: Deploy PeripheryUpkeepAdapterV2 (DeployPeripheryUpkeepAdapter.s.sol)");
        console.log("================================================================");
    }
}
