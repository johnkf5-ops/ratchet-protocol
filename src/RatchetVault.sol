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

    /// @notice The factory that deployed this vault (can initialize token)
    address public immutable FACTORY;
    /// @notice The hook contract authorized to trigger reactive sells
    address public immutable HOOK;
    /// @notice The team address that receives ETH fees and controls the ratchet
    address public immutable TEAM_RECIPIENT;

    /// @notice The token this vault holds (set once by factory after token deployment)
    address public TOKEN;
    /// @notice Current reactive sell rate in basis points (0-1000)
    uint256 public reactiveSellRate;
    /// @notice ETH fees accumulated from hook, claimable by team
    uint256 public accumulatedFees;

    error OnlyHook();
    error OnlyTeam();
    error OnlyFactory();
    error RateCanOnlyDecrease();
    error RateTooHigh();
    error NoFeesToClaim();
    error AlreadyInitialized();
    error ZeroAddress();

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
        if (msg.sender != TEAM_RECIPIENT) revert OnlyTeam();
    }

    /// @notice Deploy a new vault for a token launch
    /// @param hook_ The hook contract authorized to call onBuy
    /// @param teamRecipient_ Address that can decrease rate and claim fees
    /// @param initialReactiveSellRate_ Starting sell rate in bps (max 1000 = 10%)
    constructor(
        address hook_,
        address teamRecipient_,
        uint256 initialReactiveSellRate_
    ) {
        if (hook_ == address(0)) revert ZeroAddress();
        if (teamRecipient_ == address(0)) revert ZeroAddress();
        if (initialReactiveSellRate_ > MAX_REACTIVE_SELL_RATE) revert RateTooHigh();

        FACTORY = msg.sender;
        HOOK = hook_;
        TEAM_RECIPIENT = teamRecipient_;
        reactiveSellRate = initialReactiveSellRate_;
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

        if (sellAmount > 0) {
            IERC20(TOKEN).safeTransfer(HOOK, sellAmount);
            emit ReactiveSell(msg.sender, buyAmount, sellAmount, reactiveSellRate);
        }

        return sellAmount;
    }

    /// @notice Decrease the reactive sell rate. Can only go down, never up.
    /// @param newRate New rate in basis points, must be strictly less than current
    function decreaseRate(uint256 newRate) external onlyTeam {
        if (newRate >= reactiveSellRate) revert RateCanOnlyDecrease();

        uint256 oldRate = reactiveSellRate;
        reactiveSellRate = newRate;

        emit RatchetDecreased(oldRate, newRate);
    }

    /// @notice Withdraw accumulated ETH fees to team recipient
    function claimFees() external onlyTeam {
        uint256 fees = accumulatedFees;
        if (fees == 0) revert NoFeesToClaim();

        accumulatedFees = 0;

        (bool success,) = TEAM_RECIPIENT.call{value: fees}("");
        require(success, "ETH transfer failed");

        emit TeamFeeClaimed(TEAM_RECIPIENT, fees);
    }

    /// @notice Receive ETH fees from hook
    receive() external payable {
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

    /// @notice Get the team recipient address (legacy getter)
    function teamRecipient() external view returns (address) {
        return TEAM_RECIPIENT;
    }
}
