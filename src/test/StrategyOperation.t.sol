// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.12;
import "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {StrategyFixture} from "./utils/StrategyFixture.sol";
import {StrategyParams} from "../interfaces/Vault.sol";
import {ITradeFactory} from "../interfaces/ySwap/ITradeFactory.sol";

contract StrategyOperationsTest is StrategyFixture {
    using SafeERC20 for IERC20;

    // setup is run on before each test
    function setUp() public override {
        // setup vault
        super.setUp();
    }

    function testSetupVaultOK() public {
        console.log("address of vault", address(vault));
        assertTrue(address(0) != address(vault));
        assertEq(vault.token(), address(want));
        assertEq(vault.depositLimit(), type(uint256).max);
    }

    function testSetupStrategyOK() public {
        console.log("address of strategy", address(strategy));
        assertTrue(address(0) != address(strategy));
        assertEq(address(strategy.vault()), address(vault));
        // assert allowance of want token to morpho protocol
        assertEq(
            want.allowance(address(strategy), address(strategy.MORPHO())),
            type(uint256).max
        );
        // assert that the defualt router is sushi
        assertEq(
            address(strategy.currentV2Router()),
            address(0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F)
        );
        // assert allowance for comp to Sushi v2
        assertEq(
            IERC20(strategy.COMP()).allowance(
                address(strategy),
                address(0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F)
            ),
            type(uint96).max
        );
        // assert allowance for comp to Uni v2
        assertEq(
            IERC20(strategy.COMP()).allowance(
                address(strategy),
                address(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D)
            ),
            type(uint96).max
        );
    }

    /// Test Operations
    function testStrategyOperation(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmt && _amount < maxFuzzAmt);
        deal(address(want), user, _amount);

        uint256 balanceBefore = want.balanceOf(address(user));
        vm.startPrank(user);
        want.safeApprove(address(vault), _amount);
        vault.deposit(_amount);
        vm.stopPrank();
        assertRelApproxEq(want.balanceOf(address(vault)), _amount, DELTA);

        skip(3 minutes);
        vm.prank(strategist);
        strategy.harvest();
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, DELTA);

        // tend
        vm.prank(strategist);
        strategy.tend();

        vm.prank(user);
        vault.withdraw();

        assertRelApproxEq(want.balanceOf(user), balanceBefore, DELTA);
    }

    function testEmergencyExit(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmt && _amount < maxFuzzAmt);
        deal(address(want), user, _amount);

        // Deposit to the vault
        vm.startPrank(user);
        want.safeApprove(address(vault), _amount);
        vault.deposit(_amount);
        vm.stopPrank();
        skip(1);
        vm.prank(strategist);
        strategy.harvest();
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, DELTA);

        // set emergency and exit
        vm.prank(gov);
        strategy.setEmergencyExit();
        skip(1);
        vm.prank(strategist);
        strategy.harvest();
        assertLt(strategy.estimatedTotalAssets(), _amount);
    }

    function testProfitableHarvest(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmt && _amount < maxFuzzAmt);
        deal(address(want), user, _amount);

        // Deposit to the vault
        vm.startPrank(user);
        want.safeApprove(address(vault), _amount);
        vault.deposit(_amount);
        vm.stopPrank();
        assertRelApproxEq(want.balanceOf(address(vault)), _amount, DELTA);

        uint256 beforePps = vault.pricePerShare();

        // Harvest 1: Send funds through the strategy
        skip(1);
        vm.prank(strategist);
        strategy.harvest();
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, DELTA);

        // Add some code before harvest #2 to simulate earning yield
        // Strategy earned some reward tokens, param amount is adjusted to comp token decimals
        uint256 compAmount = _amount * 10**(18 - vault.decimals());
        vm.assume(compAmount > strategy.minCompToClaimOrSell());
        deal(address(strategy.COMP()), address(strategy), compAmount);

        // use tradefactory to execute swap reward tokens to want tokens.
        ITradeFactory.AsyncTradeExecutionDetails memory ated = ITradeFactory.AsyncTradeExecutionDetails(
            address(strategy),
            address(strategy.COMP()),
            address(want),
            compAmount,
            1
        );
        address[] memory path = new address[](3);
        path[0] = strategy.COMP();
        path[1] = address(weth);
        path[2] = address(want);
        vm.prank(yMechSafe);
        tradeFactory.execute(ated, swapper, abi.encode(path));

        // Harvest 2: Realize profit
        skip(1);
        vm.prank(strategist);
        strategy.harvest();
        skip(6 hours);

        // Validate profit
        uint256 profit = want.balanceOf(address(vault));
        assertGt(vault.pricePerShare(), beforePps);
    }

    function testProfitableHarvestWithoutTradeFactory(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmt && _amount < maxFuzzAmt);
        deal(address(want), user, _amount);

        // disable trade factory
        vm.prank(strategist);
        strategy.removeTradeFactoryPermissions();

        // Deposit to the vault
        vm.startPrank(user);
        want.safeApprove(address(vault), _amount);
        vault.deposit(_amount);
        vm.stopPrank();
        assertRelApproxEq(want.balanceOf(address(vault)), _amount, DELTA);

        uint256 beforePps = vault.pricePerShare();

        // Harvest 1: Send funds through the strategy
        skip(1);
        vm.prank(strategist);
        strategy.harvest();
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, DELTA);

        // Add some code before harvest #2 to simulate earning yield
        // Strategy earned some reward tokens, param amount is adjusted to comp token decimals
        uint256 compAmount = _amount * 10**(18 - vault.decimals());
        vm.assume(compAmount > strategy.minCompToClaimOrSell());
        deal(address(strategy.COMP()), address(strategy), compAmount);

        // Harvest 2: Realize profit
        skip(1);
        vm.prank(strategist);
        strategy.harvest();
        skip(6 hours);

        // Validate profit
        uint256 profit = want.balanceOf(address(vault));
        assertGt(want.balanceOf(address(strategy)) + profit, _amount);
        assertGt(vault.pricePerShare(), beforePps);
    }

    function testChangeDebt(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmt && _amount < maxFuzzAmt);
        deal(address(want), user, _amount);

        // Deposit to the vault and harvest
        vm.startPrank(user);
        want.safeApprove(address(vault), _amount);
        vault.deposit(_amount);
        vm.stopPrank();
        vm.prank(gov);
        vault.updateStrategyDebtRatio(address(strategy), 5_000);
        skip(1);
        vm.prank(strategist);
        strategy.harvest();
        uint256 half = uint256(_amount / 2);
        assertRelApproxEq(strategy.estimatedTotalAssets(), half, DELTA);

        vm.prank(gov);
        vault.updateStrategyDebtRatio(address(strategy), 10_000);
        skip(1);
        vm.prank(strategist);
        strategy.harvest();
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, DELTA);

        // In order to pass these tests, you will need to implement prepareReturn.
        vm.prank(gov);
        vault.updateStrategyDebtRatio(address(strategy), 5_000);
        skip(1);
        vm.prank(strategist);
        strategy.harvest();
        assertRelApproxEq(strategy.estimatedTotalAssets(), half, DELTA);
    }

    function testProfitableHarvestOnDebtChange(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmt && _amount < maxFuzzAmt);
        deal(address(want), user, _amount);

        // Deposit to the vault
        vm.startPrank(user);
        want.safeApprove(address(vault), _amount);
        vault.deposit(_amount);
        vm.stopPrank();
        assertRelApproxEq(want.balanceOf(address(vault)), _amount, DELTA);

        uint256 beforePps = vault.pricePerShare();

        // Harvest 1: Send funds through the strategy
        skip(1);
        vm.prank(strategist);
        strategy.harvest();
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, DELTA);

        // TODO: Add some code before harvest #2 to simulate earning yield

        vm.prank(gov);
        vault.updateStrategyDebtRatio(address(strategy), 5_000);

        // Harvest 2: Realize profit
        skip(1);
        vm.prank(strategist);
        strategy.harvest();
        //Make sure we have updated the debt ratio of the strategy
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount / 2, DELTA);
        skip(6 hours);

        //Make sure we have updated the debt and made a profit
        uint256 vaultBalance = want.balanceOf(address(vault));
        StrategyParams memory params = vault.strategies(address(strategy));
        //Make sure we got back profit + half the deposit
        assertRelApproxEq(_amount / 2 + params.totalGain, vaultBalance, DELTA);
        assertGe(vault.pricePerShare(), beforePps);
    }

    function testSweep(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmt && _amount < maxFuzzAmt);
        deal(address(want), user, _amount);

        // Strategy want token doesn't work
        vm.prank(user);
        want.transfer(address(strategy), _amount);
        assertEq(address(want), address(strategy.want()));
        assertGt(want.balanceOf(address(strategy)), 0);

        vm.prank(gov);
        vm.expectRevert("!want");
        strategy.sweep(address(want));

        // Vault share token doesn't work
        vm.prank(gov);
        vm.expectRevert("!shares");
        strategy.sweep(address(vault));

        // TODO: If you add protected tokens to the strategy.
        // Protected token doesn't work
        // vm.prank(gov);
        // vm.expectRevert("!protected");
        // strategy.sweep(strategy.protectedToken());

        uint256 beforeBalance = weth.balanceOf(gov);
        uint256 wethAmount = 1 ether;
        deal(address(weth), user, wethAmount);
        vm.prank(user);
        weth.transfer(address(strategy), wethAmount);
        assertNeq(address(weth), address(strategy.want()));
        assertEq(weth.balanceOf(user), 0);
        vm.prank(gov);
        strategy.sweep(address(weth));
        assertRelApproxEq(
            weth.balanceOf(gov),
            wethAmount + beforeBalance,
            DELTA
        );
    }

    function testTriggers(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmt && _amount < maxFuzzAmt);
        deal(address(want), user, _amount);

        // Deposit to the vault and harvest
        vm.startPrank(user);
        want.safeApprove(address(vault), _amount);
        vault.deposit(_amount);
        vm.stopPrank();
        vm.prank(gov);
        vault.updateStrategyDebtRatio(address(strategy), 5_000);
        skip(1);
        vm.prank(strategist);
        strategy.harvest();

        strategy.harvestTrigger(0);
        strategy.tendTrigger(0);
    }
}
