// SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;

import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "./interfaces/ICallDelegator.sol";
import "./interfaces/IPromissoryNote.sol";
import "./interfaces/IAssetVault.sol";
import "./interfaces/IFeeController.sol";
import "./interfaces/ILoanCore.sol";

import "./PromissoryNote.sol";
import "./vault/OwnableERC721.sol";

// TODO: Better natspec
// TODO: Re-Entrancy mechanisms just for a safegaurd? - Kyle/Shipyard

/**
 * @dev LoanCore contract - core contract for creating, repaying, and claiming collateral for PawnFi loans
 */
contract LoanCore is ILoanCore, AccessControl, Pausable, ICallDelegator {
    using Counters for Counters.Counter;
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    bytes32 public constant ORIGINATOR_ROLE = keccak256("ORIGINATOR_ROLE");
    bytes32 public constant REPAYER_ROLE = keccak256("REPAYER_ROLE");
    bytes32 public constant FEE_CLAIMER_ROLE = keccak256("FEE_CLAIMER_ROLE");

    // Interest rate parameters
    uint256 public constant INTEREST_DENOMINATOR = 1 * 10**18;
    uint256 public constant BASIS_POINTS_DENOMINATOR = 10000;

    Counters.Counter private loanIdTracker;
    mapping(uint256 => LoanLibrary.LoanData) private loans;
    mapping(address => mapping(uint256 => bool)) private collateralInUse;
    IPromissoryNote public immutable override borrowerNote;
    IPromissoryNote public immutable override lenderNote;
    IFeeController public override feeController;

    uint256 private constant BPS_DENOMINATOR = 10_000; // 10k bps per whole

    constructor(IFeeController _feeController) {
        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _setupRole(FEE_CLAIMER_ROLE, _msgSender());
        // only those with FEE_CLAIMER_ROLE can update or grant FEE_CLAIMER_ROLE
        _setRoleAdmin(FEE_CLAIMER_ROLE, FEE_CLAIMER_ROLE);

        feeController = _feeController;

        // TODO: Why are these deployed? Can these be provided beforehand?
        //       Even updatable with note addresses going in LoanData?
        borrowerNote = new PromissoryNote("PawnFi Borrower Note", "pBN");
        lenderNote = new PromissoryNote("PawnFi Lender Note", "pLN");

        // Avoid having loanId = 0
        loanIdTracker.increment();
    }

    // ============================= V1 FUNCTIONALITY ==================================

    /**
     * @inheritdoc ILoanCore
     */
    function getLoan(uint256 loanId) external view override returns (LoanLibrary.LoanData memory loanData) {
        return loans[loanId];
    }

    /**
     * @inheritdoc ILoanCore
     */
    function createLoan(LoanLibrary.LoanTerms calldata terms)
        external
        override
        whenNotPaused
        onlyRole(ORIGINATOR_ROLE)
        returns (uint256 loanId)
    {
        require(terms.durationSecs > 0, "LoanCore::create: Loan is already expired");
        require(
            !collateralInUse[terms.collateralAddress][terms.collateralId],
            "LoanCore::create: Collateral token already in use"
        );

        // Interest rate must be greater than or equal to 0.01%
        require(
            terms.interestRate / INTEREST_DENOMINATOR >= 1,
            "LoanCore::create: Interest must be greater than 0.01%"
        );

        // Number of installments must be an even number.
        require(
            terms.numInstallments % 2 == 0 && terms.numInstallments < 1000000,
            "LoanCore::create: Even num of installments and must be < 1 mill"
        );

        // get current loanId and increment for next function call
        loanId = loanIdTracker.current();
        loanIdTracker.increment();
        // Using loanId, set inital LoanData state
        loans[loanId] = LoanLibrary.LoanData({
            borrowerNoteId: 0,
            lenderNoteId: 0,
            terms: terms,
            state: LoanLibrary.LoanState.Created,
            dueDate: block.timestamp + terms.durationSecs,
            startDate: block.timestamp,
            balance: terms.principal,
            balancePaid: 0,
            lateFeesAccrued: 0,
            numInstallmentsPaid: 0
        });
        // set collateral to in use.
        collateralInUse[terms.collateralAddress][terms.collateralId] = true;

        emit LoanCreated(terms, loanId);
    }

    /**
     * @inheritdoc ILoanCore
     */
    function startLoan(
        address lender,
        address borrower,
        uint256 loanId
    ) external override whenNotPaused onlyRole(ORIGINATOR_ROLE) {
        LoanLibrary.LoanData memory data = loans[loanId];

        // Ensure valid initial loan state
        require(data.state == LoanLibrary.LoanState.Created, "LoanCore::start: Invalid loan state");

        // Pull collateral token and principal
        IERC721(data.terms.collateralAddress).transferFrom(_msgSender(), address(this), data.terms.collateralId);
        IERC20(data.terms.payableCurrency).safeTransferFrom(_msgSender(), address(this), data.terms.principal);

        // Distribute notes and principal
        loans[loanId].state = LoanLibrary.LoanState.Active;
        uint256 borrowerNoteId = borrowerNote.mint(borrower, loanId);
        uint256 lenderNoteId = lenderNote.mint(lender, loanId);

        loans[loanId] = LoanLibrary.LoanData(
            borrowerNoteId,
            lenderNoteId,
            data.terms,
            LoanLibrary.LoanState.Active,
            data.dueDate,
            data.startDate,
            data.balance,
            data.balancePaid,
            data.lateFeesAccrued,
            data.numInstallmentsPaid
        );

        IERC20(data.terms.payableCurrency).safeTransfer(borrower, getPrincipalLessFees(data.terms.principal));

        emit LoanStarted(loanId, lender, borrower);
    }

    /**
     * @notice Calculate the interest due.
     *
     * @dev Interest and principal must be entered as base 10**18
     *
     * @param principal                    Principal amount in the loan terms
     * @param interestRate                 Interest rate in the loan terms
     */
    function getFullInterestAmount(uint256 principal, uint256 interestRate) internal view returns (uint256 total) {
        // Interest rate to be greater than or equal to 0.01%
        require(interestRate / INTEREST_DENOMINATOR >= 1, "Interest must be greater than 0.01%.");

        return principal + ((principal * (interestRate / INTEREST_DENOMINATOR)) / BASIS_POINTS_DENOMINATOR);
    }

    /**
     * @inheritdoc ILoanCore
     */
    function repay(uint256 loanId) external override onlyRole(REPAYER_ROLE) {
        LoanLibrary.LoanData memory data = loans[loanId];
        // Ensure valid initial loan state
        require(data.state == LoanLibrary.LoanState.Active, "LoanCore::repay: Invalid loan state");

        // ensure repayment was valid
        uint256 returnAmount = getFullInterestAmount(data.terms.principal, data.terms.interestRate);
        require(returnAmount > 0, "No payment due.");
        IERC20(data.terms.payableCurrency).safeTransferFrom(_msgSender(), address(this), returnAmount);

        address lender = lenderNote.ownerOf(data.lenderNoteId);
        address borrower = borrowerNote.ownerOf(data.borrowerNoteId);

        // state changes and cleanup
        // NOTE: these must be performed before assets are released to prevent reentrance
        loans[loanId].state = LoanLibrary.LoanState.Repaid;
        collateralInUse[data.terms.collateralAddress][data.terms.collateralId] = false;

        lenderNote.burn(data.lenderNoteId);
        borrowerNote.burn(data.borrowerNoteId);

        // asset and collateral redistribution
        IERC20(data.terms.payableCurrency).safeTransfer(lender, returnAmount);
        IERC721(data.terms.collateralAddress).transferFrom(address(this), borrower, data.terms.collateralId);

        emit LoanRepaid(loanId);
    }

    /**
     * @inheritdoc ILoanCore
     */
    function claim(uint256 loanId) external override whenNotPaused onlyRole(REPAYER_ROLE) {
        LoanLibrary.LoanData memory data = loans[loanId];

        // Ensure valid initial loan state
        require(data.state == LoanLibrary.LoanState.Active, "LoanCore::claim: Invalid loan state");
        require(data.dueDate < block.timestamp, "LoanCore::claim: Loan not expired");

        address lender = lenderNote.ownerOf(data.lenderNoteId);

        // NOTE: these must be performed before assets are released to prevent reentrance
        loans[loanId].state = LoanLibrary.LoanState.Defaulted;
        collateralInUse[data.terms.collateralAddress][data.terms.collateralId] = false;

        lenderNote.burn(data.lenderNoteId);
        borrowerNote.burn(data.borrowerNoteId);

        // collateral redistribution
        IERC721(data.terms.collateralAddress).transferFrom(address(this), lender, data.terms.collateralId);

        emit LoanClaimed(loanId);
    }

    /**
     * Take a principal value and return the amount less protocol fees
     */
    function getPrincipalLessFees(uint256 principal) internal view returns (uint256) {
        return principal.sub(principal.mul(feeController.getOriginationFee()).div(BPS_DENOMINATOR));
    }

    // ======================== INSTALLMENT SPECIFIC OPERATIONS =============================

    /**
     * @dev Called from RepaymentController when paying back an installment loan.
     * New loan state parameters are calculated in the Repayment Controller.
     * Based on if the _paymentToPrincipal is greater than the current balance
     * the loan state is updated. (0 = minimum payment sent, > 0 pay down principal)
     * The paymentTotal (_paymentToPrincipal + _paymentToLateFees) is always transferred to the lender.
     *
     * @param _loanId                       Used to get LoanData
     * @param _paymentToPrincipal           Amount sent in addition to minimum amount due, used to pay down principal
     * @param _currentMissedPayments        Number of payments missed since the last isntallment payment
     * @param _paymentToLateFees            Amount due in only late fees.
     */
    function repayPart(
        uint256 _loanId,
        uint256 _paymentToPrincipal,
        uint256 _currentMissedPayments,
        uint256 _paymentToInterest,
        uint256 _paymentToLateFees
    ) external override onlyRole(REPAYER_ROLE) {
        LoanLibrary.LoanData storage data = loans[_loanId];
        // ensure valid initial loan state
        require(data.state == LoanLibrary.LoanState.Active, "LoanCore::repay: Invalid loan state");
        // calculate total sent by borrower
        uint256 paymentTotal = _paymentToPrincipal + _paymentToLateFees + _paymentToInterest;
        IERC20(data.terms.payableCurrency).safeTransferFrom(_msgSender(), address(this), paymentTotal);
        // get the lender and borrower
        address lender = lenderNote.ownerOf(data.lenderNoteId);
        address borrower = borrowerNote.ownerOf(data.borrowerNoteId);
        // update common state
        data.lateFeesAccrued = data.lateFeesAccrued + _paymentToLateFees;
        data.numInstallmentsPaid = data.numInstallmentsPaid + _currentMissedPayments + 1;

        // * If payment sent is exact or extra than remaining principal
        if (_paymentToPrincipal > data.balance || _paymentToPrincipal == data.balance) {
            // set the loan state to repaid
            data.state = LoanLibrary.LoanState.Repaid;
            collateralInUse[data.terms.collateralAddress][data.terms.collateralId] = false;

            // return the difference to borrower
            if (_paymentToPrincipal > data.balance) {
                uint256 diffAmount = _paymentToPrincipal - data.balance;
                // update paymentTotal since extra amount sent
                IERC20(data.terms.payableCurrency).safeTransfer(borrower, diffAmount);
            }
            data.balancePaid = data.balancePaid + paymentTotal;

            // state changes and cleanup
            lenderNote.burn(data.lenderNoteId);
            borrowerNote.burn(data.borrowerNoteId);

            // Loan is fully repaid, redistribute asset and collateral.
            IERC20(data.terms.payableCurrency).safeTransfer(lender, paymentTotal);
            IERC721(data.terms.collateralAddress).transferFrom(address(this), borrower, data.terms.collateralId);

            // update balance state
            data.balance = 0;

            emit LoanRepaid(_loanId);
        }
        // * Else, (mid loan payment)
        else {
            // update balance state
            data.balance = data.balance - _paymentToPrincipal;
            data.balancePaid = data.balancePaid + paymentTotal;

            // minimum repayment events will emit 0 and unchanged principal
            emit InstallmentPaymentReceived(_loanId, _paymentToPrincipal, data.balance);
        }
    }

    // ============================= ADMIN FUNCTIONS ==================================

    /**
     * @dev Set the fee controller to a new value
     *
     * Requirements:
     *
     * - Must be called by the owner of this contract
     */
    function setFeeController(IFeeController _newController) external onlyRole(FEE_CLAIMER_ROLE) {
        feeController = _newController;
    }

    /**
     * @dev Claim the protocol fees for the given token
     *
     * @param token - The address of the ERC20 token to claim fees for
     *
     * Requirements:
     *
     * - Must be called by the owner of this contract
     */
    function claimFees(IERC20 token) external onlyRole(FEE_CLAIMER_ROLE) {
        // any token balances remaining on this contract are fees owned by the protocol
        uint256 amount = token.balanceOf(address(this));
        token.safeTransfer(_msgSender(), amount);
        emit FeesClaimed(address(token), _msgSender(), amount);
    }

    /**
     * @dev Triggers stopped state.
     *
     * Requirements:
     *
     * - The contract must not be paused.
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @dev Returns to normal state.
     *
     * Requirements:
     *
     * - The contract must be paused.
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @inheritdoc ICallDelegator
     */
    function canCallOn(address caller, address vault) external view override returns (bool) {
        // if the collateral is not currently being used in a loan, disallow
        if (!collateralInUse[OwnableERC721(vault).ownershipToken()][uint256(uint160(vault))]) {
            return false;
        }

        for (uint256 i = 0; i < borrowerNote.balanceOf(caller); i++) {
            uint256 borrowerNoteId = borrowerNote.tokenOfOwnerByIndex(caller, i);
            uint256 loanId = borrowerNote.loanIdByNoteId(borrowerNoteId);
            // if the borrower is currently borrowing against this vault,
            // return true
            if (loans[loanId].terms.collateralId == uint256(uint160(vault))) {
                return true;
            }
        }

        return false;
    }
}
