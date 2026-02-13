// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRatchetVault} from "./interfaces/IRatchetVault.sol";

/// @title RatchetVault
/// @notice Holds team token allocation and sells reactively into buys
/// @dev The reactive sell rate can only decrease (ratchet down), never increase.
///      Vault sells are capped at 0.1% per trigger and 0.135% per day of starting balance.
///      When <=1% of starting balance remains, selling stops permanently.
contract RatchetVault is IRatchetVault {
    using SafeERC20 for IERC20;

    /// @notice Maximum reactive sell rate (10% = 1000 bps)
    uint256 public constant MAX_REACTIVE_SELL_RATE = 1000;
    uint256 public constant BPS_DENOMINATOR = 10000;
    /// @notice Maximum sell per trigger: 0.1% of starting balance
    uint256 public constant MAX_SELL_PER_TRIGGER_BPS = 10;
    /// @notice Maximum daily sell rate numerator: 0.135%
    uint256 public constant MAX_DAILY_RATE = 135;
    /// @notice Denominator for daily rate: 0.001% precision
    uint256 public constant RATE_DENOMINATOR = 100_000;
    /// @notice Shutoff threshold: 1% of starting balance
    uint256 public constant SHUTOFF_THRESHOLD_BPS = 100;

    /// @notice The factory that deployed this vault (can initialize token)
    address public immutable FACTORY;
    /// @notice The hook contract authorized to trigger reactive sells
    address public immutable HOOK;

    /// @notice The team address that receives tokens and controls the ratchet
    address private teamRecipient_;
    /// @notice Pending team recipient for two-step transfer
    address public pendingTeamRecipient;
    /// @notice The creator identifier string
    string public creator;
    /// @notice Whether the vault has been claimed by its creator
    bool public claimed;

    /// @notice The token this vault holds (set once by factory after token deployment)
    address public TOKEN;
    /// @notice Current reactive sell rate in basis points (0-1000)
    uint256 public reactiveSellRate;

    /// @notice The starting token balance of the vault (set on initialize)
    uint256 public vaultStartingBalance;
    /// @notice Cumulative tokens sold from the vault
    uint256 public totalSold;
    /// @notice Whether the vault has finished selling (<=1% remaining)
    bool public vaultFinished;
    /// @notice The day number (block.timestamp / 1 days) of the last sell
    uint256 public lastSellDay;
    /// @notice Cumulative tokens sold within the current day
    uint256 public dailySold;

    error OnlyHook();
    error OnlyTeam();
    error OnlyFactory();
    error RateCanOnlyDecrease();
    error RateTooHigh();
    error AlreadyInitialized();
    error ZeroAddress();
    error NotYetClaimed();
    error AlreadyClaimed();
    error OnlyPendingTeam();
    error NoPendingTransfer();
    error VaultAlreadyFinished();
    error VaultNotFinished();

    modifier onlyHook() {
        _checkHook();
        _;
    }

    modifier onlyTeam() {
        _checkTeam();
        _;
    }

    function _checkHook() internal view {
        if (msg.sender != HOOK) revert OnlyHook();
    }

    function _checkTeam() internal view {
        if (msg.sender != teamRecipient_) revert OnlyTeam();
    }

    /// @notice Deploy a new vault for a token launch
    /// @param hook_ The hook contract authorized to call onBuy
    /// @param teamRecipient__ Address that can decrease rate and release final tokens
    /// @param initialReactiveSellRate_ Starting sell rate in bps (max 1000 = 10%)
    /// @param creator_ Creator identifier string
    constructor(
        address hook_,
        address teamRecipient__,
        uint256 initialReactiveSellRate_,
        string memory creator_
    ) {
        if (hook_ == address(0)) revert ZeroAddress();
        if (teamRecipient__ == address(0)) revert ZeroAddress();
        if (initialReactiveSellRate_ > MAX_REACTIVE_SELL_RATE) revert RateTooHigh();

        FACTORY = msg.sender;
        HOOK = hook_;
        teamRecipient_ = teamRecipient__;
        reactiveSellRate = initialReactiveSellRate_;
        creator = creator_;
    }

    /// @notice Initialize the token address and record starting balance
    /// @param token_ The token address this vault will hold
    function initialize(address token_) external {
        if (msg.sender != FACTORY) revert OnlyFactory();
        if (TOKEN != address(0)) revert AlreadyInitialized();
        if (token_ == address(0)) revert ZeroAddress();
        TOKEN = token_;
        vaultStartingBalance = IERC20(token_).balanceOf(address(this));
    }

    /// @notice Called by hook when someone buys tokens. Sells a percentage into the buy.
    /// @param buyAmount The amount of tokens being bought
    /// @return sellAmount The amount of tokens sold from vault (transferred to hook)
    function onBuy(uint256 buyAmount) external onlyHook returns (uint256 sellAmount) {
        // 1. If vaultFinished or rate is 0, no sell
        if (vaultFinished || reactiveSellRate == 0) return 0;

        // 2. Check balance against shutoff reserve
        uint256 balance = IERC20(TOKEN).balanceOf(address(this));
        uint256 shutoffReserve =
            (vaultStartingBalance * SHUTOFF_THRESHOLD_BPS) / BPS_DENOMINATOR;
        if (balance <= shutoffReserve) {
            vaultFinished = true;
            emit VaultFinished(address(this));
            return 0;
        }

        // 3. Reset daily counter if new day
        uint256 today = block.timestamp / 1 days;
        if (today != lastSellDay) {
            lastSellDay = today;
            dailySold = 0;
        }

        // 4. Calculate sell amount based on buy amount and rate
        sellAmount = (buyAmount * reactiveSellRate) / BPS_DENOMINATOR;

        // 5. Cap at per-trigger maximum: 0.1% of starting balance
        uint256 maxTrigger =
            (vaultStartingBalance * MAX_SELL_PER_TRIGGER_BPS) / BPS_DENOMINATOR;
        if (sellAmount > maxTrigger) {
            sellAmount = maxTrigger;
        }

        // 6. Cap at daily remaining: 0.135% of starting balance per day
        uint256 maxDailyTotal =
            (vaultStartingBalance * MAX_DAILY_RATE) / RATE_DENOMINATOR;
        uint256 dailyRemaining = maxDailyTotal > dailySold ? maxDailyTotal - dailySold : 0;
        if (sellAmount > dailyRemaining) {
            sellAmount = dailyRemaining;
        }

        // 7. Cap so balance doesn't go below shutoff reserve
        uint256 maxForReserve = balance - shutoffReserve;
        if (sellAmount > maxForReserve) {
            sellAmount = maxForReserve;
        }

        // 8. If nothing to sell, return 0
        if (sellAmount == 0) return 0;

        // 9. Update state
        dailySold += sellAmount;
        totalSold += sellAmount;
        lastSellDay = today;

        // 10. Check if remaining balance hits shutoff
        if (balance - sellAmount <= shutoffReserve) {
            vaultFinished = true;
            emit VaultFinished(address(this));
        }

        // 11. Transfer and emit
        IERC20(TOKEN).safeTransfer(HOOK, sellAmount);
        emit ReactiveSell(msg.sender, buyAmount, sellAmount, reactiveSellRate);

        return sellAmount;
    }

    /// @notice Decrease the reactive sell rate. Can only go down, never up.
    /// @param newRate New rate in basis points, must be strictly less than current
    function decreaseRate(uint256 newRate) external onlyTeam {
        if (!claimed) revert NotYetClaimed();
        if (newRate >= reactiveSellRate) revert RateCanOnlyDecrease();

        uint256 oldRate = reactiveSellRate;
        reactiveSellRate = newRate;

        emit RatchetDecreased(oldRate, newRate);
    }

    /// @notice Release remaining tokens to team after vault is finished
    function releaseFinalTokens() external onlyTeam {
        if (!vaultFinished) revert VaultNotFinished();
        if (!claimed) revert NotYetClaimed();

        uint256 balance = IERC20(TOKEN).balanceOf(address(this));
        if (balance > 0) {
            IERC20(TOKEN).safeTransfer(teamRecipient_, balance);
        }

        emit FinalTokensReleased(teamRecipient_, balance);
    }

    /// @notice Set the vault as claimed with a new team recipient
    /// @dev Only callable by the factory contract. Cannot re-claim an already claimed vault.
    /// @param newRecipient The new team recipient address
    function setClaimed(address newRecipient) external {
        if (msg.sender != FACTORY) revert OnlyFactory();
        if (claimed) revert AlreadyClaimed();
        if (newRecipient == address(0)) revert ZeroAddress();
        teamRecipient_ = newRecipient;
        claimed = true;

        emit CreatorClaimed(address(this), newRecipient);
    }

    /// @notice Propose a new team recipient (first step of two-step transfer)
    /// @dev Only callable by current team recipient. Must be claimed first.
    /// @param newRecipient The proposed new team recipient
    function proposeTeamTransfer(address newRecipient) external onlyTeam {
        if (!claimed) revert NotYetClaimed();
        if (newRecipient == address(0)) revert ZeroAddress();
        pendingTeamRecipient = newRecipient;
        emit TeamTransferProposed(teamRecipient_, newRecipient);
    }

    /// @notice Accept the team recipient role (second step of two-step transfer)
    /// @dev Only callable by the pending team recipient
    function acceptTeamTransfer() external {
        if (msg.sender != pendingTeamRecipient) revert OnlyPendingTeam();
        emit TeamTransferAccepted(teamRecipient_, msg.sender);
        teamRecipient_ = msg.sender;
        pendingTeamRecipient = address(0);
    }

    /// @notice Get the token address (legacy getter)
    function token() external view returns (address) {
        return TOKEN;
    }

    /// @notice Get the hook address (legacy getter)
    function hook() external view returns (address) {
        return HOOK;
    }

    /// @notice Get the team recipient address
    function teamRecipient() external view returns (address) {
        return teamRecipient_;
    }
}
