// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {InterlockFactory} from "../src/InterlockFactory.sol";

/// @notice Broadcast-free rehearsal script for the V2 factory.
/// @dev The operator supplies the public deployer address. No private key or
///      PQ material belongs in this source file.
contract DeployInterlockFactory is Script {
    error ZeroExpectedDeployer();

    function run(address expectedDeployer) external returns (address deployedFactory) {
        if (expectedDeployer == address(0)) revert ZeroExpectedDeployer();
        vm.startBroadcast(expectedDeployer);
        InterlockFactory factory = new InterlockFactory();
        vm.stopBroadcast();
        return address(factory);
    }
}
