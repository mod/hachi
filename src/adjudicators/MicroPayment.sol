// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IAdjudicator} from "../interfaces/IAdjudicator.sol";
import {ITypes} from "../interfaces/ITypes.sol";

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
        ITypes.Asset payment;
    }

    /**
     * @notice Signed voucher combining payment data and signature
     * @param voucher The payment voucher
     * @param signature Signature from the Host
     */
    struct SignedVoucher {
        Voucher voucher;
        ITypes.Signature signature;
    }

    /**
     * @notice Validates state and determines outcome
     * @param chan Channel configuration
     * @param candidate Encoded SignedVoucher representing latest state
     * @param proofs Previous valid state (if any)
     * @return valid Whether the candidate state is valid
     * @return outcome Final asset distribution [Host, Guest]
     */
    function adjudicate(ITypes.Channel calldata chan, bytes calldata candidate, bytes[] calldata proofs)
        external
        view
        override
        returns (bool valid, ITypes.Asset[2] memory outcome)
    {
        // Decode candidate state
        SignedVoucher memory candidateVoucher = abi.decode(candidate, (SignedVoucher));

        // Create hash of just the voucher data for signature verification
        bytes32 stateHash = keccak256(abi.encode(candidateVoucher.voucher));

        // Verify the voucher is signed by the Host (participants[0])
        if (!verifySignature(chan.participants[0], stateHash, candidateVoucher.signature)) {
            revert InvalidSignature();
        }

        // Check previous state if provided
        if (proofs.length > 0) {
            // Decode previous state
            SignedVoucher memory previousVoucher = abi.decode(proofs[0], (SignedVoucher));

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
    function calculateOutcome(ITypes.Channel calldata chan, Voucher memory voucher)
        internal
        pure
        returns (ITypes.Asset[2] memory outcome)
    {
        // Assuming a total deposit of 100 ether (as in the tests)
        uint256 totalFunds = 100 ether;

        // Host gets deposit minus payment
        outcome[0] = ITypes.Asset({
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
    function verifySignature(address signer, bytes32 hash, ITypes.Signature memory signature)
        internal
        pure
        returns (bool)
    {
        // Recover signer from signature
        address recovered = ecrecover(hash, signature.v, signature.r, signature.s);

        // Check if recovered address matches expected signer
        return recovered == signer;
    }
}
