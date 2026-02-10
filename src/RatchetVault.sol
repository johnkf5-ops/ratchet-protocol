// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRatchetVault} from "./interfaces/IRatchetVault.sol";

/// @title RatchetVault
/// @notice Holds team token allocation and sells reactively into buys
/// @dev The reactive sell rate can only decrease (ratchet down), never increase.
///      This creates a one-way commitment mechanism for the team.
contract RatchetVault is IRatchetVault {
    using SafeERC20 for IERC20;

    /// @notice Maximum reactive sell rate (10% = 1000 bps)
    uint256 public constant MAX_REACTIVE_SELL_RATE = 1000;
    uint256 public constant BPS_DENOMINATOR = 10000;
    /// @notice Maximum reactive sell per buy as fraction of vault balance (5%)
    uint256 public constant MAX_SELL_PER_BUY_BPS = 500;
    /// @notice Time after deployment before unclaimed vaults can be expired
    uint256 public constant CLAIM_EXPIRY = 90 days;

    /// @notice The factory that deployed this vault (can initialize token)
    address public immutable FACTORY;
    /// @notice The hook contract authorized to trigger reactive sells
    address public immutable HOOK;
    /// @notice Timestamp when vault was deployed
    uint256 public immutable deployedAt;

    /// @notice The team address that receives ETH fees and controls the ratchet
    address private teamRecipient_;
    /// @notice The creator identifier string
    string public creator;
    /// @notice Whether the vault has been claimed by its creator
    bool public claimed;

    /// @notice The token this vault holds (set once by factory after token deployment)
    address public TOKEN;
    /// @notice Current reactive sell rate in basis points (0-1000)
    uint256 public reactiveSellRate;
    /// @notice ETH fees accumulated from hook, claimable by team
    uint256 public accumulatedFees;
    /// @notice Last block number when a reactive sell occurred (for per-block cap)
    uint256 private lastSellBlock;
    /// @notice Cumulative sell amount in the current block
    uint256 private blockSellAmount;

    error OnlyHook();
    error OnlyTeam();
    error OnlyFactory();
    error RateCanOnlyDecrease();
    error RateTooHigh();
    error NoFeesToClaim();
    error AlreadyInitialized();
    error ZeroAddress();
    error NotYetClaimed();
    error ClaimNotExpired();
    error AlreadyClaimed();

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
    /// @param teamRecipient__ Address that can decrease rate and claim fees
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
        deployedAt = block.timestamp;
        teamRecipient_ = teamRecipient__;
        reactiveSellRate = initialReactiveSellRate_;
        creator = creator_;
    }

    /// @notice Initialize the token address (called by factory after token deployment)
    /// @param token_ The token address this vault will hold
    function initialize(address token_) external {
        if (msg.sender != FACTORY) revert OnlyFactory();
        if (TOKEN != address(0)) revert AlreadyInitialized();
        if (token_ == address(0)) revert ZeroAddress();
        TOKEN = token_;
    }

    /// @notice Called by hook when someone buys tokens. Sells a percentage into the buy.
    /// @param buyAmount The amount of tokens being bought
    /// @return sellAmount The amount of tokens sold from vault (transferred to hook)
    function onBuy(uint256 buyAmount) external onlyHook returns (uint256 sellAmount) {
        if (reactiveSellRate == 0) return 0;

        // Calculate reactive sell amount as percentage of buy
        sellAmount = (buyAmount * reactiveSellRate) / BPS_DENOMINATOR;

        // Cap at available balance
        uint256 balance = IERC20(TOKEN).balanceOf(address(this));
        if (sellAmount > balance) {
            sellAmount = balance;
        }

        // Per-block cumulative cap to limit flash-loan / split-buy extraction
        if (block.number != lastSellBlock) {
            lastSellBlock = block.number;
            blockSellAmount = 0;
        }
        uint256 blockStartBalance = balance + blockSellAmount;
        uint256 maxBlockSell = (blockStartBalance * MAX_SELL_PER_BUY_BPS) / BPS_DENOMINATOR;
        if (blockSellAmount + sellAmount > maxBlockSell) {
            sellAmount = maxBlockSell > blockSellAmount ? maxBlockSell - blockSellAmount : 0;
        }
        blockSellAmount += sellAmount;

        if (sellAmount > 0) {
            IERC20(TOKEN).safeTransfer(HOOK, sellAmount);
            emit ReactiveSell(msg.sender, buyAmount, sellAmount, reactiveSellRate);
        }

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

    /// @notice Withdraw accumulated ETH fees to team recipient
    function claimFees() external onlyTeam {
        if (!claimed) revert NotYetClaimed();
        uint256 fees = accumulatedFees;
        if (fees == 0) revert NoFeesToClaim();

        accumulatedFees = 0;

        (bool success,) = teamRecipient_.call{value: fees}("");
        require(success, "ETH transfer failed");

        emit TeamFeeClaimed(teamRecipient_, fees);
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

    /// @notice Expire an unclaimed vault after the claim period has passed
    /// @dev Preserves the original teamRecipient, allowing them to claim fees and manage the vault
    function expireClaim() external {
        if (claimed) return;
        if (block.timestamp < deployedAt + CLAIM_EXPIRY) revert ClaimNotExpired();
        claimed = true;
        emit ClaimExpired(address(this), teamRecipient_);
    }

    /// @notice Receive ETH fees from hook
    receive() external payable {
        if (msg.sender != HOOK) revert OnlyHook();
        accumulatedFees += msg.value;
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
