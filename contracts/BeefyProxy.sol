// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IBeefyZapRouter {
    struct Input {
        address token;
        uint256 amount;
    }

    struct Output {
        address token;
        uint256 minOutputAmount;
    }

    struct Relay {
        address target;
        uint256 value;
        bytes data;
    }

    struct Order {
        Input[] inputs;
        Output[] outputs;
        Relay relay;
        address user;
        address recipient;
    }

    struct Step {
        address target;
        uint256 value;
        bytes data;
    }

    function executeOrder(
        Order calldata _order,
        Step[] calldata _route
    ) external payable;
}

contract BeefyProxy is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    /// @notice Address of the BeefyZapRouter contract
    IBeefyZapRouter public beefyRouter;

    /// @notice Fixed fee percentage (default: 20%)
    uint256 public feePercentage;

    /// @notice Tracks user deposits per token
    mapping(address => mapping(address => uint256)) public userDeposits;

    /// @notice Tracks contract's accumulated fees per token
    mapping(address => uint256) public accumulatedFees;

    event DepositTracked(
        address indexed user,
        address indexed token,
        uint256 amount
    );
    event WithdrawalProcessed(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 profit,
        uint256 fee
    );
    event FeeWithdrawn(address indexed token, uint256 amount);
    event EmergencyWithdrawal(address indexed token, uint256 amount);
    event BeefyRouterUpdated(address newRouter);
    event EmergencyModeActivated();
    event EmergencyModeDeactivated();

    /// @notice Modifier to restrict access to only whitelisted functions
    modifier onlyWhitelistedFunction(bytes4 selector) {
        require(
            selector == IBeefyZapRouter.executeOrder.selector,
            "Function not allowed"
        );
        _;
    }

    /// @notice Initialize contract (called only once)
    function initialize(
        address _beefyRouter,
        uint256 _feePercentage
    ) public initializer {
        __Ownable_init(msg.sender); // Multisig as owner
        __Pausable_init();
        __ReentrancyGuard_init();

        beefyRouter = IBeefyZapRouter(_beefyRouter);
        feePercentage = _feePercentage;
    }

    /// @notice Proxy function to BeefyZapRouter's `executeOrder`
    function executeOrder(
        IBeefyZapRouter.Order calldata _order,
        IBeefyZapRouter.Step[] calldata _route
    ) external payable whenNotPaused nonReentrant {
        require(_order.inputs.length > 0, "No input tokens specified");
        require(_order.outputs.length > 0, "No output tokens specified");

        // Track deposits per user per token
        for (uint256 i = 0; i < _order.inputs.length; i++) {
            address token = _order.inputs[i].token;
            uint256 amount = _order.inputs[i].amount;

            require(amount > 0, "Invalid deposit amount");

            // Transfer tokens from user to this contract
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

            // Approve BeefyZapRouter to spend tokens
            IERC20(token).approve(address(beefyRouter), amount);

            // Track user deposit
            userDeposits[msg.sender][token] += amount;

            emit DepositTracked(msg.sender, token, amount);
        }

        // Execute order via BeefyZapRouter
        beefyRouter.executeOrder(_order, _route);
    }

    /// @notice Handles user withdrawals and calculates profit & fee
    function processWithdrawal(
        address token,
        uint256 amount
    ) external whenNotPaused nonReentrant {
        require(amount > 0, "Invalid withdrawal amount");

        uint256 initialDeposit = userDeposits[msg.sender][token];
        require(initialDeposit > 0, "No deposits found");

        // Profit = Withdrawn Amount - Initial Deposit
        uint256 profit = (amount > initialDeposit)
            ? (amount - initialDeposit)
            : 0;
        uint256 fee = (profit * feePercentage) / 100;

        // Deduct fee and transfer remaining funds to user
        uint256 amountAfterFee = amount - fee;
        IERC20(token).safeTransfer(msg.sender, amountAfterFee);

        // Store fee in contract
        accumulatedFees[token] += fee;
        userDeposits[msg.sender][token] = (amount > initialDeposit)
            ? 0
            : initialDeposit - amount;

        emit WithdrawalProcessed(msg.sender, token, amount, profit, fee);
    }

    /// @notice Allows contract owner to withdraw accumulated fees
    function withdrawFees(address token) external onlyOwner {
        uint256 feeBalance = accumulatedFees[token];
        require(feeBalance > 0, "No fees available");

        accumulatedFees[token] = 0;
        IERC20(token).safeTransfer(owner(), feeBalance);

        emit FeeWithdrawn(token, feeBalance);
    }

    /// @notice Emergency function to withdraw all funds (only after pausing)
    function emergencyWithdraw(address token) external onlyOwner whenPaused {
        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance > 0, "No funds available");

        IERC20(token).safeTransfer(owner(), balance);
        emit EmergencyWithdrawal(token, balance);
    }

    /// @notice Allows contract owner to update BeefyZapRouter address
    function updateBeefyRouter(address newRouter) external onlyOwner {
        require(newRouter != address(0), "Invalid address");
        beefyRouter = IBeefyZapRouter(newRouter);
        emit BeefyRouterUpdated(newRouter);
    }

    /// @notice Activate emergency mode (pauses all deposits & withdrawals)
    function activateEmergencyMode() external onlyOwner {
        _pause();
        emit EmergencyModeActivated();
    }

    /// @notice Deactivate emergency mode (resumes all operations)
    function deactivateEmergencyMode() external onlyOwner {
        _unpause();
        emit EmergencyModeDeactivated();
    }

    /// @notice Required override for upgradeability
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}
}
