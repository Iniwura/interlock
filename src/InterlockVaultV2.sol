// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IArcPQVerifierV2 {
    function verifySlhDsaSha2128s(bytes calldata vk, bytes calldata message, bytes calldata sig)
        external
        returns (bool isValid);
}

/// @title InterlockVaultV2
/// @notice A wallet-owned Arc native USDC vault requiring an EVM owner and a PQ signature.
/// @dev Recovery can change only the PQ credential after a delay; it cannot move funds.
contract InterlockVaultV2 {
    address public constant ARC_PQ_VERIFIER = 0x1800000000000000000000000000000000000004;

    uint256 public constant PQ_SIGNATURE_LENGTH = 7856;
    uint256 public constant RECOVERY_DELAY = 3 days;

    bytes32 public constant PAYMENT_TAG = keccak256("INTERLOCK_PAYMENT_V2");
    bytes32 public constant ROTATION_TAG = keccak256("INTERLOCK_ROTATION_V2");
    bytes32 public constant RECOVERY_CANCEL_TAG = keccak256("INTERLOCK_RECOVERY_CANCEL_V2");
    bytes32 public constant RECOVERY_ACTIVATE_TAG = keccak256("INTERLOCK_RECOVERY_ACTIVATE_V2");

    address public immutable owner;

    bytes32 public pqPublicKey;
    uint256 public nonce;

    bytes32 public pendingPQKey;
    uint256 public pendingRecoveryNonce;
    uint256 public recoveryReadyAt;
    uint256 public recoveryNonce;

    uint256 private _reentrancyState = 1;

    error NotOwner();
    error ZeroOwner();
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
    error RecoveryAlreadyPending();
    error NoPendingRecovery();
    error RecoveryNotReady();

    event Deposit(address indexed from, uint256 amount, uint256 newBalance);
    event PaymentExecuted(address indexed recipient, uint256 amount, uint256 indexed authorizationNonce);
    event PQKeyRotated(bytes32 indexed oldPQKey, bytes32 indexed newPQKey, uint256 indexed authorizationNonce);
    event PQRecoveryRequested(bytes32 indexed newPQKey, uint256 indexed recoveryRequestNonce, uint256 readyAt);
    event PQRecoveryCancelled(bytes32 indexed pendingPQKey, uint256 indexed recoveryRequestNonce);
    event PQRecoveryActivated(bytes32 indexed oldPQKey, bytes32 indexed newPQKey, uint256 indexed authorizationNonce);

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

    constructor(address owner_, bytes32 initialPQPublicKey) {
        if (owner_ == address(0)) revert ZeroOwner();
        if (initialPQPublicKey == bytes32(0)) revert InvalidPQKey();
        owner = owner_;
        pqPublicKey = initialPQPublicKey;
    }

    receive() external payable {
        _deposit();
    }

    function deposit() external payable {
        _deposit();
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

    function recoveryCancelDigest(bytes32 key, uint256 requestNonce, uint256 readyAt, uint256 deadline)
        public
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(RECOVERY_CANCEL_TAG, block.chainid, address(this), key, requestNonce, readyAt, deadline)
        );
    }

    function recoveryActivationDigest(bytes32 key, uint256 requestNonce, uint256 readyAt, uint256 deadline)
        public
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(RECOVERY_ACTIVATE_TAG, block.chainid, address(this), key, requestNonce, readyAt, deadline)
        );
    }

    function executePayment(address payable recipient, uint256 amount, uint256 deadline, bytes calldata pqSignature)
        external
        onlyOwner
        nonReentrant
    {
        if (recipient == address(0)) revert ZeroRecipient();
        if (amount == 0) revert ZeroAmount();
        if (block.timestamp > deadline) revert AuthorizationExpired();
        if (amount > address(this).balance) revert InsufficientBalance();

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
        if (pendingPQKey != bytes32(0)) revert RecoveryAlreadyPending();
        if (block.timestamp > deadline) revert AuthorizationExpired();

        uint256 authorizationNonce = nonce;
        bytes32 oldPQKey = pqPublicKey;
        bytes32 digest = rotationDigest(oldPQKey, newPQKey, authorizationNonce, deadline);

        _verifyPQ(oldPQKey, digest, currentKeySignature);
        _verifyPQ(newPQKey, digest, newKeySignature);

        nonce = authorizationNonce + 1;
        pqPublicKey = newPQKey;
        emit PQKeyRotated(oldPQKey, newPQKey, authorizationNonce);
    }

    function requestPQRecovery(bytes32 newPQKey) external onlyOwner {
        if (newPQKey == bytes32(0)) revert InvalidPQKey();
        if (newPQKey == pqPublicKey) revert SamePQKey();
        if (pendingPQKey != bytes32(0)) revert RecoveryAlreadyPending();

        uint256 requestNonce = recoveryNonce;
        recoveryNonce = requestNonce + 1;
        pendingPQKey = newPQKey;
        pendingRecoveryNonce = requestNonce;
        recoveryReadyAt = block.timestamp + RECOVERY_DELAY;

        emit PQRecoveryRequested(newPQKey, requestNonce, recoveryReadyAt);
    }

    function cancelPQRecovery(uint256 deadline, bytes calldata oldKeySignature) external onlyOwner nonReentrant {
        if (pendingPQKey == bytes32(0)) revert NoPendingRecovery();
        if (block.timestamp > deadline) revert AuthorizationExpired();

        bytes32 pendingKey = pendingPQKey;
        uint256 requestNonce = pendingRecoveryNonce;
        uint256 readyAt = recoveryReadyAt;
        bytes32 digest = recoveryCancelDigest(pendingKey, requestNonce, readyAt, deadline);
        _verifyPQ(pqPublicKey, digest, oldKeySignature);

        _clearPendingRecovery();
        emit PQRecoveryCancelled(pendingKey, requestNonce);
    }

    function activatePQRecovery(uint256 deadline, bytes calldata newKeySignature) external onlyOwner nonReentrant {
        if (pendingPQKey == bytes32(0)) revert NoPendingRecovery();
        if (block.timestamp < recoveryReadyAt) revert RecoveryNotReady();
        if (block.timestamp > deadline) revert AuthorizationExpired();

        bytes32 oldPQKey = pqPublicKey;
        bytes32 newPQKey = pendingPQKey;
        uint256 requestNonce = pendingRecoveryNonce;
        uint256 readyAt = recoveryReadyAt;
        bytes32 digest = recoveryActivationDigest(newPQKey, requestNonce, readyAt, deadline);
        _verifyPQ(newPQKey, digest, newKeySignature);

        _clearPendingRecovery();
        pqPublicKey = newPQKey;
        uint256 authorizationNonce = nonce;
        nonce = authorizationNonce + 1;

        emit PQRecoveryActivated(oldPQKey, newPQKey, authorizationNonce);
    }

    function _deposit() internal {
        if (msg.value == 0) revert ZeroAmount();
        emit Deposit(msg.sender, msg.value, address(this).balance);
    }

    function _clearPendingRecovery() internal {
        pendingPQKey = bytes32(0);
        pendingRecoveryNonce = 0;
        recoveryReadyAt = 0;
        recoveryNonce += 1;
    }

    function _verifyPQ(bytes32 key, bytes32 digest, bytes calldata signature) internal {
        if (signature.length != PQ_SIGNATURE_LENGTH) revert InvalidPQSignatureLength(signature.length);

        bytes memory callData = abi.encodeWithSelector(
            IArcPQVerifierV2.verifySlhDsaSha2128s.selector, abi.encodePacked(key), abi.encodePacked(digest), signature
        );
        (bool success, bytes memory result) = ARC_PQ_VERIFIER.call(callData);
        if (!success || result.length != 32) revert InvalidPQAuthorization();

        uint256 verified;
        assembly {
            verified := mload(add(result, 0x20))
        }
        if (verified != 1) revert InvalidPQAuthorization();
    }
}
