// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IStrategyRouter } from "@multyr-core/interfaces/IStrategyRouter.sol";
import { IBufferManager } from "@multyr-core/interfaces/IBufferManager.sol";

/// @title PlanDeposit -- off-chain deposit allocation planner (PR-EO keeper integration)
/// @notice Calculates optimal Allocation[] plan for keeper WITHOUT calling on-chain planDeposit().
///         The planning logic is replicated here off-chain to reduce on-chain complexity.
///         Replaces legacy monorepo script/planner/PlanDeposit.s.sol.
/// @dev View-only script (no broadcast). Output piped to keeper for execute-only pattern.
///      Does NOT call router.planDeposit() -- all calculation is done off-chain.
/// @custom:chain-id 42161 (Arbitrum One -- enforced at runtime)
/// @custom:usage forge script multyr-periphery/script/planner/PlanDeposit.s.sol:PlanDeposit \
///               --rpc-url $RPC_URL --sig "run(address)" $VAULT_ADDRESS
/// @custom:replaces script/planner/PlanDeposit.s.sol (legacy monorepo path)
contract PlanDeposit is Script {

    uint256 constant ARBITRUM_ONE_CHAIN_ID = 42161;
    /// @notice Maximum legs per plan (matches StrategyRouter.MAX_DEPOSIT_LEGS)
    uint8 constant MAX_LEGS = 12;

    struct PlanOutput {
        address[] strategies;
        uint256[] amounts;
        uint256 totalAmount;
        bool valid;
        string reason;
    }

    function run(address vault) external view returns (PlanOutput memory output) {
        require(
            block.chainid == ARBITRUM_ONE_CHAIN_ID,
            "WRONG_CHAIN: PlanDeposit is Arbitrum-only (chainId 42161)"
        );
        console.log("=== PlanDeposit Off-Chain Planner ===");
        console.log("Vault:", vault);

        // 1. Get router from vault
        (bool ok, bytes memory data) = vault.staticcall(abi.encodeWithSignature("router()"));
        if (!ok) {
            output.valid = false;
            output.reason = "Failed to get router";
            return output;
        }
        address routerAddr = abi.decode(data, (address));

        if (routerAddr == address(0)) {
            output.valid = false;
            output.reason = "Router not configured";
            return output;
        }

        IStrategyRouter router = IStrategyRouter(routerAddr);
        console.log("Router:", routerAddr);

        // 2. Get asset address
        (ok, data) = vault.staticcall(abi.encodeWithSignature("asset()"));
        if (!ok) {
            output.valid = false;
            output.reason = "Failed to get asset";
            return output;
        }
        address assetAddr = abi.decode(data, (address));

        // 3. Get hot balance
        uint256 hot = IERC20(assetAddr).balanceOf(vault);
        console.log("Hot balance:", hot);

        // 4. Get available surplus (hot - opsReserve)
        uint256 available = _getAvailableSurplus(vault, assetAddr, hot);
        console.log("Available surplus:", available);

        if (available == 0) {
            output.valid = false;
            output.reason = "No available surplus to deploy";
            return output;
        }

        // 5. Get strategy list
        IStrategyRouter.StrategyInfo[] memory strategies = router.list();

        if (strategies.length == 0) {
            output.valid = false;
            output.reason = "No strategies registered";
            return output;
        }

        // 6. Get intake mode
        IStrategyRouter.IntakeMode mode = router.intakeMode();
        console.log("Intake mode:", uint256(mode));

        // 7. Calculate plan based on mode (replicating planDeposit logic off-chain)
        if (mode == IStrategyRouter.IntakeMode.NONE) {
            output.valid = false;
            output.reason = "IntakeMode is NONE - no allocation";
            return output;
        }

        // Count enabled strategies
        uint256 enabledCount = 0;
        for (uint256 i = 0; i < strategies.length; i++) {
            if (strategies[i].enabled) enabledCount++;
        }

        if (enabledCount == 0) {
            output.valid = false;
            output.reason = "No enabled strategies";
            return output;
        }

        if (enabledCount > MAX_LEGS) {
            output.valid = false;
            output.reason = "Too many enabled strategies (> MAX_LEGS)";
            return output;
        }

        // Allocate output arrays
        output.strategies = new address[](enabledCount);
        output.amounts = new uint256[](enabledCount);

        if (mode == IStrategyRouter.IntakeMode.PRIORITY) {
            // Priority mode: allocate to highest priority (lowest number) first
            _allocatePriority(strategies, available, output);
        } else if (mode == IStrategyRouter.IntakeMode.WEIGHTED) {
            // Weighted mode: allocate proportionally by weightBps
            _allocateWeighted(strategies, available, output);
        }

        // Validate total
        output.totalAmount = 0;
        for (uint256 i = 0; i < output.amounts.length; i++) {
            output.totalAmount += output.amounts[i];
        }

        if (output.totalAmount > available) {
            output.valid = false;
            output.reason = "Plan sum exceeds available";
            return output;
        }

        output.valid = true;
        output.reason = "OK";

        // Log for keeper consumption
        console.log("");
        console.log("=== Plan Output ===");
        console.log("Total to deploy:", output.totalAmount);
        console.log("Legs:", output.strategies.length);
        for (uint256 i = 0; i < output.strategies.length; i++) {
            console.log("  Strategy:", output.strategies[i]);
            console.log("  Amount:", output.amounts[i]);
        }

        return output;
    }

    function _getAvailableSurplus(address vault, address assetAddr, uint256 hot)
        internal
        view
        returns (uint256)
    {
        // Try to get BufferManager
        (bool ok, bytes memory data) = vault.staticcall(abi.encodeWithSignature("bufferManager()"));
        if (!ok) return hot; // Fallback to full hot

        address bmAddr = abi.decode(data, (address));
        if (bmAddr == address(0)) return hot; // Fallback to full hot

        // Get ops reserve target
        IBufferManager bm = IBufferManager(bmAddr);
        try bm.getConfig() returns (IBufferManager.BufferConfig memory cfg) {
            if (cfg.opsReserveTargetBps > 0) {
                // Get NAV
                (ok, data) = vault.staticcall(abi.encodeWithSignature("totalAssets()"));
                if (ok) {
                    uint256 nav = abi.decode(data, (uint256));
                    uint256 minHot = (nav * cfg.opsReserveTargetBps) / 1e4;
                    return hot > minHot ? hot - minHot : 0;
                }
            }
        } catch { }

        return hot; // Fallback to full hot
    }

    function _allocatePriority(
        IStrategyRouter.StrategyInfo[] memory strategies,
        uint256 available,
        PlanOutput memory output
    ) internal pure {
        // Find max priority value for iteration bound
        uint16 maxPriority = 0;
        for (uint256 i = 0; i < strategies.length; i++) {
            if (strategies[i].enabled && strategies[i].priority > maxPriority) {
                maxPriority = strategies[i].priority;
            }
        }

        uint256 remaining = available;
        uint256 k = 0;

        // Iterate by priority level (0 = highest priority)
        for (uint16 p = 0; remaining > 0 && p <= maxPriority; p++) {
            for (uint256 i = 0; i < strategies.length && remaining > 0; i++) {
                if (!strategies[i].enabled || strategies[i].priority != p) continue;

                // Allocate all remaining to this strategy
                output.strategies[k] = strategies[i].strat;
                output.amounts[k] = remaining;
                remaining = 0;
                k++;
            }
        }
    }

    function _allocateWeighted(
        IStrategyRouter.StrategyInfo[] memory strategies,
        uint256 available,
        PlanOutput memory output
    ) internal pure {
        // Calculate total weight
        uint256 totalWeight = 0;
        for (uint256 i = 0; i < strategies.length; i++) {
            if (strategies[i].enabled) {
                totalWeight += strategies[i].weightBps;
            }
        }

        uint256 k = 0;

        if (totalWeight == 0) {
            // No weights set - distribute equally
            uint256 enabledCount = 0;
            for (uint256 i = 0; i < strategies.length; i++) {
                if (strategies[i].enabled) enabledCount++;
            }
            uint256 perStrategy = available / enabledCount;

            for (uint256 i = 0; i < strategies.length; i++) {
                if (strategies[i].enabled) {
                    output.strategies[k] = strategies[i].strat;
                    output.amounts[k] = perStrategy;
                    k++;
                }
            }
            return;
        }

        // Allocate proportionally
        uint256 allocated = 0;
        for (uint256 i = 0; i < strategies.length; i++) {
            if (!strategies[i].enabled) continue;

            output.strategies[k] = strategies[i].strat;

            // Calculate proportional amount
            uint256 amount = (available * strategies[i].weightBps) / totalWeight;

            // For last strategy, give remainder to avoid dust
            if (k == output.strategies.length - 1) {
                amount = available - allocated;
            }

            output.amounts[k] = amount;
            allocated += amount;
            k++;
        }
    }

    /// @notice Encode plan as JSON-compatible string for keeper integration
    function encodeAsJson(PlanOutput memory plan) external pure returns (string memory) {
        // Simple JSON encoding (for production, use a proper JSON library)
        if (!plan.valid) {
            return string(abi.encodePacked('{"valid":false,"reason":"', plan.reason, '"}'));
        }

        // Build strategies array
        bytes memory strategiesJson = "[";
        for (uint256 i = 0; i < plan.strategies.length; i++) {
            if (i > 0) strategiesJson = abi.encodePacked(strategiesJson, ",");
            strategiesJson = abi.encodePacked(
                strategiesJson,
                '{"strat":"',
                _addressToString(plan.strategies[i]),
                '","amount":',
                _uint256ToString(plan.amounts[i]),
                "}"
            );
        }
        strategiesJson = abi.encodePacked(strategiesJson, "]");

        return string(
            abi.encodePacked(
                '{"valid":true,"totalAmount":',
                _uint256ToString(plan.totalAmount),
                ',"allocations":',
                strategiesJson,
                "}"
            )
        );
    }

    function _addressToString(address addr) internal pure returns (string memory) {
        bytes memory s = new bytes(42);
        s[0] = "0";
        s[1] = "x";
        for (uint256 i = 0; i < 20; i++) {
            bytes1 b = bytes1(uint8(uint256(uint160(addr)) / (2 ** (8 * (19 - i)))));
            bytes1 hi = bytes1(uint8(b) / 16);
            bytes1 lo = bytes1(uint8(b) - 16 * uint8(hi));
            s[2 + 2 * i] = _char(hi);
            s[3 + 2 * i] = _char(lo);
        }
        return string(s);
    }

    function _char(bytes1 b) internal pure returns (bytes1 c) {
        if (uint8(b) < 10) return bytes1(uint8(b) + 0x30);
        else return bytes1(uint8(b) + 0x57);
    }

    function _uint256ToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
