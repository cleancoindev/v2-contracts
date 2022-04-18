// SPDX-License-Identifier: MIT

pragma solidity ^0.8.11;

library LoanLibrary {
    /**
     * @dev Enum describing the current state of a loan
     * State change flow:
     *  Created -> Active -> Repaid
     *                    -> Defaulted
     */
    enum LoanState {
        // We need a default that is not 'Created' - this is the zero value
        DUMMY_DO_NOT_USE,
        // The loan data is stored, but not initiated yet.
        Created,
        // The loan has been initialized, funds have been delivered to the borrower and the collateral is held.
        Active,
        // The loan has been repaid, and the collateral has been returned to the borrower. This is a terminal state.
        Repaid,
        // The loan was delinquent and collateral claimed by the lender. This is a terminal state.
        Defaulted
    }

    /**
     * @dev The raw terms of a loan
     */
    struct LoanTerms {
        // The number of seconds representing relative due date of the loan
        uint256 durationSecs;
        // The amount of principal in terms of the payableCurrency
        uint256 principal;
        // The amount of interest in terms of the payableCurrency
        uint256 interest;
        // The tokenID of the address holding the collateral
        /// @dev Can be an AssetVault, or the NFT contract for unbundled collateral
        address collateralAddress;
        // The tokenID of the collateral
        uint256 collateralId;
        // The payable currency for the loan principal and interest
        address payableCurrency;
    }

    /**
     * @dev Modification of loan terms, used for signing only.
     *      Instead of a collateralId, a list of predicates
     *      is defined by 'bytes' in items.
     */
    struct LoanTermsWithItems {
        // The number of seconds representing relative due date of the loan
        uint256 durationSecs;
        // The amount of principal in terms of the payableCurrency
        uint256 principal;
        // The amount of interest in terms of the payableCurrency
        uint256 interest;
        // The tokenID of the address holding the collateral
        /// @dev Must be an AssetVault for LoanTermsWithItems
        address collateralAddress;
        // An encoded list of predicates
        bytes items;
        // The payable currency for the loan principal and interest
        address payableCurrency;
    }

    /**
     * @dev Predicate for item-based verifications
     */
    struct Predicate {
        // The encoded predicate, to decoded and parsed by the verifier contract
        bytes data;
        // The verifier contract
        address verifier;
    }

    /**
     * @dev The data of a loan. This is stored once the loan is Active
     */
    struct LoanData {
        // The tokenId of the borrower note
        uint256 borrowerNoteId;
        // The tokenId of the lender note
        uint256 lenderNoteId;
        // The raw terms of the loan
        LoanTerms terms;
        // The current state of the loan
        LoanState state;
        // Timestamp representing absolute due date date of the loan
        uint256 dueDate;
    }
}
