// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {InterlockVaultV2} from "./InterlockVaultV2.sol";

/// @title InterlockFactory
/// @notice Creates one non-upgradeable InterlockVaultV2 for each owner address.
contract InterlockFactory {
    mapping(address owner => address vault) public vaultOf;

    error VaultAlreadyExists(address vault);
    error VaultCreationFailed();

    event VaultCreated(address indexed owner, address indexed vault, bytes32 indexed pqPublicKey);

    function createVault(bytes32 pqPublicKey) external returns (address vault) {
        address existing = vaultOf[msg.sender];
        if (existing != address(0)) revert VaultAlreadyExists(existing);

        bytes32 salt = keccak256(abi.encode(msg.sender, pqPublicKey));
        vault = address(new InterlockVaultV2{salt: salt}(msg.sender, pqPublicKey));
        if (vault.code.length == 0) revert VaultCreationFailed();

        vaultOf[msg.sender] = vault;
        emit VaultCreated(msg.sender, vault, pqPublicKey);
    }

    function predictVault(address owner, bytes32 pqPublicKey) external view returns (address) {
        bytes32 salt = keccak256(abi.encode(owner, pqPublicKey));
        bytes memory initCode = abi.encodePacked(type(InterlockVaultV2).creationCode, abi.encode(owner, pqPublicKey));
        bytes32 initCodeHash = keccak256(initCode);
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }
}
