// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.12;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {StrategyFixture} from "./utils/StrategyFixture.sol";

contract StrategyRevokeTest is StrategyFixture {
    using SafeERC20 for IERC20;

    function setUp() public override {
        super.setUp();
    }

    function testRevokeStrategyFromVault(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmt && _amount < maxFuzzAmt);
        deal(address(want), user, _amount);

        // Deposit to the vault and harvest
        vm.startPrank(user);
        want.safeApprove(address(vault), _amount);
        vault.deposit(_amount);
        vm.stopPrank();
        skip(1);
        vm.prank(strategist);
        strategy.harvest();
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, DELTA);

        // In order to pass these tests, you will need to implement prepareReturn.
        vm.prank(gov);
        vault.revokeStrategy(address(strategy));
        skip(1);
        vm.prank(strategist);
        strategy.harvest();
        assertRelApproxEq(want.balanceOf(address(vault)), _amount, DELTA);
    }

    function testRevokeStrategyFromStrategy(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmt && _amount < maxFuzzAmt);
        deal(address(want), user, _amount);

        vm.startPrank(user);
        want.safeApprove(address(vault), _amount);
        vault.deposit(_amount);
        vm.stopPrank();
        skip(1);
        vm.prank(strategist);
        strategy.harvest();
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, DELTA);

        vm.prank(gov);
        strategy.setEmergencyExit();
        skip(1);
        vm.prank(strategist);
        strategy.harvest();
        assertRelApproxEq(want.balanceOf(address(vault)), _amount, DELTA);
    }
}
