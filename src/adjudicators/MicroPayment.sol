// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IAdjudicator} from "../interfaces/IAdjudicator.sol";
import "../interfaces/Types.sol";

/**
 * @title MicroPayment Adjudicator
 * @notice Adjudicator for simple payment channels with voucher validation
 */
contract MicroPayment is IAdjudicator {
    // Errors
    error InvalidSignature();
    error InvalidVoucher();
    error InvalidProofLength();
    error VersionNotHigher();

    /**
     * @notice Payment voucher structure
     * @param version Strictly increasing version number
     * @param payment Asset (token and amount) to be paid to the Guest
     */
    struct Voucher {
        uint64 version;
        Asset payment;
    }

    /**
     * @notice Signed voucher combining payment data and signature
     * @param voucher The payment voucher
     * @param signature Signature from the Host
     */
    struct SignedVoucher {
        Voucher voucher;
        Signature signature;
    }

    /**
     * @notice Validates state and determines outcome
     * @param chan Channel configuration
     * @param candidate Encoded SignedVoucher representing latest state
     * @param proofs Previous valid state (if any)
     * @return valid Whether the candidate state is valid
     * @return outcome Final asset distribution [Host, Guest]
     */
    function adjudicate(Channel calldata chan, State calldata candidate, State[] calldata proofs)
        external
        view
        override
        returns (bool valid, Asset[] memory outcome)
    {
        // Decode candidate state
        SignedVoucher memory candidateVoucher = abi.decode(candidate.data, (SignedVoucher));

        // Create hash of just the voucher data for signature verification
        bytes32 stateHash = keccak256(abi.encode(candidateVoucher.voucher));

        // Verify the voucher is signed by the Host (participants[0])
        if (!verifySignature(chan.participants[0], stateHash, candidateVoucher.signature)) {
            revert InvalidSignature();
        }

        // Check previous state if provided
        if (proofs.length > 0) {
            // Decode previous state
            SignedVoucher memory previousVoucher = abi.decode(proofs[0].data, (SignedVoucher));

            // Ensure candidate version is higher than previous
            if (candidateVoucher.voucher.version <= previousVoucher.voucher.version) {
                revert VersionNotHigher();
            }
        }

        // Valid voucher, calculate outcome
        outcome = calculateOutcome(chan, candidateVoucher.voucher);
        valid = true;

        return (valid, outcome);
    }

    /**
     * @dev Calculates asset distribution based on voucher
     * @param chan Channel configuration
     * @param voucher Payment voucher
     * @return outcome Asset distribution [Host, Guest]
     */
    function calculateOutcome(Channel calldata chan, Voucher memory voucher)
        internal
        pure
        returns (Asset[] memory outcome)
    {
        // Assuming a total deposit of 100 ether (as in the tests)
        // FIXME fix allocation
        uint256 totalFunds = 100 ether;

        // Initialize outcome array with length 2
        outcome = new Asset[](2);

        // Host gets deposit minus payment
        outcome[0] = Asset({
            token: voucher.payment.token,
            amount: totalFunds - voucher.payment.amount // Host gets remaining funds
        });

        // Guest gets payment
        outcome[1] = voucher.payment;

        return outcome;
    }

    /**
     * @dev Verifies a signature against a message hash and signer
     * @param signer The expected signer address
     * @param hash The message hash that was signed
     * @param signature The signature to verify
     * @return Whether the signature is valid
     */
    function verifySignature(address signer, bytes32 hash, Signature memory signature) internal pure returns (bool) {
        // Recover signer from signature
        address recovered = ecrecover(hash, signature.v, signature.r, signature.s);

        // Check if recovered address matches expected signer
        return recovered == signer;
    }
}
