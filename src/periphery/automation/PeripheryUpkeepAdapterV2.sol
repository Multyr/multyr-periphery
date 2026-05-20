// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AutomationCompatibleInterface } from "@multyr-core/automation/AutomationCompatibleInterface.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Minimal inline interfaces
// ─────────────────────────────────────────────────────────────────────────────

interface IOpsCollectorV2 {
    function splitAll() external;
    function paused() external view returns (bool);
    function vaults(uint256 index) external view returns (address);
    function getVaults() external view returns (address[] memory);
}

interface IFeeDistributorV2 {
    function fundEpochPayout(uint32 epochId) external;
    function ASSET() external view returns (IERC20);
    function currentEpochId() external view returns (uint32);
    function maxFundPerEpoch() external view returns (uint256);
    function fundedInEpoch(uint32 epochId) external view returns (uint256);
    function minDelayBetweenFunds() external view returns (uint256);
    function lastFundTimestamp() external view returns (uint256);
    function fundingPaused() external view returns (bool);
    function paused() external view returns (bool);
}

/// @dev Operations the adapter can trigger, in priority order.
enum PeripheryOp {
    NONE,
    SPLIT,
    FUND
}

error UnknownOp();

/// @title PeripheryUpkeepAdapterV2
/// @notice Chainlink Automation adapter for the multi-vault fee pipeline.
/// @dev Replaces V1 (which was per-vault). This adapter is shared across all vaults.
///
///      Pipeline: OpsCollectorV2.splitAll() → FeeDistributorV2.fundEpochPayout()
///
///      Deterministic priority: SPLIT > FUND.
///      Permissionless, stateless (immutables only).
///      Safe-idempotent: performUpkeep re-checks state before calling.
contract PeripheryUpkeepAdapterV2 is AutomationCompatibleInterface {
    // ═══════════════════════════════════════════════════════════════════════════
    // IMMUTABLES
    // ═══════════════════════════════════════════════════════════════════════════

    IOpsCollectorV2 public immutable opsCollector;
    IFeeDistributorV2 public immutable feeDistributor;
    IERC20 public immutable asset; // USDC

    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    event PeripheryUpkeepPerformed(PeripheryOp op);

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    constructor(address opsCollector_, address feeDistributor_) {
        require(opsCollector_ != address(0), "opsCollector=0");
        require(feeDistributor_ != address(0), "feeDistributor=0");

        opsCollector = IOpsCollectorV2(opsCollector_);
        feeDistributor = IFeeDistributorV2(feeDistributor_);
        asset = IFeeDistributorV2(feeDistributor_).ASSET();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // checkUpkeep — Deterministic Priority: SPLIT > FUND
    // ═══════════════════════════════════════════════════════════════════════════

    function checkUpkeep(bytes calldata)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        // Priority 1: SPLIT — OpsCollectorV2 has shares from any vault to split
        if (!opsCollector.paused() && _anyVaultShareBalance()) {
            return (true, abi.encode(PeripheryOp.SPLIT));
        }

        // Priority 2: FUND — FeeDistributorV2 has USDC to forward to EpochPayout
        if (_canFund()) {
            return (true, abi.encode(PeripheryOp.FUND));
        }

        return (false, bytes(""));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // performUpkeep — Safe-Idempotent (CTO MANDATE)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Execute one pipeline step. Never reverts on stale performData.
    function performUpkeep(bytes calldata performData) external override {
        PeripheryOp op = abi.decode(performData, (PeripheryOp));

        if (op == PeripheryOp.SPLIT) {
            if (opsCollector.paused()) return;
            if (!_anyVaultShareBalance()) return;
            opsCollector.splitAll();
            emit PeripheryUpkeepPerformed(PeripheryOp.SPLIT);
            return;
        }

        if (op == PeripheryOp.FUND) {
            if (!_canFund()) return;
            feeDistributor.fundEpochPayout(feeDistributor.currentEpochId());
            emit PeripheryUpkeepPerformed(PeripheryOp.FUND);
            return;
        }

        revert UnknownOp();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL VIEW HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Check if OpsCollectorV2 holds shares from any registered vault.
    function _anyVaultShareBalance() internal view returns (bool) {
        address[] memory vaults = opsCollector.getVaults();
        uint256 len = vaults.length;
        for (uint256 i = 0; i < len; i++) {
            if (IERC20(vaults[i]).balanceOf(address(opsCollector)) > 0) {
                return true;
            }
        }
        return false;
    }

    /// @dev All fund preconditions for FeeDistributorV2.
    function _canFund() internal view returns (bool) {
        if (feeDistributor.paused()) return false;
        if (feeDistributor.fundingPaused()) return false;
        if (asset.balanceOf(address(feeDistributor)) == 0) return false;

        // Delay check
        uint256 earliest = feeDistributor.lastFundTimestamp() + feeDistributor.minDelayBetweenFunds();
        if (block.timestamp < earliest) return false;

        // Cap check
        uint256 maxFund = feeDistributor.maxFundPerEpoch();
        if (maxFund > 0) {
            uint32 epochId = feeDistributor.currentEpochId();
            if (feeDistributor.fundedInEpoch(epochId) >= maxFund) return false;
        }

        return true;
    }
}
