// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.12;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {StrategyFixture} from "./utils/StrategyFixture.sol";
import {Strategy} from "../Strategy.sol";

contract StrategyMigrationTest is StrategyFixture {
    using SafeERC20 for IERC20;

    function setUp() public override {
        super.setUp();
    }

    // TODO: Add tests that show proper migration of the strategy to a newer one
    // Use another copy of the strategy to simmulate the migration
    // Show that nothing is lost.
    function testMigration(uint256 _amount) public {
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

        // Migrate to a new strategy
        vm.prank(strategist);
        Strategy newStrategy = Strategy(
            deployStrategy(address(vault), strategy.cTokenAdd())
        );
        vm.prank(gov);
        vault.migrateStrategy(address(strategy), address(newStrategy));
        assertRelApproxEq(newStrategy.estimatedTotalAssets(), _amount, DELTA);
        assertEq(strategy.estimatedTotalAssets(), 0);
    }
}
