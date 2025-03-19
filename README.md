# Simplified State Channel Specification

This document describes a minimal **N-party state channel** that enables off-chain interaction between a **Host** and a **Guest**, with an on-chain contract providing:

1. **Custody** of ERC-20 tokens for each channel.
2. **Mutual close** when both parties sign a final state.
3. **Challenge/response** mechanism allowing a party to unilaterally finalize if needed.

> **Note:** This is a high-level specification of types, interfaces, and function semantics—no implementation details are included.

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

### `Channel`

Identifies a channel between exactly **two** participants (`participants[0]` is Host, `participants[1]` is Guest) and specifies an external adjudicator:

```solidity
struct Channel {
    address[] participants; // Always length 2: [Host, Guest]
    address adjudicator;    // Address of the contract that validates final states
    uint64 nonce;           // Strictly increasing for each new off-chain state
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

### `ITypes`

Contains shared type definitions:

```solidity
interface ITypes {
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
}
```

### `IAdjudicator`

The adjudicator contract must implement:

```solidity
interface IAdjudicator {
    function adjudicate(
        Channel calldata chan,
        bytes calldata candidate,
        bytes[] calldata proofs
    ) external view returns (
        bool valid,
        ITypes.Asset[2] memory outcome
    );
}
```

- **Parameters**:
  - `chan`: Channel configuration
  - `candidate`: ABI encoded off-chain state (e.g., game data)
  - `proofs`: Additional data for state validation
- **Returns**:
  - `valid`: Whether the candidate state is valid given the proofs
  - `outcome`: The final split of tokens for `[Host, Guest]` if `valid` is true

## IStateChannel Interface

The main state channel interface implements:

```solidity
interface IChannel {
    function open(
        ITypes.Channel calldata ch,
        ITypes.Asset calldata deposit
    ) external returns (bytes32 channelId);
    
    function close(
        bytes32 channelId,
        bytes calldata state,
        ITypes.Signature[2] calldata signatures
    ) external;
    
    function challenge(
        bytes32 channelId,
        bytes calldata state
    ) external;
    
    function reclaim(
        bytes32 channelId
    ) external;
}
```

### Function Details

1. **Open Channel**  
   `open(ITypes.Channel ch, ITypes.Asset deposit) returns (bytes32 channelId)`
   - **Purpose**: Open or join a channel by depositing assets into the contract.
   - **Effects**:  
     - Transfers token amounts from the caller to the contract
     - Returns unique channelId
     - Marks channel as open

2. **Close Channel (Mutual Close)**  
   `close(bytes32 channelId, bytes state, ITypes.Signature[2] signatures)`  
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
