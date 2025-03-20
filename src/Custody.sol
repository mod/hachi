// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IChannel} from "./interfaces/IChannel.sol";
import {IAdjudicator} from "./interfaces/IAdjudicator.sol";
import {ITypes} from "./interfaces/ITypes.sol";
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
        ITypes.Channel chan;
        ITypes.Asset[2] outcome;
        Status status;
        uint256 challengeExpire;
        bytes lastValidState;
    }

    // ChannelId to Metadata mapping
    mapping(bytes32 => Metadata) private channels;

    /**
     * @notice Open or join a channel by depositing assets
     * @param ch Channel configuration
     * @param deposit Assets to deposit by the caller
     * @return channelId Unique identifier for the channel
     */
    function open(ITypes.Channel calldata ch, ITypes.Asset calldata deposit)
        external
        override
        returns (bytes32 channelId)
    {
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
            meta.status = Status.PARTIAL;
        } else if (meta.status != Status.PARTIAL && meta.status != Status.OPENED) {
            revert InvalidStatus();
        }

        // Transfer deposit to this contract
        if (deposit.amount > 0) {
            bool success = IERC20(deposit.token).transferFrom(msg.sender, address(this), deposit.amount);

            if (!success) {
                revert TransferFailed();
            }
        }

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
    function close(bytes32 channelId, bytes calldata state, ITypes.Signature[2] calldata signatures)
        external
        override
    {
        Metadata storage meta = channels[channelId];

        // Check channel exists and is in the correct state
        if (meta.status != Status.OPENED && meta.status != Status.CHALLENGED) {
            revert InvalidStatus();
        }

        // Verify signatures from both participants
        ITypes.Channel memory chan = meta.chan;
        bytes32 stateHash = keccak256(state);

        if (!verifySignature(chan.participants[0], stateHash, signatures[0])) {
            revert InvalidSignature();
        }

        if (!verifySignature(chan.participants[1], stateHash, signatures[1])) {
            revert InvalidSignature();
        }

        // Use the adjudicator to validate the state and get the outcome
        (bool valid, ITypes.Asset[2] memory outcome) = IAdjudicator(chan.adjudicator).adjudicate(
            chan,
            state,
            new bytes[](0) // No proofs needed for mutual close
        );

        if (!valid) {
            revert InvalidState();
        }

        // Distribute tokens according to adjudicated outcome
        _distributeAssets(outcome, chan.participants);

        // Mark channel as closed
        meta.status = Status.CLOSED;
    }

    /**
     * @notice Unilaterally post a state when the other party is uncooperative
     * @param channelId Unique identifier for the channel
     * @param state The latest known valid state
     */
    function challenge(bytes32 channelId, bytes calldata state) external override {
        Metadata storage meta = channels[channelId];

        // Check channel exists and is in a valid state for challenge
        if (meta.status != Status.OPENED && meta.status != Status.CHALLENGED) {
            revert InvalidStatus();
        }

        ITypes.Channel memory chan = meta.chan;

        // Verify caller is a participant
        if (msg.sender != chan.participants[0] && msg.sender != chan.participants[1]) {
            revert InvalidCaller();
        }

        // Prepare proofs array including previous state if this is a counter-challenge
        bytes[] memory proofs = new bytes[](0);
        if (meta.status == Status.CHALLENGED && meta.lastValidState.length > 0) {
            proofs = new bytes[](1);
            proofs[0] = meta.lastValidState;
        }

        // Use the adjudicator to validate the state
        (bool valid, ITypes.Asset[2] memory outcome) = IAdjudicator(chan.adjudicator).adjudicate(chan, state, proofs);

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
    function _distributeAssets(ITypes.Asset[2] memory outcome, address[] memory participants) private {
        // Distribute to Host (participant[0])
        if (outcome[0].amount > 0) {
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
    function verifySignature(address signer, bytes32 hash, ITypes.Signature memory signature)
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
