// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title State Channel Type Definitions
 * @notice Shared types used in the state channel system
 */
// TODO: no need to restrain signatures to ECDSA over a hash. `bytes` will allow applications to use other signing schemes.
struct Signature {
    uint8 v;
    bytes32 r;
    bytes32 s;
}

struct Channel {
    address[] participants; // Always length 2: [Host, Guest]
    address adjudicator; // Address of the contract that validates final states
    uint64 nonce; // Unique per channel with same participants and adjudicator
    // TODO: move challengeDuration here
}

struct State {
    bytes data;
    Asset[] outcome;
}

struct Asset {
    address token; // ERC-20 token contract
    uint256 amount; // Token amount
}
