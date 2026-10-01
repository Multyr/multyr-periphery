// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AutomationReceiver} from "../src/AutomationReceiver.sol";

interface DeployVm {
    function envAddress(string calldata) external returns (address);
    function envUint(string calldata) external returns (uint256);
    function startBroadcast() external;
    function stopBroadcast() external;
}
interface UpkeepOwner { function owner() external view returns (address); }

/// @notice Deploys/configures only the CRE receiver for StrategyUpkeep. Uses a Foundry wallet
///         account, never a hardcoded key. Mirrors DeployVaultReceiver.s.sol; a separate receiver
///         instance is used per the runbook's "one receiver per workflow/security boundary"
///         guidance, since this receiver's outbound allowlist is scoped to StrategyUpkeep only.
contract DeployStrategyReceiver {
    DeployVm constant vm = DeployVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address constant UPKEEP = 0xd32a464df8e90D8aa9Bc290C4635eCE8D5362550;
    address constant FORWARDER = 0xF8344CFd5c43616a4366C34E3EEE75af79a74482;
    address constant GOVERNANCE = 0xE2812E869F8005397130CCDF1aaabd75447844df;
    event ReceiverConfigured(address receiver, address upkeep, address governance);

    function run() external returns (AutomationReceiver receiver) {
        require(block.chainid == 42161, "Arbitrum only");
        require(UPKEEP.code.length > 0 && FORWARDER.code.length > 0, "missing chain contracts");
        require(UpkeepOwner(UPKEEP).owner() == GOVERNANCE, "governance changed; review deployment");
        address author = vm.envAddress("WORKFLOW_AUTHOR");
        uint256 consumerGas = vm.envUint("CONSUMER_GAS_LIMIT");
        require(author != address(0) && consumerGas > 0, "author and measured gas required");
        vm.startBroadcast();
        receiver = new AutomationReceiver(FORWARDER);
        receiver.setExpectedAuthor(author);
        receiver.setExpectedWorkflowName("multyr-strategy-production");
        receiver.setCallAllowed(UPKEEP, bytes4(keccak256("performUpkeep(bytes)")), true);
        receiver.setConsumerGasLimit(UPKEEP, bytes4(keccak256("performUpkeep(bytes)")), consumerGas);
        receiver.transferOwnership(GOVERNANCE);
        vm.stopBroadcast();
        emit ReceiverConfigured(address(receiver), UPKEEP, GOVERNANCE);
    }
}
