// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

pragma solidity ^0.8.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/IMorpho.sol";
import "./interfaces/ILens.sol";

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    IMorpho public constant MORPHO = IMorpho(0x8888882f8f843896699869179fB6E4f7e3B58888);
    ILens public constant LENS = ILens(0x930f1b46e1D081Ec1524efD95752bE3eCe51EF67);
    // TODO: extract this to constructor, rename it to wantPool
    address public constant C_WANT = 0x5d3a536E4D6DbD6114cc1Ead35777bAB948E3643;
    uint256 public maxGasForMatching = 100000;

    // solhint-disable-next-line no-empty-blocks
    constructor(address _vault) BaseStrategy(_vault) {
        // You can set these parameters on deployment to whatever you want
        // maxReportDelay = 6300;
        // profitFactor = 100;
        // debtThreshold = 0;
        want.safeApprove(address(MORPHO), type(uint256).max);
    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external view override returns (string memory) {
        // TODO: rename to general X
        return "StrategyMorphoDAI";
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return want.balanceOf(address(this)) + balanceOfCWant();
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        // TODO: maybe call harvestRewards()

        uint256 totalDebt = vault.strategies(address(this)).totalDebt;
        uint256 totalAssetsAfterProfit = estimatedTotalAssets();
        _profit = totalAssetsAfterProfit > totalDebt
            ? totalAssetsAfterProfit - totalDebt
            : 0;

        if (_debtOutstanding > 0) {
            uint256 amountFreed;
            // NOTE: Should try to free up at least `_debtOutstanding` of underlying position
            (amountFreed, _loss) = liquidatePosition(_debtOutstanding + _profit);
            _debtPayment = amountFreed;
            // _debtPayment = Math.min(_debtOutstanding, amountFreed);
        }
        // Net profit and loss calculation
        if (_loss > _profit) {
            _loss -= _profit;
            _profit = 0;
        } else {
            _profit -= _loss;
            _loss = 0;
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        // TODO: Do something to invest excess `want` tokens (from the Vault) into your positions
        // NOTE: Try to adjust positions so that `_debtOutstanding` can be freed up on *next* harvest (not immediately)
        // uint256 totalAssets = want.balanceOf(address(this));
        // if (totalAssets > _debtOutstanding) {
        //     MORPHO.supply(C_WANT, address(this), totalAssets - _debtOutstanding, maxGasForMatching);
        // }
        uint256 balance = want.balanceOf(address(this));
        if (balance > 0) {
            MORPHO.supply(C_WANT, address(this), want.balanceOf(address(this)), maxGasForMatching);
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 totalAssets = want.balanceOf(address(this));
        if (_amountNeeded > totalAssets) {
            uint256 balance = balanceOfCWant();
            if (balance > 0) {
                uint256 amountToWithdraw = _amountNeeded - totalAssets;
                // TODO: min(amountToWithdraw, balanceOfWant) -> witdhraw
                if (balance > amountToWithdraw) {
                    MORPHO.withdraw(C_WANT, amountToWithdraw);
                } else {
                    MORPHO.withdraw(C_WANT, balance);
                }
            }
            // TODO: maybe call harvestRewards()
            // _debtPayment = Math.min(want.balanceOf(address(this)), amountFreed);
            _liquidatedAmount = want.balanceOf(address(this));
            unchecked {
                _loss = _amountNeeded - totalAssets;
            }
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {
        uint256 balanceToWithdraw = balanceOfCWant();
        if (balanceToWithdraw > 0) {
            MORPHO.withdraw(C_WANT, balanceToWithdraw);
        }
        // TODO: maybe call harvestRewards()
        return want.balanceOf(address(this));
    }

    // NOTE: Can override `tendTrigger` and `harvestTrigger` if necessary
    // solhint-disable-next-line no-empty-blocks
    function prepareMigration(address _newStrategy) internal override {
        // TODO: Transfer any non-`want` tokens to the new strategy
        // NOTE: `migrate` will automatically forward all `want` in this strategy to the new one
        // TODO: maybe call harvestRewards()
        liquidateAllPositions();
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    // solhint-disable-next-line no-empty-blocks
    {

    }

    /**
     * @notice
     *  Provide an accurate conversion from `_amtInWei` (denominated in wei)
     *  to `want` (using the native decimal characteristics of `want`).
     * @dev
     *  Care must be taken when working with decimals to assure that the conversion
     *  is compatible. As an example:
     *
     *      given 1e17 wei (0.1 ETH) as input, and want is USDC (6 decimals),
     *      with USDC/ETH = 1800, this should give back 1800000000 (180 USDC)
     *
     * @param _amtInWei The amount (in wei/1e-18 ETH) to convert to `want`
     * @return The amount in `want` of `_amtInEth` converted to `want`
     **/
    function ethToWant(uint256 _amtInWei)
        public
        view
        virtual
        override
        returns (uint256)
    {
        // TODO create an accurate price oracle
        return _amtInWei;
    }

    /**
     * @notice
     *  Set the maximum amount of gas to consume to get matched in peer-to-peer.
     * @param _maxGasForMatching new gas value in 
     */
    function setMaxGasForMatching(uint256 _maxGasForMatching) external onlyStrategist() {
        maxGasForMatching = _maxGasForMatching;
    }

    function balanceOfCWant() public view returns (uint256 _balance) {
        (, , _balance) = LENS.getCurrentSupplyBalanceInOf(C_WANT, address(this));
    }

    function harvestRewards() private {
        return;
        // address[] memory pools = new address[](1);
        // pools[0] = C_WANT;
        // TODO: maybe set higher minimal reward to claim
        // if (LENS.getUserUnclaimedRewards(pools, address(this)) > 0) {
        //     // claim the underlying pool's rewards, currently COMP
        //     MORPHO.claimRewards(pools, false);
        //     // TODO: swap the COMP token for want
        // }
    }
}
