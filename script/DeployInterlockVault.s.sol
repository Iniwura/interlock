// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {InterlockVault} from "../src/InterlockVault.sol";

/// @notice Parameterized InterlockVault deployment rehearsal.
/// @dev The caller supplies both the expected deployer/owner and the initial PQ
///      public key. No wallet or PQ private key belongs in this source file.
contract DeployInterlockVault is Script {
    error ZeroExpectedDeployer();
    error ZeroPQPublicKey();
    error UnexpectedOwner(address actualOwner, address expectedOwner);

    function run(address expectedDeployer, bytes32 initialPQPublicKey) external returns (address deployedVault) {
        if (expectedDeployer == address(0)) revert ZeroExpectedDeployer();
        if (initialPQPublicKey == bytes32(0)) revert ZeroPQPublicKey();

        // In a dry run this creates a simulated deployment. A broadcast still
        // requires the operator to opt in with forge's explicit --broadcast
        // flag and provide a signer for expectedDeployer.
        vm.startBroadcast(expectedDeployer);
        InterlockVault vault = new InterlockVault(initialPQPublicKey);
        vm.stopBroadcast();

        address actualOwner = vault.owner();
        if (actualOwner != expectedDeployer) {
            revert UnexpectedOwner(actualOwner, expectedDeployer);
        }

        return address(vault);
    }
}
