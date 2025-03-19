// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ITypes} from "./ITypes.sol";

/**
 * @title Adjudicator Interface
 * @notice Interface for state validation and outcome determination
 */
interface IAdjudicator {
    function adjudicate(ITypes.Channel calldata chan, bytes calldata candidate, bytes[] calldata proofs)
        external
        view
        returns (bool valid, ITypes.Asset[2] memory outcome);
}
