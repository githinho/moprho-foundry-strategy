// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.12;

interface ILens {
    function getUserUnclaimedRewards(address[] calldata _poolTokenAddresses, address _user)
        external
        view
        returns (uint256 unclaimedRewards);
}
