// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {InterlockVault, IArcPQVerifier} from "../src/InterlockVault.sol";

contract RejectNativeTransfer {
    receive() external payable {
        revert();
    }
}

contract ReentrantOwnerRecipient {
    InterlockVault public vault;

    uint256 private _amount;
    uint256 private _deadline;
    bytes private _signature;

    bool public reentryAttempted;
    bytes public reentryReason;

    function deploy(bytes32 key) external {
        vault = new InterlockVault(key);
    }

    function fund(uint256 amount) external {
        vault.deposit{value: amount}();
    }

    function execute(uint256 amount, uint256 deadline, bytes calldata signature) external {
        _amount = amount;
        _deadline = deadline;
        _signature = signature;

        vault.executePayment(payable(address(this)), amount, deadline, signature);
    }

    receive() external payable {
        if (reentryAttempted) return;

        reentryAttempted = true;

        try vault.executePayment(payable(address(this)), _amount, _deadline, _signature) {
        // A successful reentrant call would be a security failure.
        }
        catch (bytes memory reason) {
            reentryReason = reason;
        }
    }
}

contract InterlockVaultTest is Test {
    address internal constant ARC_PQ_VERIFIER = 0x1800000000000000000000000000000000000004;

    bytes32 internal constant PQ_KEY = keccak256("interlock-test-pq-key");

    InterlockVault internal vault;

    address internal owner;
    address internal attacker;
    address payable internal recipient;

    function setUp() public {
        owner = makeAddr("owner");
        attacker = makeAddr("attacker");
        recipient = payable(makeAddr("recipient"));

        vm.deal(owner, 10 ether);

        vm.prank(owner);
        vault = new InterlockVault(PQ_KEY);

        vm.prank(owner);
        vault.deposit{value: 1 ether}();
    }

    function _signature(uint8 marker) internal pure returns (bytes memory sig) {
        sig = new bytes(7856);
        sig[0] = bytes1(marker);
    }

    function _mockPaymentAuthorization(
        address payable targetRecipient,
        uint256 amount,
        uint256 deadline,
        bytes memory signature,
        bool verified
    ) internal {
        bytes32 digest = vault.paymentDigest(targetRecipient, amount, vault.nonce(), deadline);

        bytes memory callData = abi.encodeWithSelector(
            IArcPQVerifier.verifySlhDsaSha2128s.selector, abi.encodePacked(PQ_KEY), abi.encodePacked(digest), signature
        );

        vm.mockCall(ARC_PQ_VERIFIER, callData, abi.encode(verified));
    }

    function testConstructorRejectsZeroPQKey() public {
        vm.expectRevert(InterlockVault.InvalidPQKey.selector);

        vm.prank(owner);
        new InterlockVault(bytes32(0));
    }

    function testDepositWorks() public {
        address depositor = makeAddr("depositor");
        vm.deal(depositor, 1 ether);

        vm.prank(depositor);
        vault.deposit{value: 0.25 ether}();

        assertEq(address(vault).balance, 1.25 ether);
    }

    function testValidHybridPaymentExecutes() public {
        uint256 amount = 0.1 ether;
        uint256 deadline = block.timestamp + 1 days;
        bytes memory signature = _signature(1);

        _mockPaymentAuthorization(recipient, amount, deadline, signature, true);

        uint256 recipientBefore = recipient.balance;

        vm.prank(owner);
        vault.executePayment(recipient, amount, deadline, signature);

        assertEq(vault.nonce(), 1);
        assertEq(recipient.balance, recipientBefore + amount);
        assertEq(address(vault).balance, 0.9 ether);
    }

    function testWrongWalletCannotExecute() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory signature = _signature(2);

        vm.expectRevert(InterlockVault.NotOwner.selector);

        vm.prank(attacker);
        vault.executePayment(recipient, 0.1 ether, deadline, signature);
    }

    function testExpiredAuthorizationFails() public {
        vm.warp(1_000_000);

        uint256 deadline = block.timestamp - 1;
        bytes memory signature = _signature(3);

        vm.expectRevert(InterlockVault.AuthorizationExpired.selector);

        vm.prank(owner);
        vault.executePayment(recipient, 0.1 ether, deadline, signature);
    }

    function testWrongSignatureLengthFails() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory badSignature = new bytes(1);

        vm.expectRevert(abi.encodeWithSelector(InterlockVault.InvalidPQSignatureLength.selector, 1));

        vm.prank(owner);
        vault.executePayment(recipient, 0.1 ether, deadline, badSignature);
    }

    function testTamperedAmountFails() public {
        uint256 signedAmount = 0.1 ether;
        uint256 tamperedAmount = 0.2 ether;
        uint256 deadline = block.timestamp + 1 days;
        bytes memory signature = _signature(4);

        _mockPaymentAuthorization(recipient, signedAmount, deadline, signature, true);

        vm.expectRevert(InterlockVault.InvalidPQAuthorization.selector);

        vm.prank(owner);
        vault.executePayment(recipient, tamperedAmount, deadline, signature);
    }

    function testReplayFails() public {
        uint256 amount = 0.1 ether;
        uint256 deadline = block.timestamp + 1 days;
        bytes memory signature = _signature(5);

        _mockPaymentAuthorization(recipient, amount, deadline, signature, true);

        vm.prank(owner);
        vault.executePayment(recipient, amount, deadline, signature);

        assertEq(vault.nonce(), 1);

        vm.expectRevert(InterlockVault.InvalidPQAuthorization.selector);

        vm.prank(owner);
        vault.executePayment(recipient, amount, deadline, signature);
    }

    function testVerifierFalseFails() public {
        uint256 amount = 0.1 ether;
        uint256 deadline = block.timestamp + 1 days;
        bytes memory signature = _signature(6);

        _mockPaymentAuthorization(recipient, amount, deadline, signature, false);

        vm.expectRevert(InterlockVault.InvalidPQAuthorization.selector);

        vm.prank(owner);
        vault.executePayment(recipient, amount, deadline, signature);
    }

    function testInsufficientBalanceFails() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory signature = _signature(7);

        vm.expectRevert(InterlockVault.InsufficientBalance.selector);

        vm.prank(owner);
        vault.executePayment(recipient, 2 ether, deadline, signature);
    }

    function testTamperedRecipientFails() public {
        address payable signedRecipient = payable(makeAddr("signedRecipient"));

        address payable tamperedRecipient = payable(makeAddr("tamperedRecipient"));

        uint256 amount = 0.1 ether;
        uint256 deadline = block.timestamp + 1 days;
        bytes memory signature = _signature(8);

        _mockPaymentAuthorization(signedRecipient, amount, deadline, signature, true);

        vm.expectRevert(InterlockVault.InvalidPQAuthorization.selector);

        vm.prank(owner);
        vault.executePayment(tamperedRecipient, amount, deadline, signature);
    }

    function testAuthorizationCannotBeUsedOnAnotherVault() public {
        uint256 amount = 0.1 ether;
        uint256 deadline = block.timestamp + 1 days;
        bytes memory signature = _signature(9);

        _mockPaymentAuthorization(recipient, amount, deadline, signature, true);

        vm.prank(owner);
        InterlockVault secondVault = new InterlockVault(PQ_KEY);

        vm.deal(address(secondVault), 1 ether);

        vm.expectRevert(InterlockVault.InvalidPQAuthorization.selector);

        vm.prank(owner);
        secondVault.executePayment(recipient, amount, deadline, signature);
    }

    function testPQKeyRotationWorks() public {
        bytes32 newKey = keccak256("interlock-new-pq-key");

        uint256 deadline = block.timestamp + 1 days;
        uint256 authorizationNonce = vault.nonce();

        bytes memory currentSignature = _signature(10);
        bytes memory newSignature = _signature(11);

        bytes32 digest = vault.rotationDigest(PQ_KEY, newKey, authorizationNonce, deadline);

        bytes memory currentCallData = abi.encodeWithSelector(
            IArcPQVerifier.verifySlhDsaSha2128s.selector,
            abi.encodePacked(PQ_KEY),
            abi.encodePacked(digest),
            currentSignature
        );

        bytes memory newCallData = abi.encodeWithSelector(
            IArcPQVerifier.verifySlhDsaSha2128s.selector,
            abi.encodePacked(newKey),
            abi.encodePacked(digest),
            newSignature
        );

        vm.mockCall(ARC_PQ_VERIFIER, currentCallData, abi.encode(true));

        vm.mockCall(ARC_PQ_VERIFIER, newCallData, abi.encode(true));

        vm.prank(owner);
        vault.rotatePQKey(newKey, deadline, currentSignature, newSignature);

        assertEq(vault.pqPublicKey(), newKey);
        assertEq(vault.nonce(), 1);
    }

    function testRotationFailsWithoutCurrentKeyApproval() public {
        bytes32 newKey = keccak256("interlock-new-pq-key");

        uint256 deadline = block.timestamp + 1 days;

        bytes memory currentSignature = _signature(12);
        bytes memory newSignature = _signature(13);

        bytes32 digest = vault.rotationDigest(PQ_KEY, newKey, vault.nonce(), deadline);

        bytes memory currentCallData = abi.encodeWithSelector(
            IArcPQVerifier.verifySlhDsaSha2128s.selector,
            abi.encodePacked(PQ_KEY),
            abi.encodePacked(digest),
            currentSignature
        );

        vm.mockCall(ARC_PQ_VERIFIER, currentCallData, abi.encode(false));

        vm.expectRevert(InterlockVault.InvalidPQAuthorization.selector);

        vm.prank(owner);
        vault.rotatePQKey(newKey, deadline, currentSignature, newSignature);
    }

    function testRotationFailsWithoutNewKeyProof() public {
        bytes32 newKey = keccak256("interlock-new-pq-key");

        uint256 deadline = block.timestamp + 1 days;

        bytes memory currentSignature = _signature(14);
        bytes memory newSignature = _signature(15);

        bytes32 digest = vault.rotationDigest(PQ_KEY, newKey, vault.nonce(), deadline);

        bytes memory currentCallData = abi.encodeWithSelector(
            IArcPQVerifier.verifySlhDsaSha2128s.selector,
            abi.encodePacked(PQ_KEY),
            abi.encodePacked(digest),
            currentSignature
        );

        bytes memory newCallData = abi.encodeWithSelector(
            IArcPQVerifier.verifySlhDsaSha2128s.selector,
            abi.encodePacked(newKey),
            abi.encodePacked(digest),
            newSignature
        );

        vm.mockCall(ARC_PQ_VERIFIER, currentCallData, abi.encode(true));

        vm.mockCall(ARC_PQ_VERIFIER, newCallData, abi.encode(false));

        vm.expectRevert(InterlockVault.InvalidPQAuthorization.selector);

        vm.prank(owner);
        vault.rotatePQKey(newKey, deadline, currentSignature, newSignature);
    }

    function testZeroRecipientFails() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory signature = _signature(16);

        vm.expectRevert(InterlockVault.ZeroRecipient.selector);

        vm.prank(owner);
        vault.executePayment(payable(address(0)), 0.1 ether, deadline, signature);
    }

    function testZeroAmountFails() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory signature = _signature(17);

        vm.expectRevert(InterlockVault.ZeroAmount.selector);

        vm.prank(owner);
        vault.executePayment(recipient, 0, deadline, signature);
    }

    function testZeroPQKeyRotationFails() public {
        uint256 deadline = block.timestamp + 1 days;

        vm.expectRevert(InterlockVault.InvalidPQKey.selector);

        vm.prank(owner);
        vault.rotatePQKey(bytes32(0), deadline, _signature(18), _signature(19));
    }

    function testSamePQKeyRotationFails() public {
        uint256 deadline = block.timestamp + 1 days;

        vm.expectRevert(InterlockVault.SamePQKey.selector);

        vm.prank(owner);
        vault.rotatePQKey(PQ_KEY, deadline, _signature(20), _signature(21));
    }

    function testDeadlineEqualCurrentTimestampIsValid() public {
        uint256 amount = 0.1 ether;
        uint256 deadline = block.timestamp;

        bytes memory signature = _signature(22);

        _mockPaymentAuthorization(recipient, amount, deadline, signature, true);

        vm.prank(owner);
        vault.executePayment(recipient, amount, deadline, signature);

        assertEq(vault.nonce(), 1);
    }

    function testNativeTransferFailureRevertsEverything() public {
        RejectNativeTransfer rejector = new RejectNativeTransfer();

        uint256 amount = 0.1 ether;
        uint256 deadline = block.timestamp + 1 days;

        bytes memory signature = _signature(23);

        _mockPaymentAuthorization(payable(address(rejector)), amount, deadline, signature, true);

        uint256 balanceBefore = address(vault).balance;

        vm.expectRevert(InterlockVault.NativeTransferFailed.selector);

        vm.prank(owner);
        vault.executePayment(payable(address(rejector)), amount, deadline, signature);

        assertEq(vault.nonce(), 0);
        assertEq(address(vault).balance, balanceBefore);
    }

    function testReentrancyIsBlocked() public {
        bytes32 key = keccak256("reentrant-owner-pq-key");

        ReentrantOwnerRecipient helper = new ReentrantOwnerRecipient();

        helper.deploy(key);

        InterlockVault reentrantVault = helper.vault();

        vm.deal(address(helper), 1 ether);
        helper.fund(1 ether);

        uint256 amount = 0.1 ether;
        uint256 deadline = block.timestamp + 1 days;

        bytes memory signature = _signature(24);

        bytes32 digest =
            reentrantVault.paymentDigest(payable(address(helper)), amount, reentrantVault.nonce(), deadline);

        bytes memory callData = abi.encodeWithSelector(
            IArcPQVerifier.verifySlhDsaSha2128s.selector, abi.encodePacked(key), abi.encodePacked(digest), signature
        );

        vm.mockCall(ARC_PQ_VERIFIER, callData, abi.encode(true));

        helper.execute(amount, deadline, signature);

        assertTrue(helper.reentryAttempted());

        assertEq(helper.reentryReason(), abi.encodeWithSelector(InterlockVault.Reentrancy.selector));

        assertEq(reentrantVault.nonce(), 1);
        assertEq(address(reentrantVault).balance, 0.9 ether);
    }

    function testPaymentDigestIsBoundToChain() public {
        uint256 amount = 0.1 ether;
        uint256 deadline = block.timestamp + 1 days;

        bytes32 originalDigest = vault.paymentDigest(recipient, amount, vault.nonce(), deadline);

        uint256 originalChainId = block.chainid;

        vm.chainId(originalChainId + 1);

        bytes32 otherChainDigest = vault.paymentDigest(recipient, amount, vault.nonce(), deadline);

        assertNotEq(originalDigest, otherChainDigest);
    }

    function testStaleRotationAuthorizationFailsAfterNonceChanges() public {
        bytes32 newKey = keccak256("stale-rotation-new-key");

        uint256 deadline = block.timestamp + 1 days;

        bytes memory currentSignature = _signature(25);

        bytes memory newSignature = _signature(26);

        bytes32 staleDigest = vault.rotationDigest(PQ_KEY, newKey, vault.nonce(), deadline);

        bytes memory staleCurrentCall = abi.encodeWithSelector(
            IArcPQVerifier.verifySlhDsaSha2128s.selector,
            abi.encodePacked(PQ_KEY),
            abi.encodePacked(staleDigest),
            currentSignature
        );

        bytes memory staleNewCall = abi.encodeWithSelector(
            IArcPQVerifier.verifySlhDsaSha2128s.selector,
            abi.encodePacked(newKey),
            abi.encodePacked(staleDigest),
            newSignature
        );

        vm.mockCall(ARC_PQ_VERIFIER, staleCurrentCall, abi.encode(true));

        vm.mockCall(ARC_PQ_VERIFIER, staleNewCall, abi.encode(true));

        bytes memory paymentSignature = _signature(27);

        _mockPaymentAuthorization(recipient, 0.1 ether, deadline, paymentSignature, true);

        vm.prank(owner);
        vault.executePayment(recipient, 0.1 ether, deadline, paymentSignature);

        assertEq(vault.nonce(), 1);

        vm.expectRevert(InterlockVault.InvalidPQAuthorization.selector);

        vm.prank(owner);
        vault.rotatePQKey(newKey, deadline, currentSignature, newSignature);
    }

    function testMalformedVerifierReturnFails() public {
        uint256 amount = 0.1 ether;
        uint256 deadline = block.timestamp + 1 days;

        bytes memory signature = _signature(28);

        bytes32 digest = vault.paymentDigest(recipient, amount, vault.nonce(), deadline);

        bytes memory callData = abi.encodeWithSelector(
            IArcPQVerifier.verifySlhDsaSha2128s.selector, abi.encodePacked(PQ_KEY), abi.encodePacked(digest), signature
        );

        vm.mockCall(ARC_PQ_VERIFIER, callData, hex"01");

        vm.expectRevert(InterlockVault.InvalidPQAuthorization.selector);

        vm.prank(owner);
        vault.executePayment(recipient, amount, deadline, signature);
    }
}
