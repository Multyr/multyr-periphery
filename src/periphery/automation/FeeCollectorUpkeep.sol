// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AutomationCompatibleInterface } from "@multyr-core/automation/AutomationCompatibleInterface.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IFeeCollectorForUpkeep {
    function distribute(address token) external;
}

/// @title FeeCollectorUpkeep
/// @notice Chainlink Automation contract that periodically calls FeeCollector.distribute()
///         for registered tokens. Interval is configurable by the owner.
/// @dev    Follows the same patterns as MultiplyStrategyUpkeep (time-based, Ownable) and
///         PeripheryUpkeepAdapter (safe-idempotent performUpkeep, CTO mandate).
contract FeeCollectorUpkeep is AutomationCompatibleInterface, Ownable {
    // ═══════════════════════════════════════════════════════════════════════════
    // IMMUTABLES
    // ═══════════════════════════════════════════════════════════════════════════

    IFeeCollectorForUpkeep public immutable feeCollector;

    // ═══════════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════════

    uint64 public interval; // seconds between distributions (default 3 days = 259200)
    address[] public tokens; // tokens to distribute
    mapping(address => bool) public isToken;
    mapping(address => uint64) public lastDistributeTs;

    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    event IntervalUpdated(uint64 oldInterval, uint64 newInterval);
    event TokenAdded(address indexed token);
    event TokenRemoved(address indexed token);
    event DistributionTriggered(address indexed token, uint256 timestamp);
    event DistributionFailed(address indexed token, bytes reason);

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    constructor(address feeCollector_, address initialOwner_, uint64 interval_) {
        require(feeCollector_ != address(0), "feeCollector=0");
        feeCollector = IFeeCollectorForUpkeep(feeCollector_);
        interval = interval_;
        if (initialOwner_ != address(0) && initialOwner_ != msg.sender) {
            _transferOwnership(initialOwner_);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN (onlyOwner)
    // ═══════════════════════════════════════════════════════════════════════════

    function setInterval(uint64 newInterval) external onlyOwner {
        emit IntervalUpdated(interval, newInterval);
        interval = newInterval;
    }

    function addToken(address token) external onlyOwner {
        require(token != address(0), "token=0");
        require(!isToken[token], "already added");
        tokens.push(token);
        isToken[token] = true;
        emit TokenAdded(token);
    }

    function removeToken(address token) external onlyOwner {
        require(isToken[token], "not found");
        isToken[token] = false;
        uint256 len = tokens.length;
        for (uint256 i = 0; i < len; i++) {
            if (tokens[i] == token) {
                tokens[i] = tokens[len - 1];
                tokens.pop();
                break;
            }
        }
        emit TokenRemoved(token);
    }

    function getTokens() external view returns (address[] memory) {
        return tokens;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CHAINLINK AUTOMATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns true + encoded token address when a registered token is due
    ///         for distribution and has a non-zero balance at the FeeCollector.
    function checkUpkeep(bytes calldata)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        uint256 len = tokens.length;
        for (uint256 i = 0; i < len; i++) {
            address token = tokens[i];
            uint64 lastTs = lastDistributeTs[token];
            if (
                (lastTs == 0 || block.timestamp >= lastTs + interval)
                    && IERC20(token).balanceOf(address(feeCollector)) > 0
            ) {
                return (true, abi.encode(token));
            }
        }
        return (false, bytes(""));
    }

    /// @notice Execute distribution for the given token.
    /// @dev Safe-idempotent (CTO mandate): re-checks all preconditions,
    ///      silent returns if state changed. Uses try/catch so Chainlink
    ///      never enters a revert loop.
    function performUpkeep(bytes calldata performData) external override {
        address token = abi.decode(performData, (address));

        // Safe-idempotent guards
        if (!isToken[token]) return;
        uint64 lastTs = lastDistributeTs[token];
        if (lastTs != 0 && block.timestamp < lastTs + interval) return;
        if (IERC20(token).balanceOf(address(feeCollector)) == 0) return;

        lastDistributeTs[token] = uint64(block.timestamp);

        try feeCollector.distribute(token) {
            emit DistributionTriggered(token, block.timestamp);
        } catch (bytes memory reason) {
            emit DistributionFailed(token, reason);
        }
    }
}
