// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AutomationCompatibleInterface } from "@multyr-core/automation/AutomationCompatibleInterface.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IFeeCollectorForUpkeep {
    function distribute(address token) external;
    function harvestQueued(address token) external;
    function paused() external view returns (bool);
    function allowlistEnabled() external view returns (bool);
    function allowedToken(address token) external view returns (bool);
    function minDistribution(address token) external view returns (uint256);
    function shareConfigs(address token) external view returns (bool, uint8, address);
    function pendingHarvestClaimCount(address token) external view returns (uint256);
    function pendingHarvestClaimAt(address token, uint256 index) external view returns (uint256, uint256);
}

/// @dev ABI of the epoch queue deployed September 25, 2026.
interface IFeeHarvestVault {
    struct Claim { address user; uint64 requestedAt; bool claimed; uint256 assetsOwed; uint256 grossShares; }
    struct Epoch {
        uint8 state; uint64 openedAt; uint64 closedAt; uint64 fundedAt;
        uint256 totalGrossShares; uint256 totalNetShares; uint256 totalFeeShares;
        uint256 totalAssetsOwed; uint256 claimedAssets; uint256 claimCount;
        uint256 reservedRemaining; uint256 recoveryIndex;
    }
    function epochClaim(uint256 epoch, uint256 claim) external view returns (Claim memory);
    function epochData(uint256 epoch) external view returns (Epoch memory);
    function pausedFundedClaim() external view returns (bool);
    function asset() external view returns (address);
}

/// @title FeeCollectorUpkeep
/// @notice Chainlink Automation contract that periodically calls FeeCollector.distribute()
///         for registered tokens. Interval is configurable by the owner.
/// @dev    Follows the same patterns as MultiplyStrategyUpkeep (time-based, Ownable) and
///         PeripheryUpkeepAdapter (safe-idempotent performUpkeep, CTO mandate).
contract FeeCollectorUpkeep is AutomationCompatibleInterface, Ownable, ReentrancyGuard {
    // ═══════════════════════════════════════════════════════════════════════════
    // IMMUTABLES
    // ═══════════════════════════════════════════════════════════════════════════

    IFeeCollectorForUpkeep public immutable feeCollector;

    // ═══════════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════════

    uint256 public constant MAX_TOKENS = 32;
    uint256 public constant MAX_PENDING_CLAIMS = 64;
    uint256 public constant RETRY_DELAY = 5 minutes;
    mapping(address => uint256) public distributionRetryAt;
    mapping(address => uint256) public harvestRetryAt;
    event HarvestTriggered(address indexed token);
    event HarvestFailed(address indexed token, bytes reason);
    event DistributionDeferred(address indexed token);

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
        require(tokens.length < MAX_TOKENS, "too many tokens");
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

    /// @notice Finds ready queue cleanup first, independently of distribution intervals.
    /// @dev A broken registered token cannot block checks for the others. Scans are bounded
    ///      to MAX_TOKENS * MAX_PENDING_CLAIMS; configure a smaller list for low gas limits.
    function checkUpkeep(bytes calldata) external view override returns (bool, bytes memory) {
        if (feeCollector.paused()) return (false, bytes(""));
        for (uint256 i; i < tokens.length; ++i) {
            try this.harvestReady(tokens[i]) returns (bool ready) {
                if (ready) return (true, abi.encode(tokens[i], uint8(1)));
            } catch {}
        }
        for (uint256 i; i < tokens.length; ++i) {
            try this.distributionReady(tokens[i]) returns (bool ready) {
                if (ready) return (true, abi.encode(tokens[i]));
            } catch {}
        }
        return (false, bytes(""));
    }

    function harvestReady(address token) external view returns (bool) {
        if (!isToken[token] || feeCollector.paused() || block.timestamp < harvestRetryAt[token]) return false;
        (bool configured, uint8 mode, address underlying) = feeCollector.shareConfigs(token);
        if (!configured || mode != 2 || underlying == address(0)) return false;
        // harvestQueued can distribute accumulated underlying; match its allowlist guard.
        if (feeCollector.allowlistEnabled() && !feeCollector.allowedToken(underlying)) return false;
        uint256 count = feeCollector.pendingHarvestClaimCount(token);
        if (count > MAX_PENDING_CLAIMS) return false;
        for (uint256 i; i < count; ++i) {
            (uint256 epoch, uint256 claim) = feeCollector.pendingHarvestClaimAt(token, i);
            IFeeHarvestVault.Claim memory c = IFeeHarvestVault(token).epochClaim(epoch, claim);
            if (c.claimed) return true; // permissionless payout still needs bookkeeping cleanup
            if (c.user == address(feeCollector) && !IFeeHarvestVault(token).pausedFundedClaim()
                && IFeeHarvestVault(token).epochData(epoch).state == 2) return true;
        }
        return false;
    }

    function distributionReady(address token) external view returns (bool) {
        if (!isToken[token] || feeCollector.paused() || block.timestamp < distributionRetryAt[token]) return false;
        uint256 last = lastDistributeTs[token];
        if (last != 0 && block.timestamp < last + uint256(interval)) return false;
        if (feeCollector.allowlistEnabled() && !feeCollector.allowedToken(token)) return false;
        uint256 balance = IERC20(token).balanceOf(address(feeCollector));
        if (balance == 0) return false;
        (bool isShare, uint8 mode, address underlying) = feeCollector.shareConfigs(token);
        if (!isShare) {
            try IFeeHarvestVault(token).asset() returns (address asset) { isShare = asset != address(0); }
            catch {}
        }
        if (!isShare) return balance >= feeCollector.minDistribution(token);
        if (mode == 2) {
            if (feeCollector.pendingHarvestClaimCount(token) >= MAX_PENDING_CLAIMS) return false;
            if (feeCollector.allowlistEnabled() && !feeCollector.allowedToken(underlying)) return false;
        }
        // Collector does not apply the ERC20 threshold to share-token modes.
        return true;
    }

    /// @dev Legacy address-only data still distributes. Action 1 cleans queued harvests.
    ///      Revalidate stale data, and only begin the long interval after actual progress.
    function performUpkeep(bytes calldata data) external override nonReentrant {
        if (data.length != 32 && data.length != 64) return;
        uint256 rawToken;
        uint256 action;
        assembly {
            rawToken := calldataload(data.offset)
            if eq(data.length, 64) { action := calldataload(add(data.offset, 32)) }
        }
        if (rawToken > type(uint160).max || action > 1) return;
        address token = address(uint160(rawToken));
        if (action == 1) {
            try this.harvestReady(token) returns (bool ready) { if (!ready) return; } catch { return; }
            try feeCollector.harvestQueued(token) {
                delete harvestRetryAt[token];
                emit HarvestTriggered(token);
            } catch (bytes memory reason) {
                harvestRetryAt[token] = block.timestamp + RETRY_DELAY;
                emit HarvestFailed(token, reason);
            }
        } else {
            try this.distributionReady(token) returns (bool ready) { if (!ready) return; } catch { return; }
            uint256 beforeBalance = IERC20(token).balanceOf(address(feeCollector));
            try feeCollector.distribute(token) {
                if (IERC20(token).balanceOf(address(feeCollector)) < beforeBalance) {
                    lastDistributeTs[token] = uint64(block.timestamp);
                    delete distributionRetryAt[token];
                    emit DistributionTriggered(token, block.timestamp);
                } else {
                    distributionRetryAt[token] = block.timestamp + RETRY_DELAY;
                    emit DistributionDeferred(token);
                }
            } catch (bytes memory reason) {
                distributionRetryAt[token] = block.timestamp + RETRY_DELAY;
                emit DistributionFailed(token, reason);
            }
        }
    }
}
