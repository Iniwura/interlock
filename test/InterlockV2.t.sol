// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IArcPQVerifierV2, InterlockVaultV2} from "../src/InterlockVaultV2.sol";
import {InterlockFactory} from "../src/InterlockFactory.sol";

contract RejectNativeTransferV2 {
    receive() external payable {
        revert();
    }
}

contract ReentrantRecipientV2 {
    InterlockVaultV2 public vault;
    uint256 private amount;
    uint256 private deadline;
    bytes private signature;
    bool public attempted;
    bytes public reason;

    function deploy(bytes32 key) external {
        vault = new InterlockVaultV2(address(this), key);
    }

    function fund(uint256 value) external {
        vault.deposit{value: value}();
    }

    function execute(uint256 value, uint256 expiry, bytes calldata sig) external {
        amount = value;
        deadline = expiry;
        signature = sig;
        vault.executePayment(payable(address(this)), value, expiry, sig);
    }

    receive() external payable {
        if (attempted) return;
        attempted = true;
        try vault.executePayment(payable(address(this)), amount, deadline, signature) {}
        catch (bytes memory caught) {
            reason = caught;
        }
    }
}

contract InterlockVaultV2Test is Test {
    address internal constant VERIFIER = 0x1800000000000000000000000000000000000004;
    bytes32 internal constant KEY = keccak256("interlock-v2-test-key");
    bytes32 internal constant NEW_KEY = keccak256("interlock-v2-new-key");

    InterlockVaultV2 internal vault;
    InterlockFactory internal factory;
    address internal owner;
    address internal attacker;
    address payable internal recipient;

    function setUp() public {
        owner = makeAddr("v2-owner");
        attacker = makeAddr("v2-attacker");
        recipient = payable(makeAddr("v2-recipient"));
        vm.deal(owner, 10 ether);
        vm.prank(owner);
        vault = new InterlockVaultV2(owner, KEY);
        vm.prank(owner);
        vault.deposit{value: 1 ether}();
        factory = new InterlockFactory();
    }

    function _sig(uint8 marker) internal pure returns (bytes memory sig) {
        sig = new bytes(7856);
        sig[0] = bytes1(marker);
    }

    function _mock(bytes32 key, bytes32 digest, bytes memory sig, bool valid) internal {
        bytes memory callData = abi.encodeWithSelector(
            IArcPQVerifierV2.verifySlhDsaSha2128s.selector, abi.encodePacked(key), abi.encodePacked(digest), sig
        );
        vm.mockCall(VERIFIER, callData, abi.encode(valid));
    }

    function _mockPayment(address payable target, uint256 value, uint256 expiry, bytes memory sig, bool valid)
        internal
    {
        _mock(KEY, vault.paymentDigest(target, value, vault.nonce(), expiry), sig, valid);
    }

    function _mockRotation(
        bytes32 currentKey,
        bytes32 newKey,
        uint256 expiry,
        bytes memory currentSig,
        bytes memory newSig
    ) internal {
        bytes32 digest = vault.rotationDigest(currentKey, newKey, vault.nonce(), expiry);
        _mock(currentKey, digest, currentSig, true);
        _mock(newKey, digest, newSig, true);
    }

    function testFactoryCreatesOneOwnerBoundVault() public {
        bytes32 key = keccak256("factory-key");
        vm.prank(owner);
        address created = factory.createVault(key);
        assertEq(factory.vaultOf(owner), created);
        assertEq(InterlockVaultV2(payable(created)).owner(), owner);
        assertEq(InterlockVaultV2(payable(created)).pqPublicKey(), key);
        assertEq(factory.predictVault(owner, key), created);
    }

    function testFactoryRejectsSecondVaultForOwner() public {
        vm.prank(owner);
        address created = factory.createVault(keccak256("first"));
        vm.expectRevert(abi.encodeWithSelector(InterlockFactory.VaultAlreadyExists.selector, created));
        vm.prank(owner);
        factory.createVault(keccak256("second"));
    }

    function testFactoryRejectsZeroPQKey() public {
        vm.expectRevert(InterlockVaultV2.InvalidPQKey.selector);
        vm.prank(owner);
        factory.createVault(bytes32(0));
    }

    function testPaymentNeedsOwnerAndPQAuthorization() public {
        uint256 value = 0.1 ether;
        uint256 expiry = block.timestamp + 1 days;
        bytes memory sig = _sig(1);
        _mockPayment(recipient, value, expiry, sig, true);
        uint256 beforeRecipient = recipient.balance;
        vm.prank(owner);
        vault.executePayment(recipient, value, expiry, sig);
        assertEq(recipient.balance, beforeRecipient + value);
        assertEq(vault.nonce(), 1);
        vm.expectRevert(InterlockVaultV2.NotOwner.selector);
        vm.prank(attacker);
        vault.executePayment(recipient, value, expiry, sig);
    }

    function testPaymentBindsAmountRecipientChainVaultAndNonce() public {
        uint256 expiry = block.timestamp + 1 days;
        bytes memory sig = _sig(2);
        _mock(KEY, vault.paymentDigest(recipient, 0.1 ether, 0, expiry), sig, true);
        vm.expectRevert(InterlockVaultV2.InvalidPQAuthorization.selector);
        vm.prank(owner);
        vault.executePayment(recipient, 0.2 ether, expiry, sig);

        address payable otherRecipient = payable(makeAddr("other-recipient"));
        _mock(KEY, vault.paymentDigest(recipient, 0.1 ether, 0, expiry), _sig(3), true);
        vm.expectRevert(InterlockVaultV2.InvalidPQAuthorization.selector);
        vm.prank(owner);
        vault.executePayment(otherRecipient, 0.1 ether, expiry, _sig(3));

        bytes32 original = vault.paymentDigest(recipient, 0.1 ether, 0, expiry);
        vm.chainId(block.chainid + 1);
        assertNotEq(original, vault.paymentDigest(recipient, 0.1 ether, 0, expiry));
    }

    function testReplayIsBlockedByNonce() public {
        uint256 value = 0.1 ether;
        uint256 expiry = block.timestamp + 1 days;
        bytes memory sig = _sig(4);
        _mockPayment(recipient, value, expiry, sig, true);
        vm.prank(owner);
        vault.executePayment(recipient, value, expiry, sig);
        _mock(KEY, vault.paymentDigest(recipient, value, 1, expiry), sig, false);
        vm.expectRevert(InterlockVaultV2.InvalidPQAuthorization.selector);
        vm.prank(owner);
        vault.executePayment(recipient, value, expiry, sig);
    }

    function testExpiryZeroBalanceAndSignatureLengthChecks() public {
        bytes memory sig = _sig(5);
        vm.expectRevert(InterlockVaultV2.AuthorizationExpired.selector);
        vm.prank(owner);
        vault.executePayment(recipient, 0.1 ether, block.timestamp - 1, sig);
        vm.expectRevert(InterlockVaultV2.ZeroAmount.selector);
        vm.prank(owner);
        vault.executePayment(recipient, 0, block.timestamp + 1 days, sig);
        vm.expectRevert(InterlockVaultV2.ZeroRecipient.selector);
        vm.prank(owner);
        vault.executePayment(payable(address(0)), 0.1 ether, block.timestamp + 1 days, sig);
        vm.expectRevert(abi.encodeWithSelector(InterlockVaultV2.InvalidPQSignatureLength.selector, 1));
        vm.prank(owner);
        vault.executePayment(recipient, 0.1 ether, block.timestamp + 1 days, new bytes(1));
        vm.expectRevert(InterlockVaultV2.InsufficientBalance.selector);
        vm.prank(owner);
        vault.executePayment(recipient, 2 ether, block.timestamp + 1 days, sig);
    }

    function testNativeTransferFailureRollsBackNonceAndBalance() public {
        RejectNativeTransferV2 rejector = new RejectNativeTransferV2();
        uint256 beforeBalance = address(vault).balance;
        uint256 expiry = block.timestamp + 1 days;
        bytes memory sig = _sig(6);
        _mockPayment(payable(address(rejector)), 0.1 ether, expiry, sig, true);
        vm.expectRevert(InterlockVaultV2.NativeTransferFailed.selector);
        vm.prank(owner);
        vault.executePayment(payable(address(rejector)), 0.1 ether, expiry, sig);
        assertEq(vault.nonce(), 0);
        assertEq(address(vault).balance, beforeBalance);
    }

    function testReentrancyIsBlocked() public {
        ReentrantRecipientV2 helper = new ReentrantRecipientV2();
        helper.deploy(KEY);
        vm.deal(address(helper), 1 ether);
        helper.fund(1 ether);
        uint256 expiry = block.timestamp + 1 days;
        bytes memory sig = _sig(7);
        InterlockVaultV2 helperVault = helper.vault();
        _mock(KEY, helperVault.paymentDigest(payable(address(helper)), 0.1 ether, 0, expiry), sig, true);
        helper.execute(0.1 ether, expiry, sig);
        assertTrue(helper.attempted());
        assertEq(helper.reason(), abi.encodeWithSelector(InterlockVaultV2.Reentrancy.selector));
        assertEq(helperVault.nonce(), 1);
    }

    function testRotationRequiresOldAndNewProof() public {
        uint256 expiry = block.timestamp + 1 days;
        bytes memory oldSig = _sig(8);
        bytes memory newSig = _sig(9);
        _mockRotation(KEY, NEW_KEY, expiry, oldSig, newSig);
        vm.prank(owner);
        vault.rotatePQKey(NEW_KEY, expiry, oldSig, newSig);
        assertEq(vault.pqPublicKey(), NEW_KEY);
        assertEq(vault.nonce(), 1);

        bytes32 digest = vault.rotationDigest(NEW_KEY, keccak256("third"), vault.nonce(), expiry);
        _mock(NEW_KEY, digest, _sig(10), false);
        vm.expectRevert(InterlockVaultV2.InvalidPQAuthorization.selector);
        vm.prank(owner);
        vault.rotatePQKey(keccak256("third"), expiry, _sig(11), _sig(10));
    }

    function testRotationCannotUseOnlyOwnerOrOnlyNewKey() public {
        uint256 expiry = block.timestamp + 1 days;
        bytes memory oldSig = _sig(12);
        bytes memory newSig = _sig(13);
        bytes32 digest = vault.rotationDigest(KEY, NEW_KEY, vault.nonce(), expiry);
        _mock(KEY, digest, oldSig, false);
        vm.expectRevert(InterlockVaultV2.InvalidPQAuthorization.selector);
        vm.prank(owner);
        vault.rotatePQKey(NEW_KEY, expiry, oldSig, newSig);
        _mock(KEY, digest, oldSig, true);
        _mock(NEW_KEY, digest, newSig, false);
        vm.expectRevert(InterlockVaultV2.InvalidPQAuthorization.selector);
        vm.prank(owner);
        vault.rotatePQKey(NEW_KEY, expiry, oldSig, newSig);
    }

    function testRecoveryRequestDoesNotChangeKeyAndRequiresDelay() public {
        vm.prank(owner);
        vault.requestPQRecovery(NEW_KEY);
        assertEq(vault.pqPublicKey(), KEY);
        assertEq(vault.pendingPQKey(), NEW_KEY);
        assertEq(vault.recoveryReadyAt(), block.timestamp + 3 days);
        uint256 expiry = block.timestamp + 1 days;
        bytes memory sig = _sig(14);
        _mockPayment(recipient, 0.1 ether, expiry, sig, true);
        vm.prank(owner);
        vault.executePayment(recipient, 0.1 ether, expiry, sig);
        bytes32 digest = vault.recoveryActivationDigest(NEW_KEY, 0, vault.recoveryReadyAt(), expiry);
        _mock(NEW_KEY, digest, _sig(15), true);
        vm.expectRevert(InterlockVaultV2.RecoveryNotReady.selector);
        vm.prank(owner);
        vault.activatePQRecovery(expiry, _sig(15));
    }

    function testRotationIsBlockedWhileRecoveryIsPending() public {
        vm.prank(owner);
        vault.requestPQRecovery(NEW_KEY);
        vm.expectRevert(InterlockVaultV2.RecoveryAlreadyPending.selector);
        vm.prank(owner);
        vault.rotatePQKey(keccak256("other-key"), block.timestamp + 1 days, _sig(22), _sig(23));
    }

    function testOldKeyCanCancelPendingRecovery() public {
        vm.prank(owner);
        vault.requestPQRecovery(NEW_KEY);
        uint256 expiry = block.timestamp + 1 days;
        bytes memory sig = _sig(16);
        bytes32 digest = vault.recoveryCancelDigest(NEW_KEY, 0, vault.recoveryReadyAt(), expiry);
        _mock(KEY, digest, sig, true);
        vm.prank(owner);
        vault.cancelPQRecovery(expiry, sig);
        assertEq(vault.pendingPQKey(), bytes32(0));
        assertEq(vault.recoveryReadyAt(), 0);
        assertEq(vault.pqPublicKey(), KEY);
    }

    function testRecoveryActivationNeedsNewProofAndThenInvalidatesOldKey() public {
        vm.prank(owner);
        vault.requestPQRecovery(NEW_KEY);
        vm.warp(vault.recoveryReadyAt());
        uint256 expiry = block.timestamp + 1 days;
        bytes memory sig = _sig(17);
        bytes32 digest = vault.recoveryActivationDigest(NEW_KEY, 0, vault.recoveryReadyAt(), expiry);
        _mock(NEW_KEY, digest, sig, false);
        vm.expectRevert(InterlockVaultV2.InvalidPQAuthorization.selector);
        vm.prank(owner);
        vault.activatePQRecovery(expiry, sig);
        _mock(NEW_KEY, digest, sig, true);
        vm.prank(owner);
        vault.activatePQRecovery(expiry, sig);
        assertEq(vault.pqPublicKey(), NEW_KEY);
        assertEq(vault.pendingPQKey(), bytes32(0));
        assertEq(vault.nonce(), 1);

        bytes memory paymentSig = _sig(18);
        _mock(KEY, vault.paymentDigest(recipient, 0.1 ether, 1, expiry), paymentSig, true);
        vm.expectRevert(InterlockVaultV2.InvalidPQAuthorization.selector);
        vm.prank(owner);
        vault.executePayment(recipient, 0.1 ether, expiry, paymentSig);
    }

    function testRecoveryIsOwnerBoundAndCannotActivateBeforeDelay() public {
        vm.expectRevert(InterlockVaultV2.NotOwner.selector);
        vm.prank(attacker);
        vault.requestPQRecovery(NEW_KEY);
        vm.prank(owner);
        vault.requestPQRecovery(NEW_KEY);
        vm.expectRevert(InterlockVaultV2.RecoveryAlreadyPending.selector);
        vm.prank(owner);
        vault.requestPQRecovery(keccak256("another"));
    }

    function testMalformedVerifierReturnIsRejected() public {
        uint256 expiry = block.timestamp + 1 days;
        bytes memory sig = _sig(19);
        bytes32 digest = vault.paymentDigest(recipient, 0.1 ether, 0, expiry);
        bytes memory callData = abi.encodeWithSelector(
            IArcPQVerifierV2.verifySlhDsaSha2128s.selector, abi.encodePacked(KEY), abi.encodePacked(digest), sig
        );
        vm.mockCall(VERIFIER, callData, hex"01");
        vm.expectRevert(InterlockVaultV2.InvalidPQAuthorization.selector);
        vm.prank(owner);
        vault.executePayment(recipient, 0.1 ether, expiry, sig);
    }

    function testOwnerAndKeyCannotBeChangedByArbitraryCalls() public {
        assertEq(vault.owner(), owner);
        assertEq(vault.pqPublicKey(), KEY);
        vm.expectRevert(InterlockVaultV2.NotOwner.selector);
        vm.prank(attacker);
        vault.rotatePQKey(NEW_KEY, block.timestamp + 1 days, _sig(20), _sig(21));
    }
}
