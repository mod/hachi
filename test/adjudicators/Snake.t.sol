// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "lib/forge-std/src/Test.sol";
import {SnakeGame} from "../../src/adjudicators/Snake.sol";
import {Custody} from "../../src/Custody.sol";
import "../../src/interfaces/Types.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract SnakeGameTest is Test {
    SnakeGame public adjudicator;
    Custody public custody;
    MockERC20 public token;

    // Test addresses
    address public host;
    address public guest;

    // Private keys for signing
    uint256 private hostKey = 0x1;
    uint256 private guestKey = 0x2;

    // Channel constants
    uint64 private constant CHANNEL_NONCE = 1;
    uint256 private constant INITIAL_DEPOSIT = 100 ether;

    // Game constants
    uint8 private constant GRID_SIZE = 10;
    uint8 private constant INITIAL_SNAKE_LENGTH = 3;
    uint8 private constant FOOD_COUNT = 3;

    function setUp() public {
        // Deploy contracts
        adjudicator = new SnakeGame();
        custody = new Custody();
        token = new MockERC20("Test Token", "TST", 18);

        // Set up test accounts
        host = vm.addr(hostKey);
        guest = vm.addr(guestKey);
        vm.label(host, "Host");
        vm.label(guest, "Guest");

        // Fund accounts
        token.mint(host, INITIAL_DEPOSIT);
        token.mint(guest, INITIAL_DEPOSIT);

        vm.prank(host);
        token.approve(address(custody), INITIAL_DEPOSIT);

        vm.prank(guest);
        token.approve(address(custody), INITIAL_DEPOSIT);
    }

    function test_InitialGameState() public {
        // Create channel config
        address[] memory participants = new address[](2);
        participants[0] = host;
        participants[1] = guest;

        Channel memory channel = Channel({
            participants: participants,
            adjudicator: address(adjudicator),
            nonce: CHANNEL_NONCE
        });

        // Create and sign game configuration
        SnakeGame.GameConfig memory config = SnakeGame.GameConfig({
            gridSize: GRID_SIZE,
            initialSnakeLength: INITIAL_SNAKE_LENGTH,
            foodCount: FOOD_COUNT
        });

        // Sign config with both participants
        bytes32 configHash = keccak256(abi.encode(config));
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(hostKey, configHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(guestKey, configHash);

        SnakeGame.SignedGameConfig memory signedConfig = SnakeGame
            .SignedGameConfig({
                config: config,
                signature1: Signature({v: v1, r: r1, s: s1}),
                signature2: Signature({v: v2, r: r2, s: s2})
            });

        // Create initial snake positions
        // Host snake starts from top-left
        SnakeGame.Point[] memory hostSnakeBody = new SnakeGame.Point[](
            INITIAL_SNAKE_LENGTH
        );
        for (uint8 i = 0; i < INITIAL_SNAKE_LENGTH; i++) {
            hostSnakeBody[i] = SnakeGame.Point({x: i, y: 0});
        }

        // Guest snake starts from bottom-right
        SnakeGame.Point[] memory guestSnakeBody = new SnakeGame.Point[](
            INITIAL_SNAKE_LENGTH
        );
        for (uint8 i = 0; i < INITIAL_SNAKE_LENGTH; i++) {
            guestSnakeBody[i] = SnakeGame.Point({
                x: GRID_SIZE - 1 - i,
                y: GRID_SIZE - 1
            });
        }

        // Create initial food positions
        SnakeGame.Point[] memory foodPositions = new SnakeGame.Point[](
            FOOD_COUNT
        );
        foodPositions[0] = SnakeGame.Point({x: 4, y: 4});
        foodPositions[1] = SnakeGame.Point({x: 5, y: 5});
        foodPositions[2] = SnakeGame.Point({x: 6, y: 6});

        // Create initial game state
        SnakeGame.GameState memory gameState = SnakeGame.GameState({
            version: 1,
            gridSize: GRID_SIZE,
            snakes: [
                SnakeGame.Snake({
                    body: hostSnakeBody,
                    direction: SnakeGame.Direction.RIGHT,
                    isDead: false
                }),
                SnakeGame.Snake({
                    body: guestSnakeBody,
                    direction: SnakeGame.Direction.LEFT,
                    isDead: false
                })
            ],
            food: foodPositions,
            tick: 0,
            winner: 0
        });

        // Sign the initial state with both participants
        bytes32 stateHash = keccak256(abi.encode(gameState));
        (v1, r1, s1) = vm.sign(hostKey, stateHash);
        (v2, r2, s2) = vm.sign(guestKey, stateHash);

        SnakeGame.SignedGameState memory signedState = SnakeGame
            .SignedGameState({
                state: gameState,
                signature1: Signature({v: v1, r: r1, s: s1}),
                signature2: Signature({v: v2, r: r2, s: s2})
            });

        // Create state data structures
        State[] memory proofs = new State[](1);
        proofs[0] = State({
            data: abi.encode(signedConfig),
            outcome: new Asset[](2)
        });

        State memory candidate = State({
            data: abi.encode(signedState),
            outcome: new Asset[](2)
        });

        // Validate initial state
        (bool valid, Asset[] memory outcome) = adjudicator.adjudicate(
            channel,
            candidate,
            proofs
        );

        assertTrue(valid, "Initial state should be valid");
        assertEq(
            outcome[0].amount,
            50 ether,
            "Host should get half of the deposit initially"
        );
        assertEq(
            outcome[1].amount,
            50 ether,
            "Guest should get half of the deposit initially"
        );
    }

    function test_InitialGameState_InvalidConfig() public {
        // Similar setup to test_InitialGameState
        address[] memory participants = new address[](2);
        participants[0] = host;
        participants[1] = guest;

        Channel memory channel = Channel({
            participants: participants,
            adjudicator: address(adjudicator),
            nonce: CHANNEL_NONCE
        });

        // Create invalid config (snake length larger than grid)
        SnakeGame.GameConfig memory invalidConfig = SnakeGame.GameConfig({
            gridSize: 3, // Too small grid
            initialSnakeLength: 4, // Larger than grid
            foodCount: FOOD_COUNT
        });

        // Sign invalid config
        bytes32 configHash = keccak256(abi.encode(invalidConfig));
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(hostKey, configHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(guestKey, configHash);

        SnakeGame.SignedGameConfig memory signedConfig = SnakeGame
            .SignedGameConfig({
                config: invalidConfig,
                signature1: Signature({v: v1, r: r1, s: s1}),
                signature2: Signature({v: v2, r: r2, s: s2})
            });

        // Create minimal valid state (but should fail due to invalid config)
        SnakeGame.Point[] memory minimalBody = new SnakeGame.Point[](1);
        minimalBody[0] = SnakeGame.Point({x: 0, y: 0});

        SnakeGame.GameState memory gameState = SnakeGame.GameState({
            version: 1,
            gridSize: 3,
            snakes: [
                SnakeGame.Snake({
                    body: minimalBody,
                    direction: SnakeGame.Direction.RIGHT,
                    isDead: false
                }),
                SnakeGame.Snake({
                    body: minimalBody,
                    direction: SnakeGame.Direction.LEFT,
                    isDead: false
                })
            ],
            food: new SnakeGame.Point[](0),
            tick: 0,
            winner: 0
        });

        // Sign the state
        bytes32 stateHash = keccak256(abi.encode(gameState));
        (v1, r1, s1) = vm.sign(hostKey, stateHash);
        (v2, r2, s2) = vm.sign(guestKey, stateHash);

        SnakeGame.SignedGameState memory signedState = SnakeGame
            .SignedGameState({
                state: gameState,
                signature1: Signature({v: v1, r: r1, s: s1}),
                signature2: Signature({v: v2, r: r2, s: s2})
            });

        // Prepare state data
        State[] memory proofs = new State[](1);
        proofs[0] = State({
            data: abi.encode(signedConfig),
            outcome: new Asset[](2)
        });

        State memory candidate = State({
            data: abi.encode(signedState),
            outcome: new Asset[](2)
        });

        // Should revert due to invalid initial state
        vm.expectRevert(SnakeGame.InvalidGameState.selector);
        adjudicator.adjudicate(channel, candidate, proofs);
    }

    function test_BasicMovement() public {
        (
            Channel memory channel,
            SnakeGame.GameState memory initialState,
            State[] memory proofs
        ) = createInitialGameState();

        // Create next state where both snakes move forward one step
        SnakeGame.GameState memory nextState = initialState;
        nextState.tick += 1;

        // Move host snake 
        moveSnakeForward(nextState.snakes[0]);

        // Move guest snake
        moveSnakeForward(nextState.snakes[1]);

        // Sign and validate the movement
        State memory candidateState = createSignedState(channel, nextState);
        (bool valid, ) = adjudicator.adjudicate(
            channel,
            candidateState,
            proofs
        );

        assertTrue(valid, "Basic movement should be valid");
    }

    function test_HeadToHeadCollision() public {
        (
            Channel memory channel,
            SnakeGame.GameState memory initialState,
            State[] memory proofs
        ) = createInitialGameState();

        // Position snakes head-to-head
        SnakeGame.Point[] memory hostBody = new SnakeGame.Point[](
            INITIAL_SNAKE_LENGTH
        );
        hostBody[0] = SnakeGame.Point({x: 4, y: 5}); // Head
        hostBody[1] = SnakeGame.Point({x: 3, y: 5});
        hostBody[2] = SnakeGame.Point({x: 2, y: 5});

        SnakeGame.Point[] memory guestBody = new SnakeGame.Point[](
            INITIAL_SNAKE_LENGTH
        );
        guestBody[0] = SnakeGame.Point({x: 6, y: 5}); // Head
        guestBody[1] = SnakeGame.Point({x: 7, y: 5});
        guestBody[2] = SnakeGame.Point({x: 8, y: 5});

        initialState.snakes[0].body = hostBody;
        initialState.snakes[0].direction = SnakeGame.Direction.RIGHT;
        initialState.snakes[1].body = guestBody;
        initialState.snakes[1].direction = SnakeGame.Direction.LEFT;

        // Create first state with positioned snakes
        State memory firstState = createSignedState(channel, initialState);

        // Create next state where both snakes move and collide
        SnakeGame.GameState memory collisionState = initialState;
        collisionState.tick += 1;

        // Move both snakes forward (they will collide)
        moveSnakeForward(collisionState.snakes[0]);
        moveSnakeForward(collisionState.snakes[1]);

        // Both snakes should be dead after collision
        collisionState.snakes[0].isDead = true;
        collisionState.snakes[1].isDead = true;

        // Sign and validate the collision state
        State memory candidateState = createSignedState(
            channel,
            collisionState
        );

        // Update proofs to include the positioned state
        State[] memory updatedProofs = new State[](2);
        updatedProofs[0] = proofs[0]; // Config
        updatedProofs[1] = firstState; // Previous state

        (bool valid, Asset[] memory outcome) = adjudicator.adjudicate(
            channel,
            candidateState,
            updatedProofs
        );

        assertTrue(valid, "Head-to-head collision should be valid");
        assertTrue(
            collisionState.snakes[0].isDead && collisionState.snakes[1].isDead,
            "Both snakes should be dead"
        );
        // TODO: add after outcomes are implemented
        // assertEq(
        //     outcome[0].amount,
        //     50 ether,
        //     "Should split funds on mutual death"
        // );
        // assertEq(
        //     outcome[1].amount,
        //     50 ether,
        //     "Should split funds on mutual death"
        // );
    }

    function test_SelfCollision() public {
        (
            Channel memory channel,
            SnakeGame.GameState memory initialState,
            State[] memory proofs
        ) = createInitialGameState();

        // Create a snake position that will lead to self-collision
        SnakeGame.Point[] memory hostBody = new SnakeGame.Point[](4); // Longer snake for self-collision
        hostBody[0] = SnakeGame.Point({x: 3, y: 3}); // Head
        hostBody[1] = SnakeGame.Point({x: 3, y: 2});
        hostBody[2] = SnakeGame.Point({x: 2, y: 2});
        hostBody[3] = SnakeGame.Point({x: 2, y: 3});

        initialState.snakes[0].body = hostBody;
        initialState.snakes[0].direction = SnakeGame.Direction.DOWN;

        // Create first state with positioned snake
        State memory firstState = createSignedState(channel, initialState);

        // Create next state where snake collides with itself
        SnakeGame.GameState memory collisionState = initialState;
        collisionState.tick += 1;

        // Move host snake (will hit its own body)
        moveSnakeForward(collisionState.snakes[0]);
        collisionState.snakes[0].isDead = true;

        // Move guest snake normally
        moveSnakeForward(collisionState.snakes[1]);

        // Sign and validate the collision state
        State memory candidateState = createSignedState(
            channel,
            collisionState
        );

        State[] memory updatedProofs = new State[](2);
        updatedProofs[0] = proofs[0];
        updatedProofs[1] = firstState;

        (bool valid, Asset[] memory outcome) = adjudicator.adjudicate(
            channel,
            candidateState,
            updatedProofs
        );

        assertTrue(valid, "Self collision should be valid");
        assertTrue(
            collisionState.snakes[0].isDead,
            "Snake should be dead after self collision"
        );
    }

    function test_BoundaryCollision() public {
        (
            Channel memory channel,
            SnakeGame.GameState memory initialState,
            State[] memory proofs
        ) = createInitialGameState();

        // Position host snake near boundary
        SnakeGame.Point[] memory hostBody = new SnakeGame.Point[](
            INITIAL_SNAKE_LENGTH
        );
        hostBody[0] = SnakeGame.Point({x: GRID_SIZE - 2, y: 5}); // Head at right edge
        hostBody[1] = SnakeGame.Point({x: GRID_SIZE - 3, y: 5});
        hostBody[2] = SnakeGame.Point({x: GRID_SIZE - 4, y: 5});

        initialState.snakes[0].body = hostBody;
        initialState.snakes[0].direction = SnakeGame.Direction.RIGHT;

        // Create first state with positioned snake
        State memory firstState = createSignedState(channel, initialState);

        // Create next state where snake hits boundary
        SnakeGame.GameState memory collisionState = initialState;
        collisionState.tick += 1;

        // Move host snake into boundary
        moveSnakeForward(collisionState.snakes[0]);
        collisionState.snakes[0].isDead = true;

        // Move guest snake normally
        moveSnakeForward(collisionState.snakes[1]);

        // Sign and validate the collision state
        State memory candidateState = createSignedState(
            channel,
            collisionState
        );

        State[] memory updatedProofs = new State[](2);
        updatedProofs[0] = proofs[0];
        updatedProofs[1] = firstState;

        (bool valid, Asset[] memory outcome) = adjudicator.adjudicate(
            channel,
            candidateState,
            updatedProofs
        );

        assertTrue(valid, "Boundary collision should be valid");
        assertTrue(
            collisionState.snakes[0].isDead,
            "Snake should be dead after boundary collision"
        );
    }

    function test_SnakeToSnakeBodyCollision() public {
        (
            Channel memory channel,
            SnakeGame.GameState memory initialState,
            State[] memory proofs
        ) = createInitialGameState();

        // Position snakes so that host will collide with guest's body
        // Guest snake in an L shape
        SnakeGame.Point[] memory guestBody = new SnakeGame.Point[](
            INITIAL_SNAKE_LENGTH
        );
        guestBody[0] = SnakeGame.Point({x: 5, y: 3}); // Head
        guestBody[1] = SnakeGame.Point({x: 5, y: 4});
        guestBody[2] = SnakeGame.Point({x: 5, y: 5});

        // Host snake approaching guest's body
        SnakeGame.Point[] memory hostBody = new SnakeGame.Point[](
            INITIAL_SNAKE_LENGTH
        );
        hostBody[0] = SnakeGame.Point({x: 4, y: 4}); // Head
        hostBody[1] = SnakeGame.Point({x: 3, y: 4});
        hostBody[2] = SnakeGame.Point({x: 2, y: 4});

        initialState.snakes[0].body = hostBody;
        initialState.snakes[0].direction = SnakeGame.Direction.RIGHT;
        initialState.snakes[1].body = guestBody;
        initialState.snakes[1].direction = SnakeGame.Direction.UP;

        // Create first state with positioned snakes
        State memory firstState = createSignedState(channel, initialState);

        // Create next state where host snake collides with guest's body
        SnakeGame.GameState memory collisionState = initialState;
        collisionState.tick += 1;

        // Move host snake into guest's body
        moveSnakeForward(collisionState.snakes[0]);
        collisionState.snakes[0].isDead = true; // Host dies from collision

        // Move guest snake normally
        moveSnakeForward(collisionState.snakes[1]);

        // Sign and validate the collision state
        State memory candidateState = createSignedState(
            channel,
            collisionState
        );

        State[] memory updatedProofs = new State[](2);
        updatedProofs[0] = proofs[0];
        updatedProofs[1] = firstState;

        (bool valid, Asset[] memory outcome) = adjudicator.adjudicate(
            channel,
            candidateState,
            updatedProofs
        );

        assertTrue(valid, "Snake-to-body collision should be valid");
        assertTrue(
            collisionState.snakes[0].isDead,
            "Host snake should be dead after colliding with guest's body"
        );
        assertFalse(
            collisionState.snakes[1].isDead,
            "Guest snake should remain alive"
        );

        // Verify snake positions after collision
        assertEq(
            pointsEqual(
                collisionState.snakes[0].body[0],
                SnakeGame.Point({x: 5, y: 4})
            ),
            true,
            "Host head should be at collision point"
        );
        assertEq(
            pointsEqual(
                collisionState.snakes[1].body[0],
                SnakeGame.Point({x: 5, y: 2})
            ),
            true,
            "Guest snake should have moved normally"
        );
    }

    function test_FoodConsumption() public {
        (
            Channel memory channel,
            SnakeGame.GameState memory initialState,
            State[] memory proofs
        ) = createInitialGameState();

        // Position snake near food and food at specific positions
        SnakeGame.Point[] memory hostBody = new SnakeGame.Point[](
            INITIAL_SNAKE_LENGTH
        );
        hostBody[0] = SnakeGame.Point({x: 3, y: 4}); // Head
        hostBody[1] = SnakeGame.Point({x: 2, y: 4});
        hostBody[2] = SnakeGame.Point({x: 1, y: 4});

        // Position food right in front of host snake
        SnakeGame.Point[] memory foodPoints = new SnakeGame.Point[](FOOD_COUNT);
        foodPoints[0] = SnakeGame.Point({x: 4, y: 4}); // Will be eaten
        foodPoints[1] = SnakeGame.Point({x: 7, y: 7}); // Other food points
        foodPoints[2] = SnakeGame.Point({x: 2, y: 2});

        initialState.snakes[0].body = hostBody;
        initialState.snakes[0].direction = SnakeGame.Direction.RIGHT;
        initialState.food = foodPoints;

        // Create first state with positioned snake and food
        State memory firstState = createSignedState(channel, initialState);

        // Create next state where snake eats food
        SnakeGame.GameState memory nextState = initialState;
        nextState.tick += 1;

        // Move host snake to eat food
        // Snake should grow by 1
        SnakeGame.Point[] memory newHostBody = new SnakeGame.Point[](
            INITIAL_SNAKE_LENGTH + 1
        );
        newHostBody[0] = SnakeGame.Point({x: 4, y: 4}); // New head at food position
        for (uint i = 0; i < INITIAL_SNAKE_LENGTH; i++) {
            newHostBody[i + 1] = hostBody[i];
        }
        nextState.snakes[0].body = newHostBody;

        // Move guest snake normally
        moveSnakeForward(nextState.snakes[1]);

        // New food position should appear
        SnakeGame.Point[] memory newFoodPoints = new SnakeGame.Point[](
            FOOD_COUNT
        );
        newFoodPoints[0] = SnakeGame.Point({x: 5, y: 5}); // New food position
        newFoodPoints[1] = foodPoints[1];
        newFoodPoints[2] = foodPoints[2];
        nextState.food = newFoodPoints;

        // Sign and validate the new state
        State memory candidateState = createSignedState(channel, nextState);

        State[] memory updatedProofs = new State[](2);
        updatedProofs[0] = proofs[0];
        updatedProofs[1] = firstState;

        (bool valid, ) = adjudicator.adjudicate(
            channel,
            candidateState,
            updatedProofs
        );

        assertTrue(valid, "Food consumption should be valid");
        assertEq(
            nextState.snakes[0].body.length,
            INITIAL_SNAKE_LENGTH + 1,
            "Snake should grow after eating"
        );
        assertEq(
            nextState.food.length,
            FOOD_COUNT,
            "Food count should remain constant"
        );
    }

    function test_SimultaneousFoodConsumption() public {
        (
            Channel memory channel,
            SnakeGame.GameState memory initialState,
            State[] memory proofs
        ) = createInitialGameState();

        // Position both snakes near the same food
        SnakeGame.Point[] memory hostBody = new SnakeGame.Point[](
            INITIAL_SNAKE_LENGTH
        );
        hostBody[0] = SnakeGame.Point({x: 3, y: 4}); // Head
        hostBody[1] = SnakeGame.Point({x: 2, y: 4});
        hostBody[2] = SnakeGame.Point({x: 1, y: 4});

        SnakeGame.Point[] memory guestBody = new SnakeGame.Point[](
            INITIAL_SNAKE_LENGTH
        );
        guestBody[0] = SnakeGame.Point({x: 5, y: 4}); // Head
        guestBody[1] = SnakeGame.Point({x: 6, y: 4});
        guestBody[2] = SnakeGame.Point({x: 7, y: 4});

        // Position food between snakes
        SnakeGame.Point[] memory foodPoints = new SnakeGame.Point[](FOOD_COUNT);
        foodPoints[0] = SnakeGame.Point({x: 4, y: 4}); // Will be contested
        foodPoints[1] = SnakeGame.Point({x: 7, y: 7});
        foodPoints[2] = SnakeGame.Point({x: 2, y: 2});

        initialState.snakes[0].body = hostBody;
        initialState.snakes[0].direction = SnakeGame.Direction.RIGHT;
        initialState.snakes[1].body = guestBody;
        initialState.snakes[1].direction = SnakeGame.Direction.LEFT;
        initialState.food = foodPoints;

        // Create first state
        State memory firstState = createSignedState(channel, initialState);

        // Create next state where both snakes try to eat same food
        SnakeGame.GameState memory collisionState = initialState;
        collisionState.tick += 1;

        // Move both snakes to food position - they will collide
        moveSnakeForward(collisionState.snakes[0]);
        moveSnakeForward(collisionState.snakes[1]);

        // Both snakes should die from collision
        collisionState.snakes[0].isDead = true;
        collisionState.snakes[1].isDead = true;

        // Food should remain as both snakes died
        collisionState.food = foodPoints;

        // Sign and validate the collision state
        State memory candidateState = createSignedState(
            channel,
            collisionState
        );

        State[] memory updatedProofs = new State[](2);
        updatedProofs[0] = proofs[0];
        updatedProofs[1] = firstState;

        (bool valid, Asset[] memory outcome) = adjudicator.adjudicate(
            channel,
            candidateState,
            updatedProofs
        );

        assertTrue(
            valid,
            "Simultaneous food consumption collision should be valid"
        );
        assertTrue(
            collisionState.snakes[0].isDead && collisionState.snakes[1].isDead,
            "Both snakes should die"
        );
    }

    function test_InvalidFoodConsumption() public {
        (
            Channel memory channel,
            SnakeGame.GameState memory initialState,
            State[] memory proofs
        ) = createInitialGameState();

        // Set up initial state with snake near food
        SnakeGame.Point[] memory hostBody = new SnakeGame.Point[](
            INITIAL_SNAKE_LENGTH
        );
        hostBody[0] = SnakeGame.Point({x: 3, y: 4}); // Head
        hostBody[1] = SnakeGame.Point({x: 2, y: 4});
        hostBody[2] = SnakeGame.Point({x: 1, y: 4});

        SnakeGame.Point[] memory foodPoints = new SnakeGame.Point[](FOOD_COUNT);
        foodPoints[0] = SnakeGame.Point({x: 4, y: 4}); // Will be eaten
        foodPoints[1] = SnakeGame.Point({x: 7, y: 7});
        foodPoints[2] = SnakeGame.Point({x: 2, y: 2});

        initialState.snakes[0].body = hostBody;
        initialState.snakes[0].direction = SnakeGame.Direction.RIGHT;
        initialState.food = foodPoints;

        // Create first state
        State memory firstState = createSignedState(channel, initialState);

        // Create invalid next state where snake eats food but doesn't grow
        SnakeGame.GameState memory invalidState = initialState;
        invalidState.tick += 1;

        // Move snake to food position but don't grow it
        moveSnakeForward(invalidState.snakes[0]);
        moveSnakeForward(invalidState.snakes[1]);

        // Remove eaten food but don't grow snake
        SnakeGame.Point[] memory newFoodPoints = new SnakeGame.Point[](
            FOOD_COUNT
        );
        newFoodPoints[0] = SnakeGame.Point({x: 5, y: 5}); // New food position
        newFoodPoints[1] = foodPoints[1];
        newFoodPoints[2] = foodPoints[2];
        invalidState.food = newFoodPoints;

        // Sign and validate the invalid state
        State memory candidateState = createSignedState(channel, invalidState);

        State[] memory updatedProofs = new State[](2);
        updatedProofs[0] = proofs[0];
        updatedProofs[1] = firstState;

        vm.expectRevert(SnakeGame.InvalidGameState.selector);
        adjudicator.adjudicate(channel, candidateState, updatedProofs);
    }

    function test_InvalidStateTransitions() public {
        (
            Channel memory channel,
            SnakeGame.GameState memory initialState,
            State[] memory proofs
        ) = createInitialGameState();
        State memory firstState = createSignedState(channel, initialState);

        // Prepare base proofs array
        State[] memory updatedProofs = new State[](2);
        updatedProofs[0] = proofs[0];
        updatedProofs[1] = firstState;

        // Test 1: Invalid tick increment
        {
            SnakeGame.GameState memory invalidTickState = initialState;
            invalidTickState.tick += 2; // Increment by 2 instead of 1
            moveSnakeForward(invalidTickState.snakes[0]);
            moveSnakeForward(invalidTickState.snakes[1]);

            State memory candidateState = createSignedState(
                channel,
                invalidTickState
            );

            vm.expectRevert(SnakeGame.InvalidTick.selector);
            adjudicator.adjudicate(channel, candidateState, updatedProofs);
        }

        // Test 2: Invalid grid size change
        {
            SnakeGame.GameState memory invalidGridState = initialState;
            invalidGridState.tick += 1;
            invalidGridState.gridSize += 1; // Can't change grid size
            moveSnakeForward(invalidGridState.snakes[0]);
            moveSnakeForward(invalidGridState.snakes[1]);

            State memory candidateState = createSignedState(
                channel,
                invalidGridState
            );

            vm.expectRevert(SnakeGame.InvalidGameState.selector);
            adjudicator.adjudicate(channel, candidateState, updatedProofs);
        }

        // Test 3: Invalid food count change
        {
            SnakeGame.GameState memory invalidFoodState = initialState;
            invalidFoodState.tick += 1;
            // Add extra food point
            SnakeGame.Point[] memory newFood = new SnakeGame.Point[](
                FOOD_COUNT + 1
            );
            for (uint i = 0; i < FOOD_COUNT; i++) {
                newFood[i] = invalidFoodState.food[i];
            }
            newFood[FOOD_COUNT] = SnakeGame.Point({x: 0, y: 0});
            invalidFoodState.food = newFood;

            State memory candidateState = createSignedState(
                channel,
                invalidFoodState
            );

            vm.expectRevert(SnakeGame.InvalidGameState.selector);
            adjudicator.adjudicate(channel, candidateState, updatedProofs);
        }

        // Test 4: Dead snake moving
        {
            SnakeGame.GameState memory invalidDeadMoveState = initialState;
            invalidDeadMoveState.tick += 1;
            invalidDeadMoveState.snakes[0].isDead = true;
            // Try to move dead snake
            moveSnakeForward(invalidDeadMoveState.snakes[0]);
            moveSnakeForward(invalidDeadMoveState.snakes[1]);

            State memory candidateState = createSignedState(
                channel,
                invalidDeadMoveState
            );

            vm.expectRevert(SnakeGame.InvalidGameState.selector);
            adjudicator.adjudicate(channel, candidateState, updatedProofs);
        }

        // Test 5: Teleporting snake (non-continuous movement)
        {
            SnakeGame.GameState memory invalidTeleportState = initialState;
            invalidTeleportState.tick += 1;
            // Move snake to non-adjacent position
            invalidTeleportState.snakes[0].body[0] = SnakeGame.Point({
                x: 8,
                y: 8
            });
            moveSnakeForward(invalidTeleportState.snakes[1]);

            State memory candidateState = createSignedState(
                channel,
                invalidTeleportState
            );

            vm.expectRevert(SnakeGame.InvalidGameState.selector);
            adjudicator.adjudicate(channel, candidateState, updatedProofs);
        }

        // Test 6: Invalid food placement after consumption
        {
            // Position snake next to food
            SnakeGame.Point[] memory hostBody = new SnakeGame.Point[](
                INITIAL_SNAKE_LENGTH
            );
            hostBody[0] = SnakeGame.Point({x: 3, y: 4}); // Head
            hostBody[1] = SnakeGame.Point({x: 2, y: 4});
            hostBody[2] = SnakeGame.Point({x: 1, y: 4});

            SnakeGame.Point[] memory foodPoints = new SnakeGame.Point[](
                FOOD_COUNT
            );
            foodPoints[0] = SnakeGame.Point({x: 4, y: 4}); // Will be eaten
            foodPoints[1] = SnakeGame.Point({x: 7, y: 7});
            foodPoints[2] = SnakeGame.Point({x: 2, y: 2});

            initialState.snakes[0].body = hostBody;
            initialState.snakes[0].direction = SnakeGame.Direction.RIGHT;
            initialState.food = foodPoints;

            // Create state with snake eating food but invalid new food placement
            SnakeGame.GameState memory invalidFoodPlacementState = initialState;
            invalidFoodPlacementState.tick += 1;

            // Snake eats food and grows
            SnakeGame.Point[] memory newHostBody = new SnakeGame.Point[](
                INITIAL_SNAKE_LENGTH + 1
            );
            newHostBody[0] = SnakeGame.Point({x: 4, y: 4}); // New head at food position
            for (uint i = 0; i < INITIAL_SNAKE_LENGTH; i++) {
                newHostBody[i + 1] = hostBody[i];
            }
            invalidFoodPlacementState.snakes[0].body = newHostBody;

            // Place new food on snake body (invalid)
            SnakeGame.Point[] memory newFoodPoints = new SnakeGame.Point[](
                FOOD_COUNT
            );
            newFoodPoints[0] = newHostBody[1]; // Invalid - food on snake body
            newFoodPoints[1] = foodPoints[1];
            newFoodPoints[2] = foodPoints[2];
            invalidFoodPlacementState.food = newFoodPoints;

            State memory candidateState = createSignedState(
                channel,
                invalidFoodPlacementState
            );

            vm.expectRevert(SnakeGame.InvalidGameState.selector);
            adjudicator.adjudicate(channel, candidateState, updatedProofs);
        }

        // Test 7: Invalid revival of dead snake
        {
            // First create a valid state where snake dies
            SnakeGame.GameState memory deadSnakeState = initialState;
            deadSnakeState.tick += 1;
            deadSnakeState.snakes[0].isDead = true;
            moveSnakeForward(deadSnakeState.snakes[1]);

            State memory deadState = createSignedState(channel, deadSnakeState);

            // Try to revive dead snake
            SnakeGame.GameState memory invalidRevivalState = deadSnakeState;
            invalidRevivalState.tick += 1;
            invalidRevivalState.snakes[0].isDead = false; // Invalid revival
            moveSnakeForward(invalidRevivalState.snakes[0]); // Try to move revived snake
            moveSnakeForward(invalidRevivalState.snakes[1]);

            State memory candidateState = createSignedState(
                channel,
                invalidRevivalState
            );

            // Update proofs to include dead snake state
            State[] memory revivalProofs = new State[](2);
            revivalProofs[0] = proofs[0];
            revivalProofs[1] = deadState;

            vm.expectRevert(SnakeGame.InvalidGameState.selector);
            adjudicator.adjudicate(channel, candidateState, revivalProofs);
        }
    }

    // Helper functions
    function createInitialGameState()
        internal
        returns (
            Channel memory channel,
            SnakeGame.GameState memory initialState,
            State[] memory proofs
        )
    {
        // Create channel
        address[] memory participants = new address[](2);
        participants[0] = host;
        participants[1] = guest;

        channel = Channel({
            participants: participants,
            adjudicator: address(adjudicator),
            nonce: CHANNEL_NONCE
        });

        // Create and sign config
        SnakeGame.GameConfig memory config = SnakeGame.GameConfig({
            gridSize: GRID_SIZE,
            initialSnakeLength: INITIAL_SNAKE_LENGTH,
            foodCount: FOOD_COUNT
        });

        State memory configState = createSignedConfig(config);

        // Create initial state
        initialState = createDefaultGameState();

        // Create proofs array with config
        proofs = new State[](1);
        proofs[0] = configState;

        return (channel, initialState, proofs);
    }

    function createDefaultGameState()
        internal
        pure
        returns (SnakeGame.GameState memory)
    {
        // Create default snake positions
        SnakeGame.Point[] memory hostBody = new SnakeGame.Point[](
            INITIAL_SNAKE_LENGTH
        );
        for (uint8 i = 0; i < INITIAL_SNAKE_LENGTH; i++) {
            // 1 is for boundaries
            hostBody[i] = SnakeGame.Point({x: i + 1, y: 1});
        }

        SnakeGame.Point[] memory guestBody = new SnakeGame.Point[](
            INITIAL_SNAKE_LENGTH
        );
        for (uint8 i = 0; i < INITIAL_SNAKE_LENGTH; i++) {
            // 1 is for boundaries
            guestBody[i] = SnakeGame.Point({x: i + 1, y: 6});
        }

        // Create food positions
        SnakeGame.Point[] memory food = new SnakeGame.Point[](FOOD_COUNT);
        food[0] = SnakeGame.Point({x: 4, y: 4});
        food[1] = SnakeGame.Point({x: 5, y: 5});
        food[2] = SnakeGame.Point({x: 6, y: 6});

        return
            SnakeGame.GameState({
                version: 1,
                gridSize: GRID_SIZE,
                snakes: [
                    SnakeGame.Snake({
                        body: hostBody,
                        direction: SnakeGame.Direction.DOWN,
                        isDead: false
                    }),
                    SnakeGame.Snake({
                        body: guestBody,
                        direction: SnakeGame.Direction.DOWN,
                        isDead: false
                    })
                ],
                food: food,
                tick: 0,
                winner: 0
            });
    }

    function moveSnakeForward(SnakeGame.Snake memory snake) internal pure {
        SnakeGame.Point memory newHead = getNextHeadPosition(
            snake.body[0],
            snake.direction
        );

        // Move body
        for (uint i = snake.body.length - 1; i > 0; i--) {
            snake.body[i] = snake.body[i - 1];
        }
        snake.body[0] = newHead;
    }

    // Helper function to create signed game state
    function createSignedState(
        Channel memory channel,
        SnakeGame.GameState memory gameState
    ) internal returns (State memory) {
        // Create hash of the game state
        bytes32 stateHash = keccak256(abi.encode(gameState));

        // Sign with both participants
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(hostKey, stateHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(guestKey, stateHash);

        // Create signed state structure
        SnakeGame.SignedGameState memory signedState = SnakeGame
            .SignedGameState({
                state: gameState,
                signature1: Signature({v: v1, r: r1, s: s1}),
                signature2: Signature({v: v2, r: r2, s: s2})
            });

        // Create and return State structure
        return State({data: abi.encode(signedState), outcome: new Asset[](2)});
    }

    // Helper function to create signed game configuration
    function createSignedConfig(
        SnakeGame.GameConfig memory config
    ) internal returns (State memory) {
        // Create hash of the config
        bytes32 configHash = keccak256(abi.encode(config));

        // Sign with both participants
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(hostKey, configHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(guestKey, configHash);

        // Create signed config structure
        SnakeGame.SignedGameConfig memory signedConfig = SnakeGame
            .SignedGameConfig({
                config: config,
                signature1: Signature({v: v1, r: r1, s: s1}),
                signature2: Signature({v: v2, r: r2, s: s2})
            });

        // Create and return State structure
        return State({data: abi.encode(signedConfig), outcome: new Asset[](2)});
    }

    // Helper function to create signed state with single signature
    function createSingleSignedState(
        Channel memory channel,
        SnakeGame.GameState memory gameState,
        bool isHost
    ) internal returns (State memory) {
        // Create hash of the game state
        bytes32 stateHash = keccak256(abi.encode(gameState));

        // Sign with specified participant
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            isHost ? hostKey : guestKey,
            stateHash
        );

        // Create signed state structure with only one signature
        SnakeGame.SignedGameState memory signedState = SnakeGame
            .SignedGameState({
                state: gameState,
                signature1: isHost
                    ? Signature({v: v, r: r, s: s})
                    : Signature({v: 0, r: 0, s: 0}),
                signature2: isHost
                    ? Signature({v: 0, r: 0, s: 0})
                    : Signature({v: v, r: r, s: s})
            });

        // Create and return State structure
        return State({data: abi.encode(signedState), outcome: new Asset[](2)});
    }

    // Helper function to get next head position based on direction
    function getNextHeadPosition(
        SnakeGame.Point memory currentHead,
        SnakeGame.Direction direction
    ) internal pure returns (SnakeGame.Point memory) {
        SnakeGame.Point memory newHead = SnakeGame.Point({
            x: currentHead.x,
            y: currentHead.y
        });

        // Remove boundary checks - let snake move beyond boundary
        if (direction == SnakeGame.Direction.UP) {
            newHead.y -= 1;
        } else if (direction == SnakeGame.Direction.DOWN) {
            newHead.y += 1;
        } else if (direction == SnakeGame.Direction.LEFT) {
            newHead.x -= 1;
        } else if (direction == SnakeGame.Direction.RIGHT) {
            newHead.x += 1;
        }

        return newHead;
    }

    // Helper function to compare points
    function pointsEqual(
        SnakeGame.Point memory a,
        SnakeGame.Point memory b
    ) internal pure returns (bool) {
        return a.x == b.x && a.y == b.y;
    }

    // Helper function to compare snake states
    function snakesEqual(
        SnakeGame.Snake memory a,
        SnakeGame.Snake memory b
    ) internal pure returns (bool) {
        if (a.direction != b.direction) return false;
        if (a.isDead != b.isDead) return false;
        if (a.body.length != b.body.length) return false;

        for (uint i = 0; i < a.body.length; i++) {
            if (!pointsEqual(a.body[i], b.body[i])) return false;
        }

        return true;
    }

    // Helper function to deep copy a game state
    function copyGameState(
        SnakeGame.GameState memory state
    ) internal pure returns (SnakeGame.GameState memory) {
        SnakeGame.Point[] memory newFood = new SnakeGame.Point[](
            state.food.length
        );
        for (uint i = 0; i < state.food.length; i++) {
            newFood[i] = SnakeGame.Point({
                x: state.food[i].x,
                y: state.food[i].y
            });
        }

        SnakeGame.Snake[2] memory newSnakes;
        for (uint i = 0; i < 2; i++) {
            SnakeGame.Point[] memory newBody = new SnakeGame.Point[](
                state.snakes[i].body.length
            );
            for (uint j = 0; j < state.snakes[i].body.length; j++) {
                newBody[j] = SnakeGame.Point({
                    x: state.snakes[i].body[j].x,
                    y: state.snakes[i].body[j].y
                });
            }
            newSnakes[i] = SnakeGame.Snake({
                body: newBody,
                direction: state.snakes[i].direction,
                isDead: state.snakes[i].isDead
            });
        }

        return
            SnakeGame.GameState({
                version: state.version,
                gridSize: state.gridSize,
                snakes: newSnakes,
                food: newFood,
                tick: state.tick,
                winner: state.winner
            });
    }
}
