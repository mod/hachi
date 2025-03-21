// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IAdjudicator} from "../interfaces/IAdjudicator.sol";
import "../interfaces/Types.sol";
import {Test, Vm, console} from "lib/forge-std/src/Test.sol";

contract SnakeGame is IAdjudicator {
    error InvalidSignature();
    error InvalidGameState();
    error InvalidTick();
    error InvalidGridSize();
    error InvalidSnakePosition();
    error InvalidFoodPosition();
    error InvalidCollisionState();
    error InvalidInitialLength();
    error InvalidFoodCount();
    error MissingConfiguration();
    error InvalidConfigSignatures();
    error InvalidPreviousStateSignatures();
    error InvalidProofCount();

    struct Point {
        uint8 x;
        uint8 y;
    }

    struct Snake {
        Point[] body; // Array of points, first element is head
        Direction direction;
        bool isDead;
    }

    enum Direction {
        UP,
        RIGHT,
        DOWN,
        LEFT
    }

    struct GameConfig {
        uint8 gridSize;
        uint8 initialSnakeLength;
        uint8 foodCount;
    }

    struct GameState {
        uint64 version;
        uint8 gridSize;
        Snake[2] snakes;
        Point[] food;
        uint64 tick;
        uint8 winner; // 0=none, 1=player1, 2=player2
    }

    struct SignedGameState {
        GameState state;
        Signature signature1; // Host's signature
        Signature signature2; // Guest's signature
    }

    uint8 constant BOUNDARY_THICKNESS = 1;

    function adjudicate(
        Channel calldata chan,
        State calldata candidate,
        State[] calldata proofs
    ) external pure override returns (bool valid, Asset[] memory outcome) {
        if (proofs.length == 0) {
            revert MissingConfiguration();
        }

        // Decode configuration and verify signatures
        SignedGameConfig memory signedConfig = abi.decode(
            proofs[0].data,
            (SignedGameConfig)
        );
        bytes32 configHash = keccak256(abi.encode(signedConfig.config));

        // Config must be signed by both participants
        if (
            !verifySignature(
                chan.participants[0],
                configHash,
                signedConfig.signature1
            ) ||
            !verifySignature(
                chan.participants[1],
                configHash,
                signedConfig.signature2
            )
        ) {
            revert InvalidConfigSignatures();
        }

        // Decode candidate state
        SignedGameState memory candidateGame = abi.decode(
            candidate.data,
            (SignedGameState)
        );
        bytes32 stateHash = keccak256(abi.encode(candidateGame.state));

        // For a new state, at least one signature is required
        if (
            !verifySignature(
                chan.participants[0],
                stateHash,
                candidateGame.signature1
            ) &&
            !verifySignature(
                chan.participants[1],
                stateHash,
                candidateGame.signature2
            )
        ) {
            revert InvalidSignature();
        }

        // For initial state validation
        if (proofs.length == 1) {
            if (
                !isValidInitialState(candidateGame.state, signedConfig.config)
            ) {
                console.log("invalid initial");

                revert InvalidGameState();
            }
        } else if (proofs.length == 2) {
            // Decode previous state
            SignedGameState memory previousGame = abi.decode(
                proofs[1].data,
                (SignedGameState)
            );
            bytes32 prevStateHash = keccak256(abi.encode(previousGame.state));

            // Previous state must have both signatures
            if (
                !verifySignature(
                    chan.participants[0],
                    prevStateHash,
                    previousGame.signature1
                ) ||
                !verifySignature(
                    chan.participants[1],
                    prevStateHash,
                    previousGame.signature2
                )
            ) {
                revert InvalidPreviousStateSignatures();
            }

            // Validate tick increment
            if (candidateGame.state.tick != previousGame.state.tick + 1) {
                revert InvalidTick();
            }

            // Validate state transition including movement and collisions
            if (
                !isValidTransition(
                    previousGame.state,
                    candidateGame.state,
                    signedConfig.config
                )
            ) {
                console.log("invalid transition");
                revert InvalidGameState();
            }
        } else {
            revert InvalidProofCount();
        }

        outcome = calculateOutcome(chan, candidateGame.state);
        valid = true;
        return (valid, outcome);
    }

    struct SignedGameConfig {
        GameConfig config;
        Signature signature1;
        Signature signature2;
    }

    function isValidTransition(
        GameState memory prevState,
        GameState memory newState,
        GameConfig memory config
    ) internal pure returns (bool) {
        // Verify grid size hasn't changed
        if (newState.gridSize != config.gridSize) return false;

        // Verify food count remains constant
        if (newState.food.length != config.foodCount) return false;

        // Verify tick increment
        if (newState.tick != prevState.tick + 1) return false;

        // Calculate expected state after movement and collisions
        GameState memory expectedState = calculateNextState(prevState);

        // Compare expected state with provided new state
        return statesEqual(expectedState, newState);
    }

    function isInPlayableArea(
        Point memory point,
        uint8 gridSize
    ) internal pure returns (bool) {
        return
            point.x >= BOUNDARY_THICKNESS &&
            point.x < gridSize - BOUNDARY_THICKNESS &&
            point.y >= BOUNDARY_THICKNESS &&
            point.y < gridSize - BOUNDARY_THICKNESS;
    }

    function calculateNextState(
        GameState memory prevState
    ) internal pure returns (GameState memory) {
        GameState memory nextState = prevState;
        nextState.tick += 1;

        // Move snakes and check for food consumption
        for (uint i = 0; i < 2; i++) {
            if (nextState.snakes[i].isDead) {
                continue;
            }

            Point memory newHead = getNextHeadPosition(
                prevState.snakes[i].body[0],
                prevState.snakes[i].direction
            );

            // Check if snake moved into unplayable area
            if (!isInPlayableArea(newHead, nextState.gridSize)) {
                nextState.snakes[i].isDead = true;
            }

            // How snake's body changed after moving
            moveSnake(nextState.snakes[i], prevState.food);

            // Check for collision with snakes
            for (uint j = 0; j < 2; j++) {
                // Cannot collide with the dead snake
                if (prevState.snakes[j].isDead) {
                    continue;
                }

                for (uint k = 0; k < nextState.snakes[j].body.length; k++) {
                    // Cannot collide with its own head
                    if (k == 0 && i == j) {
                        continue;
                    }

                    if (pointsEqual(newHead, nextState.snakes[j].body[k])) {
                        nextState.snakes[j].isDead = true;
                        break;
                    }
                }
            }
        }

        return nextState;
    }

    function moveSnake(Snake memory snake, Point[] memory food) internal pure {
        Point memory newHead = getNextHeadPosition(
            snake.body[0],
            snake.direction
        );

        bool ateFood = false;
        for (uint i = 0; i < food.length; i++) {
            if (pointsEqual(newHead, food[i])) {
                ateFood = true;
                break;
            }
        }

        if (ateFood) {
            // Grow snake by adding new head
            Point[] memory newBody = new Point[](snake.body.length + 1);
            newBody[0] = newHead;
            for (uint i = 0; i < snake.body.length; i++) {
                newBody[i + 1] = snake.body[i];
            }
            snake.body = newBody;
        } else {
            // Move snake by updating positions
            for (uint i = snake.body.length - 1; i > 0; i--) {
                snake.body[i] = snake.body[i - 1];
            }
            snake.body[0] = newHead;
        }
    }

    function statesEqual(
        GameState memory a,
        GameState memory b
    ) internal pure returns (bool) {
        if (a.gridSize != b.gridSize) return false;
        if (a.tick != b.tick) return false;
        if (a.winner != b.winner) return false;
        if (a.food.length != b.food.length) return false;

        for (uint i = 0; i < a.food.length; i++) {
            if (!pointsEqual(a.food[i], b.food[i])) return false;
        }

        for (uint i = 0; i < 2; i++) {
            console.log(a.snakes[i].isDead, b.snakes[i].isDead);
            for (uint j = 0; j < a.snakes[i].body.length; j++) {
                console.log(
                    "exp",
                    i,
                    a.snakes[i].body[j].x,
                    a.snakes[i].body[j].y
                );
                console.log(
                    "new",
                    i,
                    b.snakes[i].body[j].x,
                    b.snakes[i].body[j].y
                );
            }
        }

        for (uint i = 0; i < 2; i++) {
            if (!snakesEqual(a.snakes[i], b.snakes[i])) return false;
        }

        return true;
    }

    function pointsEqual(
        Point memory a,
        Point memory b
    ) internal pure returns (bool) {
        return a.x == b.x && a.y == b.y;
    }

    function getNextHeadPosition(
        Point memory currentHead,
        Direction direction
    ) internal pure returns (Point memory) {
        Point memory newHead = Point({x: currentHead.x, y: currentHead.y});

        if (direction == Direction.UP) {
            newHead.y = currentHead.y > 0 ? currentHead.y - 1 : currentHead.y;
        } else if (direction == Direction.DOWN) {
            newHead.y = currentHead.y + 1;
        } else if (direction == Direction.LEFT) {
            newHead.x = currentHead.x > 0 ? currentHead.x - 1 : currentHead.x;
        } else if (direction == Direction.RIGHT) {
            newHead.x = currentHead.x + 1;
        }

        return newHead;
    }

    function snakesEqual(
        Snake memory a,
        Snake memory b
    ) internal pure returns (bool) {
        if (a.direction != b.direction) return false;
        if (a.isDead != b.isDead) return false;
        if (a.body.length != b.body.length) return false;

        for (uint i = 0; i < a.body.length; i++) {
            if (!pointsEqual(a.body[i], b.body[i])) return false;
        }

        return true;
    }

    function isValidInitialState(
        GameState memory state,
        GameConfig memory config
    ) internal pure returns (bool) {
        // Verify grid size matches config
        if (state.gridSize != config.gridSize) return false;

        // Verify food count matches config
        if (state.food.length != config.foodCount) return false;

        // Verify initial snake lengths
        for (uint i = 0; i < 2; i++) {
            if (state.snakes[i].body.length != config.initialSnakeLength)
                return false;
            if (state.snakes[i].isDead) return false;

            // Verify snake is within grid bounds
            for (uint j = 0; j < state.snakes[i].body.length; j++) {
                Point memory p = state.snakes[i].body[j];
                if (p.x >= state.gridSize || p.y >= state.gridSize)
                    return false;
            }
        }

        // Verify snakes don't overlap initially
        for (uint i = 0; i < state.snakes[0].body.length; i++) {
            for (uint j = 0; j < state.snakes[1].body.length; j++) {
                if (
                    pointsEqual(
                        state.snakes[0].body[i],
                        state.snakes[1].body[j]
                    )
                ) {
                    return false;
                }
            }
        }

        // Verify food positions are valid (not overlapping with snakes)
        for (uint f = 0; f < state.food.length; f++) {
            // Check food is within grid bounds
            if (
                state.food[f].x >= state.gridSize ||
                state.food[f].y >= state.gridSize
            ) {
                return false;
            }

            // Check food doesn't overlap with snakes
            for (uint i = 0; i < 2; i++) {
                for (uint j = 0; j < state.snakes[i].body.length; j++) {
                    if (pointsEqual(state.food[f], state.snakes[i].body[j])) {
                        return false;
                    }
                }
            }
        }

        return true;
    }

    //TODO: take outcome from the channel + winner should be decided when:
    // either both snake are dead: winner is the longest
    // one of snakes is alive, and it's longer than the dead one
    function calculateOutcome(
        Channel calldata chan,
        GameState memory state
    ) internal pure returns (Asset[] memory) {
        Asset[] memory outcome = new Asset[](2);
        address token = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
        uint256 totalFunds = 100 ether;

        // If no winner is declared yet, split funds equally
        if (state.winner == 0) {
            outcome[0] = Asset({token: token, amount: totalFunds / 2});
            outcome[1] = Asset({token: token, amount: totalFunds / 2});
            return outcome;
        }

        // Winner takes all
        if (state.winner == 1) {
            outcome[0] = Asset({token: token, amount: totalFunds});
            outcome[1] = Asset({token: token, amount: 0});
        } else {
            outcome[0] = Asset({token: token, amount: 0});
            outcome[1] = Asset({token: token, amount: totalFunds});
        }

        return outcome;
    }

    function verifySignature(
        address signer,
        bytes32 hash,
        Signature memory signature
    ) internal pure returns (bool) {
        // Recover signer from signature
        address recovered = ecrecover(
            hash,
            signature.v,
            signature.r,
            signature.s
        );

        // Check if recovered address matches expected signer
        return recovered == signer;
    }
}
