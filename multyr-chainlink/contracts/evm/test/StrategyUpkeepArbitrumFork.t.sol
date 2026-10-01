// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AutomationReceiver} from "../src/AutomationReceiver.sol";

interface ForkVm {
    struct Log { bytes32[] topics; bytes data; address emitter; }
    function prank(address) external;
    function skip(bool) external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory);
}
interface LiveUpkeep {
    function checkUpkeep(bytes calldata) external view returns (bool, bytes memory);
    function performUpkeep(bytes calldata) external;
    function isStrategy(address) external view returns (bool);
    function owner() external view returns (address);
}
interface LiveStrategy { function hasRole(bytes32 role, address account) external view returns (bool); }

/// @notice Opt-in fork smoke test of the exact deployed StrategyUpkeep target; no transactions on
///         Arbitrum. Mirrors VaultUpkeepArbitrumFork.t.sol. StrategyUpkeep's success/failure signal
///         differs from VaultUpkeep's: instead of a single `UpkeepPerformed(uint8,uint256,bool)`
///         event carrying a success flag, StrategyUpkeep emits either `UpkeepPerformed(uint8,address,uint256)`
///         on success or `UpkeepErrored(uint8,address,bytes)` on failure (mutually exclusive per
///         action, except OP_POKE_APY which always emits UpkeepPerformed after best-effort,
///         individually try/catch'd sub-pokes). This test treats "UpkeepPerformed observed and
///         UpkeepErrored absent" as the success condition.
contract StrategyUpkeepArbitrumForkTest {
    ForkVm constant vm = ForkVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address constant UPKEEP = 0xd32a464df8e90D8aa9Bc290C4635eCE8D5362550;
    address constant STRATEGY = 0x2ca30120C828Fc136d348234f7e68116572DD83E;
    address constant FORWARDER = 0xF8344CFd5c43616a4366C34E3EEE75af79a74482;
    address constant GOVERNANCE = 0xE2812E869F8005397130CCDF1aaabd75447844df;
    bytes32 constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    event DeliveryMeasured(uint256 blockNumber, uint8 op, uint256 receiverGas);

    function testDueActionThroughReceiver() external {
        if (block.chainid != 42161) { vm.skip(true); return; }
        require(FORWARDER.code.length > 0, "forwarder absent");
        require(LiveUpkeep(UPKEEP).owner() == GOVERNANCE, "governance changed; review deployment");
        require(LiveUpkeep(UPKEEP).isStrategy(STRATEGY), "strategy not registered on upkeep");
        require(LiveStrategy(STRATEGY).hasRole(KEEPER_ROLE, UPKEEP), "upkeep missing KEEPER_ROLE on strategy");
        (bool needed, bytes memory data) = LiveUpkeep(UPKEEP).checkUpkeep("");
        require(needed, "No due action at fork block; choose a block with work");
        (uint8 op,) = abi.decode(data, (uint8, uint256));
        AutomationReceiver receiver = new AutomationReceiver(FORWARDER);
        receiver.setExpectedAuthor(address(this));
        receiver.setExpectedWorkflowName("multyr-strategy-production");
        receiver.setCallAllowed(UPKEEP, LiveUpkeep.performUpkeep.selector, true);
        bytes memory metadata = abi.encodePacked(bytes32(0), receiver.getExpectedWorkflowName(), address(this));
        bytes memory report = abi.encode(UPKEEP, block.number, abi.encodeCall(LiveUpkeep.performUpkeep, (data)));
        vm.recordLogs();
        vm.prank(FORWARDER);
        uint256 gasBefore = gasleft();
        receiver.onReport(metadata, report);
        uint256 used = gasBefore - gasleft();
        ForkVm.Log[] memory logs = vm.getRecordedLogs();
        bool performedSeen;
        bool erroredSeen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != UPKEEP || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] == keccak256("UpkeepPerformed(uint8,address,uint256)")) {
                performedSeen = true;
            } else if (logs[i].topics[0] == keccak256("UpkeepErrored(uint8,address,bytes)")) {
                erroredSeen = true;
            }
        }
        require(performedSeen, "No successful upkeep event");
        require(!erroredSeen, "Upkeep swallowed a downstream failure");
        emit DeliveryMeasured(block.number, op, used);
    }
}
