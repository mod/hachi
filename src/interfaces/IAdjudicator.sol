// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./Types.sol";

/**
 * @title Adjudicator Interface
 * @notice Interface for state validation and outcome determination
 */
interface IAdjudicator {
    function adjudicate(Channel calldata chan, State calldata candidate, State[] calldata proofs)
        external
        view
        returns (bool valid, Asset[] memory outcome);
}
