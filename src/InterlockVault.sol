// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IArcPQVerifier {
    function verifySlhDsaSha2128s(bytes calldata vk, bytes calldata message, bytes calldata sig)
        external
        returns (bool isValid);
}

/// @title InterlockVault
/// @notice Hybrid wallet + SLH-DSA authorization vault for Arc native USDC.
/// @dev A payment requires both the vault owner and the registered PQ key.
contract InterlockVault {
    address public constant ARC_PQ_VERIFIER = 0x1800000000000000000000000000000000000004;

    uint256 public constant PQ_SIGNATURE_LENGTH = 7856;

    bytes32 public constant PAYMENT_TAG = keccak256("INTERLOCK_PAYMENT_V1");

    bytes32 public constant ROTATION_TAG = keccak256("INTERLOCK_ROTATION_V1");

    address public immutable owner;

    bytes32 public pqPublicKey;
    uint256 public nonce;

    uint256 private _reentrancyState = 1;

    error NotOwner();
    error ZeroAmount();
    error ZeroRecipient();
    error InvalidPQKey();
    error SamePQKey();
    error AuthorizationExpired();
    error InvalidPQSignatureLength(uint256 actualLength);
    error InvalidPQAuthorization();
    error InsufficientBalance();
    error NativeTransferFailed();
    error Reentrancy();

    event Deposit(address indexed from, uint256 amount, uint256 newBalance);

    event PaymentExecuted(address indexed recipient, uint256 amount, uint256 indexed authorizationNonce);

    event PQKeyRotated(bytes32 indexed oldPQKey, bytes32 indexed newPQKey, uint256 indexed authorizationNonce);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_reentrancyState != 1) revert Reentrancy();

        _reentrancyState = 2;
        _;
        _reentrancyState = 1;
    }

    constructor(bytes32 initialPQPublicKey) {
        if (initialPQPublicKey == bytes32(0)) {
            revert InvalidPQKey();
        }

        owner = msg.sender;
        pqPublicKey = initialPQPublicKey;
    }

    receive() external payable {
        if (msg.value == 0) revert ZeroAmount();

        emit Deposit(msg.sender, msg.value, address(this).balance);
    }

    function deposit() external payable {
        if (msg.value == 0) revert ZeroAmount();

        emit Deposit(msg.sender, msg.value, address(this).balance);
    }

    function balance() external view returns (uint256) {
        return address(this).balance;
    }

    function paymentDigest(address recipient, uint256 amount, uint256 authorizationNonce, uint256 deadline)
        public
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(PAYMENT_TAG, block.chainid, address(this), recipient, amount, authorizationNonce, deadline)
        );
    }

    function rotationDigest(bytes32 currentPQKey, bytes32 newPQKey, uint256 authorizationNonce, uint256 deadline)
        public
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(ROTATION_TAG, block.chainid, address(this), currentPQKey, newPQKey, authorizationNonce, deadline)
        );
    }

    function executePayment(address payable recipient, uint256 amount, uint256 deadline, bytes calldata pqSignature)
        external
        onlyOwner
        nonReentrant
    {
        if (recipient == address(0)) revert ZeroRecipient();
        if (amount == 0) revert ZeroAmount();
        if (block.timestamp > deadline) {
            revert AuthorizationExpired();
        }

        if (amount > address(this).balance) {
            revert InsufficientBalance();
        }

        uint256 authorizationNonce = nonce;

        bytes32 digest = paymentDigest(recipient, amount, authorizationNonce, deadline);

        _verifyPQ(pqPublicKey, digest, pqSignature);

        nonce = authorizationNonce + 1;

        (bool sent,) = recipient.call{value: amount}("");

        if (!sent) revert NativeTransferFailed();

        emit PaymentExecuted(recipient, amount, authorizationNonce);
    }

    function rotatePQKey(
        bytes32 newPQKey,
        uint256 deadline,
        bytes calldata currentKeySignature,
        bytes calldata newKeySignature
    ) external onlyOwner nonReentrant {
        if (newPQKey == bytes32(0)) revert InvalidPQKey();
        if (newPQKey == pqPublicKey) revert SamePQKey();

        if (block.timestamp > deadline) {
            revert AuthorizationExpired();
        }

        uint256 authorizationNonce = nonce;
        bytes32 oldPQKey = pqPublicKey;

        bytes32 digest = rotationDigest(oldPQKey, newPQKey, authorizationNonce, deadline);

        // Existing PQ credential authorizes the rotation.
        _verifyPQ(oldPQKey, digest, currentKeySignature);

        // Replacement key proves possession before registration.
        _verifyPQ(newPQKey, digest, newKeySignature);

        nonce = authorizationNonce + 1;
        pqPublicKey = newPQKey;

        emit PQKeyRotated(oldPQKey, newPQKey, authorizationNonce);
    }

    function _verifyPQ(bytes32 key, bytes32 digest, bytes calldata signature) internal {
        if (signature.length != PQ_SIGNATURE_LENGTH) {
            revert InvalidPQSignatureLength(signature.length);
        }

        bytes memory callData = abi.encodeWithSelector(
            IArcPQVerifier.verifySlhDsaSha2128s.selector, abi.encodePacked(key), abi.encodePacked(digest), signature
        );

        (bool success, bytes memory result) = ARC_PQ_VERIFIER.call(callData);

        if (!success || result.length != 32) {
            revert InvalidPQAuthorization();
        }

        uint256 verified;

        assembly {
            verified := mload(add(result, 0x20))
        }

        if (verified != 1) {
            revert InvalidPQAuthorization();
        }
    }
}
