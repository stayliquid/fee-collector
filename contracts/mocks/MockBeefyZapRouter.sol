// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./MockERC20.sol";

contract MockBeefyZapRouter {
    event OrderExecuted(address indexed user, address indexed recipient);

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
    ) external payable {
        // Simulate execution and emit an event
        emit OrderExecuted(_order.user, _order.recipient);
    }
}
