// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

pragma solidity ^0.8.12;

interface ITradeFactory {
    function enable(address, address) external;

    function grantRole(bytes32 role, address account) external;

    function STRATEGY() external view returns (bytes32);

    struct AsyncTradeExecutionDetails {
        address _strategy;
        address _tokenIn;
        address _tokenOut;
        uint256 _amount;
        uint256 _minAmountOut;
    }

    function execute(
        AsyncTradeExecutionDetails calldata _tradeExecutionDetails,
        address _swapper,
        bytes calldata _data
    ) external returns (uint256 _receivedAmount);
}
