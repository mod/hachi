// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./Types.sol";

/**
 * @title State Channel Interface
 * @notice Main interface for the state channel system
 */
interface IChannel {
    /**
     * @notice Open or join a channel by depositing assets
     * @param ch Channel configuration
     * @param deposit Assets to deposit by the caller
     * @return channelId Unique identifier for the channel
     */
    function open(Channel calldata ch, Asset calldata deposit) external returns (bytes32 channelId);

    /**
     * @notice Finalize the channel with a mutually signed state
     * @param channelId Unique identifier for the channel
     * @param state The final state signed by both parties
     * @param signatures Array of signatures from both participants
     */
    function close(bytes32 channelId, State calldata state, Signature[2] calldata signatures) external;

    /**
     * @notice Unilaterally post a state when the other party is uncooperative
     * @param channelId Unique identifier for the channel
     * @param state The latest known valid state
     */
    function challenge(bytes32 channelId, State calldata state) external;

    /**
     * @notice Conclude the channel after challenge period expires
     * @param channelId Unique identifier for the channel
     */
    function reclaim(bytes32 channelId) external;
}
