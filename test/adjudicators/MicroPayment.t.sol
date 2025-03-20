// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "lib/forge-std/src/Test.sol";
import {MicroPayment} from "../../src/adjudicators/MicroPayment.sol";
import {Custody} from "../../src/Custody.sol";
import "../../src/interfaces/Types.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract MicroPaymentTest is Test {
    MicroPayment public adjudicator;
    Custody public custody;
    MockERC20 public token;

    // Test addresses
    address public host; // Account with private key 1
    address public guest; // Account with private key 2

    // Private keys for signing
    uint256 private hostKey = 0x1;
    uint256 private guestKey = 0x2;

    // Channel constants
    uint64 private constant CHANNEL_NONCE = 1;
    uint256 private constant INITIAL_DEPOSIT = 100 * 10 ** 18;

    function setUp() public {
        // Deploy contracts
        adjudicator = new MicroPayment();
        custody = new Custody();
        token = new MockERC20("Test Token", "TST", 18);

        // Set up test accounts and give them tokens
        host = vm.addr(hostKey);
        guest = vm.addr(guestKey);
        vm.label(host, "Host");
        vm.label(guest, "Guest");

        token.mint(host, INITIAL_DEPOSIT);
        token.mint(guest, INITIAL_DEPOSIT);

        vm.prank(host);
        token.approve(address(custody), INITIAL_DEPOSIT);

        vm.prank(guest);
        token.approve(address(custody), INITIAL_DEPOSIT);
    }

    function test_OpenChannel() public {
        // Create channel config
        address[] memory participants = new address[](2);
        participants[0] = host;
        participants[1] = guest;

        Channel memory channel =
            Channel({participants: participants, adjudicator: address(adjudicator), nonce: CHANNEL_NONCE});

        // Host opens the channel
        vm.prank(host);
        Asset memory hostDeposit = Asset({token: address(token), amount: INITIAL_DEPOSIT});

        bytes32 channelId = custody.open(channel, hostDeposit);

        // Guest joins the channel
        vm.prank(guest);
        Asset memory guestDeposit = Asset({
            token: address(token),
            amount: 0 // Guest doesn't need to deposit for a payment channel
        });

        custody.open(channel, guestDeposit);

        // Verify channel opened and tokens transferred
        assertEq(token.balanceOf(address(custody)), INITIAL_DEPOSIT);
        assertEq(token.balanceOf(host), 0);
    }

    function test_AdjudicateVoucher() public {
        // Create a voucher off-chain
        uint64 version = 1;
        uint256 amount = 10 ether;

        // Create channel data
        address[] memory participants = new address[](2);
        participants[0] = host;
        participants[1] = guest;

        Channel memory channel =
            Channel({participants: participants, adjudicator: address(adjudicator), nonce: CHANNEL_NONCE});

        // Create voucher
        MicroPayment.Voucher memory voucher =
            MicroPayment.Voucher({payment: Asset({token: address(token), amount: amount}), version: version});

        // Create signed voucher
        MicroPayment.SignedVoucher memory signedVoucher = createSignedVoucher(channel, voucher, hostKey);
        bytes memory encodedVoucher = abi.encode(signedVoucher);

        // Create state data
        State memory stateData;
        stateData.data = encodedVoucher;
        stateData.outcome = new Asset[](2);

        // Adjudicate the voucher
        (bool valid, Asset[] memory outcome) = adjudicator.adjudicate(
            channel,
            stateData,
            new State[](0) // No previous state
        );

        assertTrue(valid);
        assertEq(outcome[1].token, address(token)); // Guest payment token
        assertEq(outcome[1].amount, amount); // Guest payment amount
    }

    function test_AdjudicateWithPreviousVoucher() public {
        // Create channel data
        address[] memory participants = new address[](2);
        participants[0] = host;
        participants[1] = guest;

        Channel memory channel =
            Channel({participants: participants, adjudicator: address(adjudicator), nonce: CHANNEL_NONCE});

        // Create first voucher
        uint64 version1 = 1;
        uint256 amount1 = 10 ether;

        MicroPayment.Voucher memory voucher1 =
            MicroPayment.Voucher({payment: Asset({token: address(token), amount: amount1}), version: version1});

        MicroPayment.SignedVoucher memory signedVoucher1 = createSignedVoucher(channel, voucher1, hostKey);
        bytes memory encodedVoucher1 = abi.encode(signedVoucher1);

        // Create second voucher with higher version
        uint64 version2 = 2;
        uint256 amount2 = 20 ether;

        MicroPayment.Voucher memory voucher2 =
            MicroPayment.Voucher({payment: Asset({token: address(token), amount: amount2}), version: version2});

        MicroPayment.SignedVoucher memory signedVoucher2 = createSignedVoucher(channel, voucher2, hostKey);
        bytes memory encodedVoucher2 = abi.encode(signedVoucher2);

        // Prepare proofs array with previous voucher
        State[] memory proofs = new State[](1);
        proofs[0].data = encodedVoucher1;
        proofs[0].outcome = new Asset[](2);

        // Create state data for second voucher
        State memory stateData;
        stateData.data = encodedVoucher2;
        stateData.outcome = new Asset[](2);

        // Adjudicate the second voucher
        (bool valid, Asset[] memory outcome) = adjudicator.adjudicate(channel, stateData, proofs);

        assertTrue(valid);
        assertEq(outcome[1].token, address(token)); // Guest payment token
        assertEq(outcome[1].amount, amount2); // Guest payment amount
    }

    function test_RejectLowerVersionVoucher() public {
        // Create channel data
        address[] memory participants = new address[](2);
        participants[0] = host;
        participants[1] = guest;

        Channel memory channel =
            Channel({participants: participants, adjudicator: address(adjudicator), nonce: CHANNEL_NONCE});

        // Create first voucher with higher version
        uint64 version1 = 2;
        uint256 amount1 = 20 ether;

        MicroPayment.Voucher memory voucher1 =
            MicroPayment.Voucher({payment: Asset({token: address(token), amount: amount1}), version: version1});

        MicroPayment.SignedVoucher memory signedVoucher1 = createSignedVoucher(channel, voucher1, hostKey);
        bytes memory encodedVoucher1 = abi.encode(signedVoucher1);

        // Create second voucher with lower version
        uint64 version2 = 1;
        uint256 amount2 = 10 ether;

        MicroPayment.Voucher memory voucher2 =
            MicroPayment.Voucher({payment: Asset({token: address(token), amount: amount2}), version: version2});

        MicroPayment.SignedVoucher memory signedVoucher2 = createSignedVoucher(channel, voucher2, hostKey);
        bytes memory encodedVoucher2 = abi.encode(signedVoucher2);

        // Prepare proofs array with previous voucher
        State[] memory proofs = new State[](1);
        proofs[0].data = encodedVoucher1;
        proofs[0].outcome = new Asset[](2);

        // Create state data for second voucher
        State memory stateData;
        stateData.data = encodedVoucher2;
        stateData.outcome = new Asset[](2);

        // Adjudicate should revert with VersionNotHigher
        vm.expectRevert(MicroPayment.VersionNotHigher.selector);
        adjudicator.adjudicate(channel, stateData, proofs);
    }

    function test_RejectInvalidSignature() public {
        // Create channel data
        address[] memory participants = new address[](2);
        participants[0] = host;
        participants[1] = guest;

        Channel memory channel =
            Channel({participants: participants, adjudicator: address(adjudicator), nonce: CHANNEL_NONCE});

        // Create voucher
        uint64 version = 1;
        uint256 amount = 10 ether;

        MicroPayment.Voucher memory voucher =
            MicroPayment.Voucher({payment: Asset({token: address(token), amount: amount}), version: version});

        // Sign with guest key instead of host key (invalid)
        MicroPayment.SignedVoucher memory signedVoucher = createSignedVoucher(channel, voucher, guestKey);
        bytes memory encodedVoucher = abi.encode(signedVoucher);

        // Create state data for voucher
        State memory stateData;
        stateData.data = encodedVoucher;
        stateData.outcome = new Asset[](2);

        // Adjudicate should revert with InvalidSignature
        vm.expectRevert(MicroPayment.InvalidSignature.selector);
        adjudicator.adjudicate(channel, stateData, new State[](0));
    }

    function test_CloseWithMutualSignatures() public {
        // First open the channel
        address[] memory participants = new address[](2);
        participants[0] = host;
        participants[1] = guest;

        Channel memory channel =
            Channel({participants: participants, adjudicator: address(adjudicator), nonce: CHANNEL_NONCE});

        // Host opens the channel
        vm.prank(host);
        Asset memory hostDeposit = Asset({token: address(token), amount: INITIAL_DEPOSIT});

        bytes32 channelId = custody.open(channel, hostDeposit);

        // Guest joins the channel
        vm.prank(guest);
        Asset memory guestDeposit = Asset({token: address(token), amount: 0});

        custody.open(channel, guestDeposit);

        // Create voucher with 30 ether payment
        uint64 version = 1;
        uint256 amount = 30 ether;

        MicroPayment.Voucher memory voucher =
            MicroPayment.Voucher({payment: Asset({token: address(token), amount: amount}), version: version});

        // Create signed voucher
        MicroPayment.SignedVoucher memory signedVoucher = createSignedVoucher(channel, voucher, hostKey);
        bytes memory encodedVoucher = abi.encode(signedVoucher);

        // Create state data
        State memory stateData;
        stateData.data = encodedVoucher;
        stateData.outcome = new Asset[](2);
        stateData.outcome[0] = Asset({token: address(token), amount: INITIAL_DEPOSIT - amount});
        stateData.outcome[1] = Asset({token: address(token), amount: amount});

        // Both parties sign the same state for close
        bytes32 closeMessageHash = keccak256(abi.encode(stateData));

        // Host signs
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(hostKey, closeMessageHash);
        Signature memory hostSig = Signature({v: v1, r: r1, s: s1});

        // Guest signs
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(guestKey, closeMessageHash);
        Signature memory guestSig = Signature({v: v2, r: r2, s: s2});

        Signature[2] memory signatures = [hostSig, guestSig];

        // Close the channel
        vm.prank(guest);
        custody.close(channelId, stateData, signatures);

        // Verify funds distribution
        assertEq(token.balanceOf(host), INITIAL_DEPOSIT - amount);
        assertEq(token.balanceOf(guest), INITIAL_DEPOSIT + amount);
    }

    function test_ChallengeAndReclaim() public {
        // First open the channel
        address[] memory participants = new address[](2);
        participants[0] = host;
        participants[1] = guest;

        Channel memory channel =
            Channel({participants: participants, adjudicator: address(adjudicator), nonce: CHANNEL_NONCE});

        // Host opens the channel
        vm.prank(host);
        Asset memory hostDeposit = Asset({token: address(token), amount: INITIAL_DEPOSIT});

        bytes32 channelId = custody.open(channel, hostDeposit);

        // Guest joins the channel
        vm.prank(guest);
        Asset memory guestDeposit = Asset({token: address(token), amount: 0});

        custody.open(channel, guestDeposit);

        // Create voucher with 40 ether payment
        uint64 version = 1;
        uint256 amount = 40 ether;

        MicroPayment.Voucher memory voucher =
            MicroPayment.Voucher({payment: Asset({token: address(token), amount: amount}), version: version});

        // Create signed voucher
        MicroPayment.SignedVoucher memory signedVoucher = createSignedVoucher(channel, voucher, hostKey);
        bytes memory encodedVoucher = abi.encode(signedVoucher);

        // Create state data
        State memory stateData;
        stateData.data = encodedVoucher;
        stateData.outcome = new Asset[](2);
        stateData.outcome[0] = Asset({token: address(token), amount: INITIAL_DEPOSIT - amount});
        stateData.outcome[1] = Asset({token: address(token), amount: amount});

        // Guest challenges with the voucher
        vm.prank(guest);
        custody.challenge(channelId, stateData);

        // Fast forward past challenge period
        vm.warp(block.timestamp + 3 days + 1);

        // Guest claims the funds
        vm.prank(guest);
        custody.reclaim(channelId);

        // Verify funds distribution
        assertEq(token.balanceOf(host), INITIAL_DEPOSIT - amount);
        assertEq(token.balanceOf(guest), INITIAL_DEPOSIT + amount);
    }

    // Helper function to create a signed voucher
    function createSignedVoucher(Channel memory channel, MicroPayment.Voucher memory voucher, uint256 privateKey)
        internal
        view
        returns (MicroPayment.SignedVoucher memory)
    {
        // Create hash of just the voucher data for signature verification
        bytes32 stateHash = keccak256(abi.encode(voucher));

        // Sign the hash
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, stateHash);

        // Create the SignedVoucher structure with signature
        MicroPayment.SignedVoucher memory signedVoucher =
            MicroPayment.SignedVoucher({voucher: voucher, signature: Signature({v: v, r: r, s: s})});

        return signedVoucher;
    }
}
