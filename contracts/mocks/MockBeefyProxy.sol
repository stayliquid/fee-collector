// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../BeefyProxy.sol";

/// @notice Test-only mock contract for BeefyProxy
contract MockBeefyProxy is BeefyProxy {
    /// @notice Allows setting `accumulatedFees` manually (test only)
    function setAccumulatedFees(
        address token,
        uint256 amount
    ) external onlyOwner {
        accumulatedFees[token] = amount;
    }
}
