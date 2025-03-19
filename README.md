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

## External Interface

### `IAdjudicator`

The adjudicator contract must implement:

```solidity
interface IAdjudicator {
    function adjudicate(
        bytes calldata state
    ) external view returns (
        bool valid,
        Asset[2] memory outcome
    );
}
```

- **Parameters**:
  - `state`: ABI Encoded off-chain state (e.g., game data).
  Contains a versioning to be able to challenge with more recent state and participant signatures
- **Returns**:
  - `valid`: Whether the off-chain `state` is valid given the game logic and signatures.
  - `outcome`: The final split of tokens for `[Host, Guest]` if `valid` is true.

## Contract Functions (Conceptual)

1. **Open Channel**  
   `open(Channel ch, Asset deposit) return bytes32`
   - **Purpose**: Open or join a channel by depositing `asset` into the contract from the caller.
   - **Effects**:  
     - Transfers token amounts in `asset` from the caller to the contract.
     - Emit Events
     - Return ChannelId
     - Marks channel as open.

2. **Close Channel (Mutual Close)**  
   `close(bytes32 chId, bytes state, Signature[2])`  
   - **Purpose**: Finalize the channel immediately with a mutually signed state.
   - **Logic**:
     - Calls `adjudicate(state, sigs)` on `ch.adjudicator`.
     - If `valid` is `true`, distributes tokens according to `outcome`.
     - Closes the channel.

3. **Challenge Channel**  
   `challenge(bytes32 chId, bytes state)`  
   - **Purpose**: Unilaterally post a latest known state when the other party is uncooperative.
   - **Subsequent calls**: Counter an ongoing challenge with a *newer* state (strictly higher `version` inside state).
   - **Logic**:
     - Verifies the submitted state is valid via `adjudicate`.
     - Records the proposed outcome and starts the "challenge period."

5. **Finalize Challenge**  
   `reclaim(bytes32 chId)`  
   - **Purpose**: Conclude the channel after the challenge period expires, if uncontested or if no newer state supersedes the last posted outcome.
   - **Logic**:  
     - Distributes tokens according to the last proposed outcome.
     - Closes the channel.

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
