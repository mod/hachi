# Simplified State Channel Specification

This document describes a minimal **N-party state channel** that enables off-chain interaction between a **Host** and a **Guest**, with an on-chain contract providing:

1. **Custody** of ERC-20 tokens for each channel.
2. **Mutual close** when both parties sign a final state.
3. **Challenge/response** mechanism allowing a party to unilaterally finalize if needed.

> **Note:** This is a high-level specification of types, interfaces, and function semantics—no implementation details are included.

State channel infrastructure has two main components:

- Channel Custody which can support and run adjudication on multiple channels
- Adjudicators mini contracts which can validate state transitions to a candidate state against proofs

## Data Types

### `Signature`

A standard ECDSA signature broken into `(v, r, s)` components:

```solidity
struct Signature {
    uint8 v;
    bytes32 r;
    bytes32 s;
}
```

The convention is to sign the `stateHash = keccak256(state)`
EIP712 is not required to form signed state

### `Channel`

Identifies a channel between exactly **two** participants (`participants[0]` is Host, `participants[1]` is Guest) and specifies an external adjudicator:

```solidity
struct Channel {
    address[] participants; // Always length 2: [Host, Guest]
    address adjudicator;    // Address of the contract that validates final states
    uint64 nonce;           // Unique per channel with same participants and adjudicator
}
```

### `State`

Contains the application-specific data and outcome distribution:

```solidity
struct State {
    bytes data;      // Application-specific state data
    Asset[] outcome; // Asset distribution
}
```

### `Asset`

Represents a token and amount:

```solidity
struct Asset {
    address token;    // ERC-20 token contract
    uint256 amount;   // Token amount
}
```

## Interface Structure

### `Types`

Contains shared type definitions:

```solidity
struct Signature {
    uint8 v;
    bytes32 r;
    bytes32 s;
}

struct Channel {
    address[] participants; // Always length 2: [Host, Guest]
    address adjudicator;    // Address of the contract that validates final states
    uint64 nonce;           // Unique per channel with same participants and adjudicator
}

struct Asset {
    address token;    // ERC-20 token contract
    uint256 amount;   // Token amount
}
```

### `IAdjudicator`

The adjudicator contract must implement:

```solidity
interface IAdjudicator {
    function adjudicate(
        Channel calldata chan,
        State calldata candidate,
        State[] calldata proofs
    ) external view returns (
        bool valid,
        Asset[] memory outcome
    );
}
```

- **Parameters**:
  - `chan`: Channel configuration
  - `candidate`: The State being validated, containing application-specific data
  - `proofs`: Previous valid states for reference in validation
- **Returns**:
  - `valid`: Whether the candidate state is valid given the proofs
  - `outcome`: The final split of tokens if `valid` is true

## IChannel Interface

The main state channel interface implements:

```solidity
interface IChannel {
    function open(
        Channel calldata ch,
        Asset calldata deposit
    ) external returns (bytes32 channelId);
    
    function close(
        bytes32 channelId,
        State calldata state,
        Signature[2] calldata signatures
    ) external;
    
    function challenge(
        bytes32 channelId,
        State calldata state
    ) external;
    
    function reclaim(
        bytes32 channelId
    ) external;
}
```

### Function Details

1. **Open Channel**  
   `open(Channel ch, Asset deposit) returns (bytes32 channelId)`
   - **Purpose**: Open or join a channel by depositing assets into the contract.
   - **Effects**:  
     - Transfers token amounts from the caller to the contract
     - Returns unique channelId
     - Marks channel as open

2. **Close Channel (Mutual Close)**  
   `close(bytes32 channelId, bytes state, Signature[2] signatures)`  
   - **Purpose**: Finalize the channel immediately with a mutually signed state.
   - **Logic**:
     - Verifies signatures from both participants
     - Calls `adjudicate` on the channel's adjudicator
     - If valid, distributes tokens according to outcome
     - Closes the channel

3. **Challenge Channel**  
   `challenge(bytes32 channelId, bytes state)`  
   - **Purpose**: Unilaterally post a state when the other party is uncooperative.
   - **Logic**:
     - Verifies the submitted state is valid via `adjudicate`
     - Records the proposed outcome and starts the challenge period

4. **Finalize Challenge**  
   `reclaim(bytes32 channelId)`  
   - **Purpose**: Conclude the channel after challenge period expires.
   - **Logic**:  
     - Distributes tokens according to the last valid outcome
     - Closes the channel

## High-Level Flow

1. **Channel Creation**:  
   - The Host and Guest each deposit ERC-20 tokens into the contract using `open`.
2. **Off-Chain Updates**:  
   - The two parties exchange and co-sign states off-chain, incrementing `versioning` inside their application state.
3. **Happy Path (Mutual Close)**:  
   - A final state is signed by both parties.
   - Either party calls `close` to finalize distribution immediately.
4. **Unhappy Path (Challenge)**:  
   - One party calls `challenge` with their most recent signed state.
   - The counterparty may respond with a *newer* state using `challenge`.
   - After the challenge period, `reclaim` settles funds according to the last posted valid state.

## Files

```
src
├── Custody.sol
├── adjudicators
│   └── MicroPayment.sol
└── interfaces
    ├── IAdjudicator.sol
    ├── IChannel.sol
    └── sol
```

### Custody.sol implementation

#### Requirements

- Sign stateHash
- Do not use EIP712
- When submitting new challenge, previously submitted states into proofs of the adjudicator
- Only state which adjudicator return valid can replace previously submitted state

```solidity
    enum Status {
        VOID,
        PARTIAL,  // Partial funding
        OPENED,   // Channel funded
        CLOSED,   // Channel closed
        CHALLENGED
    }

    struct Metadata {
        Channel  chan;
        Asset[2] outcome;
        Status          status;
        uint256         challengeExpire;
        bytes           lastValidState;
    }

    // ChannelId to Data
    mapping(bytes32 => Metadata) private channels;
```

### MicroPayment.sol adjudicator

#### Requirements

- Validate state is signed by Host
- Candidate `version` is higher than proofs
- Do not use EIP712
- Use `stateHash = keccak256(SignedVoucher)`

```solidity
struct Voucher {
    uint64 version;
    Asset payment;
}

struct SignedVoucher {
    Voucher voucher;
    Signature signature;
}
```

## Example Scenario (Tic-Tac-Toe)

1. **Open Channel**:  
   - Alice (Host) and Bob (Guest) each deposit 100 USDC.
2. **Play Off-Chain**:  
   - They exchange signed states for each move, incrementing `turn`.
3. **Alice Wins**:  
   - The final state says Alice gets 200 USDC, Bob gets 0.
4. **Mutual Close**:  
   - They both sign, and either calls `close`, distributing 200 USDC to Alice.
5. **Challenge Path**:  
   - If Bob refuses to sign, Alice calls `challenge`. If Bob cannot produce a newer state, Alice finalizes and claims her winnings once the challenge period ends.

## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

- **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
- **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
- **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
- **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

<https://book.getfoundry.sh/>

## Usage

### Build

```shell
forge build
```

### Test

```shell
forge test
```

### Format

```shell
forge fmt
```

### Gas Snapshots

```shell
forge snapshot
```

### Anvil

```shell
anvil
```

### Deploy

```shell
forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
cast <subcommand>
```

### Help

```shell
forge --help
anvil --help
cast --help
```
