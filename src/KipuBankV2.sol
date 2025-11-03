// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title KipuBankV2
 * @notice Versión mejorada de KipuBank con multi-token, control de acceso, Chainlink oracles
 * @dev Uso de OpenZeppelin, SafeERC20 y Chainlink price feeds. Contabilidad en USDC (6 dec).
 */

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );

    function decimals() external view returns (uint8);
}

contract KipuBankV2 is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    address public constant NATIVE = address(0);
    uint8 public constant USDC_DECIMALS = 6;

    error InsufficientBalance(address user, address token, uint256 requested, uint256 available);
    error ZeroAmount();
    error PriceFeedNotSet(address token);
    error InvalidAmount();

    event Deposit(address indexed user, address indexed token, uint256 amount, uint256 valueUSDC);
    event Withdrawal(address indexed user, address indexed token, uint256 amount, uint256 valueUSDC);
    event PriceFeedSet(address indexed token, address indexed feed);
    event GlobalLimitSet(uint256 newLimitUSDC);

    mapping(address => mapping(address => uint256)) private balances;
    mapping(address => address) public priceFeeds;
    address[] public trackedTokens;
    mapping(address => bool) private tracked;
    uint256 public globalLimitUSDC;
    address public immutable deployer;

    constructor(uint256 _initialGlobalLimitUSDC) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        deployer = msg.sender;
        globalLimitUSDC = _initialGlobalLimitUSDC;
    }

    function deposit(address token, uint256 amount) external payable {
        if (amount == 0) revert ZeroAmount();
        uint256 valueUSDC = _convertToUSDC(token, amount);
        uint256 totalAfter = totalBankValueUSDC() + valueUSDC;
        if (globalLimitUSDC > 0 && totalAfter > globalLimitUSDC) revert InvalidAmount();

        if (token == NATIVE) {
            if (msg.value != amount) revert InvalidAmount();
            balances[msg.sender][NATIVE] += amount;
        } else {
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
            balances[msg.sender][token] += amount;
        }

        _ensureTracked(token);
        emit Deposit(msg.sender, token, amount, valueUSDC);
    }

    function depositNative() external payable {
        uint256 amount = msg.value;
        if (amount == 0) revert ZeroAmount();
        uint256 valueUSDC = _convertToUSDC(NATIVE, amount);
        uint256 totalAfter = totalBankValueUSDC() + valueUSDC;
        if (globalLimitUSDC > 0 && totalAfter > globalLimitUSDC) revert InvalidAmount();
        balances[msg.sender][NATIVE] += amount;
        _ensureTracked(NATIVE);
        emit Deposit(msg.sender, NATIVE, amount, valueUSDC);
    }

    function withdraw(address token, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 bal = balances[msg.sender][token];
        if (bal < amount) revert InsufficientBalance(msg.sender, token, amount, bal);
        balances[msg.sender][token] = bal - amount;

        if (token == NATIVE) {
            (bool ok, ) = msg.sender.call{value: amount}("");
            require(ok, "ETH_TRANSFER_FAILED");
        } else {
            IERC20(token).safeTransfer(msg.sender, amount);
        }
        uint256 valueUSDC = _safeTryConvertToUSDC(token, amount);
        emit Withdrawal(msg.sender, token, amount, valueUSDC);
    }

    function setPriceFeed(address token, address feed) external onlyRole(ADMIN_ROLE) {
        priceFeeds[token] = feed;
        emit PriceFeedSet(token, feed);
        _ensureTracked(token);
    }

    function setGlobalLimitUSDC(uint256 newLimit) external onlyRole(ADMIN_ROLE) {
        globalLimitUSDC = newLimit;
        emit GlobalLimitSet(newLimit);
    }

    function getUserBalance(address user, address token) external view returns (uint256) {
        return balances[user][token];
    }

    function _ensureTracked(address token) internal {
        if (!tracked[token]) {
            tracked[token] = true;
            trackedTokens.push(token);
        }
    }

    function _convertToUSDC(address token, uint256 amount) internal view returns (uint256) {
        address feed = priceFeeds[token];
        if (feed == address(0)) revert PriceFeedNotSet(token);
        AggregatorV3Interface pf = AggregatorV3Interface(feed);
        (, int256 answer, , , ) = pf.latestRoundData();
        require(answer > 0, "INVALID_PRICE");
        uint8 feedDecimals = pf.decimals();
        uint256 usdValue = (amount * uint256(answer)) / (10 ** uint256(feedDecimals));
        uint256 scaled = usdValue * (10 ** uint256(USDC_DECIMALS));
        return scaled;
    }

    function _safeTryConvertToUSDC(address token, uint256 amount) internal view returns (uint256) {
        address feed = priceFeeds[token];
        if (feed == address(0)) return 0;
        try AggregatorV3Interface(feed).latestRoundData() returns (uint80, int256 answer, uint256, uint256, uint80) {
            if (answer <= 0) return 0;
            uint8 feedDecimals = AggregatorV3Interface(feed).decimals();
            uint256 usdValue = (amount * uint256(answer)) / (10 ** uint256(feedDecimals));
            return usdValue * (10 ** uint256(USDC_DECIMALS));
        } catch {
            return 0;
        }
    }

    function totalBankValueUSDC() public view returns (uint256 total) {
        uint256 len = trackedTokens.length;
        for (uint256 i = 0; i < len; ++i) {
            address token = trackedTokens[i];
            uint256 aggregate = _aggregateTokenBalance(token);
            if (aggregate == 0) continue;
            address feed = priceFeeds[token];
            if (feed == address(0)) continue;
            (, int256 answer, , , ) = AggregatorV3Interface(feed).latestRoundData();
            if (answer <= 0) continue;
            uint8 feedDecimals = AggregatorV3Interface(feed).decimals();
            uint256 usdValue = (aggregate * uint256(answer)) / (10 ** uint256(feedDecimals));
            total += usdValue * (10 ** uint256(USDC_DECIMALS));
        }
    }

    function _aggregateTokenBalance(address token) internal view returns (uint256 sum) {
        if (token == NATIVE) {
            return address(this).balance;
        } else {
            return IERC20(token).balanceOf(address(this));
        }
    }

    receive() external payable {}
}
