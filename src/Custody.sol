// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IChannel} from "./interfaces/IChannel.sol";
import {IAdjudicator} from "./interfaces/IAdjudicator.sol";
import "./interfaces/Types.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Custody
 * @notice Implementation of IChannel for managing state channels
 */
contract Custody is IChannel {
    // Constants
    uint256 private constant CHALLENGE_PERIOD = 3 days;

    // Errors
    error ChannelNotFound();
    error InvalidParticipants();
    error InvalidCaller();
    error InvalidSignature();
    error InvalidState();
    error InvalidStatus();
    error ChallengeNotExpired();
    error TransferFailed();

    // Channel status
    enum Status {
        VOID,
        PARTIAL, // Partial funding
        OPENED, // Channel fully funded
        CLOSED, // Channel closed
        CHALLENGED // Channel in challenge period

    }

    // Channel metadata
    struct Metadata {
        Channel chan;
        Asset[] outcome;
        Status status;
        uint256 challengeExpire;
        State lastValidState;
    }

    // ChannelId to Metadata mapping
    mapping(bytes32 => Metadata) private channels;

    /**
     * @notice Open or join a channel by depositing assets
     * @param ch Channel configuration
     * @param deposit Assets to deposit by the caller
     * @return channelId Unique identifier for the channel
     */
    // FIXME: if only one party funds, and the other disappears, the funds are stuck and cannot be challenged or reclaimed.
    // FIXME: "calling 'open'" approach PROHIBITS CROSS-CHAIN channels, as it requires BOTH parties to call OPEN on the same chain.
    // To overcome this, a channel should have a mechanism to move from PARTIALLY_FUNDED to OPENED without second party interaction.
    // One way to achieve this is to supply a VALID state proclaiming "FUNDING IS DONE", as it is implemented in Nitro :wink:.
    function open(Channel calldata ch, Asset calldata deposit) external override returns (bytes32 channelId) {
        // Validate participants array length
        if (ch.participants.length != 2) {
            revert InvalidParticipants();
        }

        // Calculate channel identifier
        channelId = keccak256(abi.encode(ch));

        // Get metadata for this channel
        Metadata storage meta = channels[channelId];

        // If channel is new, initialize it
        if (meta.status == Status.VOID) {
            meta.chan = ch;
            meta.outcome = new Asset[](2);
            meta.status = Status.PARTIAL;
        } else if (meta.status != Status.PARTIAL && meta.status != Status.OPENED) {
            revert InvalidStatus();
        }

        // Transfer deposit to this contract
        if (deposit.amount > 0) {
            // TODO: native asset support
            bool success = IERC20(deposit.token).transferFrom(msg.sender, address(this), deposit.amount);

            if (!success) {
                revert TransferFailed();
            }
        }

        // FIXME: there is no execution path that results in Status.PARTIAL
        // Record deposit in outcome based on caller
        if (msg.sender == ch.participants[0]) {
            meta.outcome[0] = deposit;
            // For a payment channel we can immediately mark it OPENED when host deposits
            meta.status = Status.OPENED;
        } else if (msg.sender == ch.participants[1]) {
            meta.outcome[1] = deposit;
            // For guest joining, we need to check if host has already funded
            if (meta.outcome[0].amount > 0) {
                meta.status = Status.OPENED;
            }
        } else {
            revert InvalidCaller();
        }

        return channelId;
    }

    /**
     * @notice Finalize the channel with a mutually signed state
     * @param channelId Unique identifier for the channel
     * @param state The final state signed by both parties
     * @param signatures Array of signatures from both participants
     */
    function close(bytes32 channelId, State calldata state, Signature[2] calldata signatures) external override {
        Metadata storage meta = channels[channelId];

        // Check channel exists and is in the correct state
        if (meta.status != Status.OPENED && meta.status != Status.CHALLENGED) {
            revert InvalidStatus();
        }

        // Verify signatures from both participants
        Channel memory chan = meta.chan;
        bytes32 stateHash = keccak256(abi.encode(state));

        // NOTE: the approach of signing states, that MAY include signatures is interesting.
        // On one hand there is signature duplication (participant sign something that already contains their signature),
        // while on the other hand it differentiates ordinary states and final ones, which removes the need for `isFinal` state field.
        // TODO: this, however, may pose a threat, as it imposes an implicit security requirement for Adjudicator to ALWAYS include signatures alongside meaningful data in State.data
        // This should be done to protect against a situation, when signatures of both parties can be extracted from State.data, and the other data that is left still encodes a VALID state, supported by the Adjudicator.
        if (!verifySignature(chan.participants[0], stateHash, signatures[0])) {
            revert InvalidSignature();
        }

        if (!verifySignature(chan.participants[1], stateHash, signatures[1])) {
            revert InvalidSignature();
        }

        // Use the adjudicator to validate the state and get the outcome
        (bool valid, Asset[] memory outcome) = IAdjudicator(chan.adjudicator).adjudicate(
            chan,
            state,
            new State[](0) // No proofs needed for mutual close
        );

        if (!valid) {
            revert InvalidState();
        }

        // Distribute tokens according to adjudicated outcome
        _distributeAssets(outcome, chan.participants);

        // Mark channel as closed
        meta.status = Status.CLOSED;
    }

    // FIXME: implement `checkpoint` to allow moving from `CHALLENGED` to `OPENED` state

    /**
     * @notice Unilaterally post a state when the other party is uncooperative
     * @param channelId Unique identifier for the channel
     * @param state The latest known valid state
     */
    function challenge(bytes32 channelId, State calldata state) external override {
        Metadata storage meta = channels[channelId];

        // Check channel exists and is in a valid state for challenge
        if (meta.status != Status.OPENED && meta.status != Status.CHALLENGED) {
            revert InvalidStatus();
        }

        Channel memory chan = meta.chan;

        // Verify caller is a participant
        if (msg.sender != chan.participants[0] && msg.sender != chan.participants[1]) {
            revert InvalidCaller();
        }

        // Prepare proofs array including previous state if this is a counter-challenge
        // FIXME: I think proofs are meant to be passed to `challenge` directly
        State[] memory proofs = new State[](0);
        if (meta.status == Status.CHALLENGED) {
            proofs = new State[](1);
            // TODO: imagine parties are already at imaginary turnNum 100, where outcome is not it Bob's favor.
            // Bob challenges with imaginary turnNum 1, it passes. Then, Alice would want to challenge Bob's 1 with state 100.
            // But when doing that, the Adjudicator application will receive the state 100 as candidate and state 1 as proof, which may not be correct.
            // This means that Adjudicator app needs to be able to handle VALID candidates with ANY PREVIOUS VALID state as proof.
            // NOTE: this basically removes the need for turnNumbers (for good case), and moves efforts in unhappy case, which is now harder to support in Adjudicator app.
            proofs[0] = meta.lastValidState;
        }

        // Use the adjudicator to validate the state
        (bool valid, Asset[] memory outcome) = IAdjudicator(chan.adjudicator).adjudicate(chan, state, proofs);

        if (!valid) {
            revert InvalidState();
        }

        // Store the valid state and outcome
        meta.lastValidState = state;
        meta.outcome = outcome;

        // Set challenge expiration time
        meta.challengeExpire = block.timestamp + CHALLENGE_PERIOD;

        // Mark as CHALLENGED
        meta.status = Status.CHALLENGED;
    }

    /**
     * @notice Conclude the channel after challenge period expires
     * @param channelId Unique identifier for the channel
     */
    function reclaim(bytes32 channelId) external override {
        Metadata storage meta = channels[channelId];

        // Channel must be in CHALLENGED state
        if (meta.status != Status.CHALLENGED) {
            revert InvalidStatus();
        }

        // Challenge period must have expired
        if (block.timestamp < meta.challengeExpire) {
            revert ChallengeNotExpired();
        }

        // Distribute tokens according to the last valid outcome
        _distributeAssets(meta.outcome, meta.chan.participants);

        // Mark channel as closed
        meta.status = Status.CLOSED;
    }

    /**
     * @dev Distributes assets to participants based on the outcome
     * @param outcome Array of assets for each participant
     * @param participants Array of participant addresses
     */
    function _distributeAssets(Asset[] memory outcome, address[] memory participants) private {
        // Ensure we have outcomes for both participants
        require(outcome.length == 2, "Invalid outcome length");

        // Distribute to Host (participant[0])
        if (outcome[0].amount > 0) {
            // NOTE: GOOD simplification for THIS APP ONLY is to only support 1 asset per participant in outcome
            bool success = IERC20(outcome[0].token).transfer(participants[0], outcome[0].amount);

            if (!success) {
                revert TransferFailed();
            }
        }

        // Distribute to Guest (participant[1])
        if (outcome[1].amount > 0) {
            bool success = IERC20(outcome[1].token).transfer(participants[1], outcome[1].amount);

            if (!success) {
                revert TransferFailed();
            }
        }
    }

    /**
     * @dev Verifies a signature against a message hash and signer
     * @param signer The expected signer address
     * @param hash The message hash that was signed
     * @param signature The signature to verify
     * @return valid Whether the signature is valid
     */
    // TODO: can be substituted with OpenZeppelin's ECDSA.sol library
    function verifySignature(address signer, bytes32 hash, Signature memory signature)
        private
        pure
        returns (bool valid)
    {
        // Recover signer from signature
        address recovered = ecrecover(hash, signature.v, signature.r, signature.s);

        // Check if recovered address matches expected signer
        return recovered == signer;
    }
}
