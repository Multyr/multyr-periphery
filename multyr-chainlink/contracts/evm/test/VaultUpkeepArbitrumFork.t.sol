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
    function core() external view returns (address);
    function checkUpkeep(bytes calldata) external view returns (bool, bytes memory);
    function performUpkeep(bytes calldata) external;
}
interface LiveBuffer { function keeper() external view returns (address); }

/// @notice Opt-in fork smoke test of the exact deployed target; no transactions on Arbitrum.
contract VaultUpkeepArbitrumForkTest {
    ForkVm constant vm = ForkVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address constant UPKEEP = 0x8672921E03c9995AE1Dbe234A7a08C327163883e;
    address constant VAULT = 0x4575Ec0dD1ED08FD4F426665E5B56442594189bb;
    address constant BUFFER = 0x8eCE4bB8CAd975902F221E961215aa0CB6a3e5a5;
    address constant FORWARDER = 0xF8344CFd5c43616a4366C34E3EEE75af79a74482;
    event DeliveryMeasured(uint256 blockNumber, uint8 op, uint256 receiverGas);

    function testDueActionThroughReceiver() external {
        if (block.chainid != 42161) { vm.skip(true); return; }
        require(FORWARDER.code.length > 0, "forwarder absent");
        require(LiveUpkeep(UPKEEP).core() == VAULT, "wrong vault");
        require(LiveBuffer(BUFFER).keeper() == UPKEEP, "wrong keeper");
        (bool needed, bytes memory data) = LiveUpkeep(UPKEEP).checkUpkeep("");
        require(needed, "No due action at fork block; choose a block with work");
        AutomationReceiver receiver = new AutomationReceiver(FORWARDER);
        receiver.setExpectedAuthor(address(this));
        receiver.setExpectedWorkflowName("multyr-core-production");
        receiver.setCallAllowed(UPKEEP, LiveUpkeep.performUpkeep.selector, true);
        bytes memory metadata = abi.encodePacked(bytes32(0), receiver.getExpectedWorkflowName(), address(this));
        bytes memory report = abi.encode(UPKEEP, block.number, abi.encodeCall(LiveUpkeep.performUpkeep, (data)));
        vm.recordLogs();
        vm.prank(FORWARDER);
        uint256 gasBefore = gasleft();
        receiver.onReport(metadata, report);
        uint256 used = gasBefore - gasleft();
        ForkVm.Log[] memory logs = vm.getRecordedLogs();
        bool succeeded;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == UPKEEP && logs[i].topics.length > 0
                && logs[i].topics[0] == keccak256("UpkeepPerformed(uint8,uint256,bool)")) {
                (,, bool success) = abi.decode(logs[i].data, (uint8, uint256, bool));
                require(success, "Upkeep swallowed a downstream failure");
                succeeded = true;
            }
        }
        require(succeeded, "No successful upkeep event");
        (uint8 op,) = abi.decode(data, (uint8, uint256));
        emit DeliveryMeasured(block.number, op, used);
    }
}
