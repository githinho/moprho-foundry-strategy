// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

pragma solidity ^0.8.12;

// These are the core Yearn libraries
import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./interfaces/IMorpho.sol";
import "./interfaces/ILens.sol";
import "./interfaces/IUniswapV2Router01.sol";

import "./interfaces/ySwap/ITradeFactory.sol";

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    //ySwap TradeFactory:
    address public tradeFactory;
    // Morpho is a contract to handle interaction with the protocol
    IMorpho public constant MORPHO =
        IMorpho(0x8888882f8f843896699869179fB6E4f7e3B58888);
    // Lens is a contract to fetch data about Morpho protocol
    ILens public constant LENS =
        ILens(0x930f1b46e1D081Ec1524efD95752bE3eCe51EF67);
    // cTokenAdd = Morpho Market for want token, address of cToken
    address public immutable cTokenAdd;
    // COMP = Compound token
    address public constant COMP = 0xc00e94Cb662C3520282E6f5717214004A7f26888;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    // Router used for swapping reward token (COMP)
    IUniswapV2Router01 public currentV2Router;
    // Max gas used for matching with p2p deals
    uint256 public maxGasForMatching = 100000;
    // Minimum amount of COMP to be claimed or sold
    uint256 public minCompToClaimOrSell = 0.1 ether;

    IUniswapV2Router01 private constant UNI_V2_ROUTER =
        IUniswapV2Router01(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    IUniswapV2Router01 private constant SUSHI_V2_ROUTER =
        IUniswapV2Router01(0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F);

    constructor(address _vault, address _cTokenAdd) BaseStrategy(_vault) {
        // cTokenAdd = Morpho Market for want token, address of cToken
        cTokenAdd = _cTokenAdd;
        want.safeApprove(address(MORPHO), type(uint256).max);
        currentV2Router = SUSHI_V2_ROUTER;
        IERC20 comp = IERC20(COMP);
        // COMP max allowance is uint96
        comp.safeApprove(address(SUSHI_V2_ROUTER), type(uint96).max);
        comp.safeApprove(address(UNI_V2_ROUTER), type(uint96).max);
    }

    // ******** BaseStrategy overriden contract function ************

    function name() external view override returns (string memory) {
        return "StrategyMorphoDAI";
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return want.balanceOf(address(this)) + balanceOfcToken();
    }

    // NOTE: Return `_profit` which is value generated by all positions, priced in `want`
    // NOTE: Should try to free up at least `_debtOutstanding` of underlying position
    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        claimComp();
        sellComp();

        uint256 totalDebt = vault.strategies(address(this)).totalDebt;
        uint256 totalAssetsAfterProfit = estimatedTotalAssets();
        _profit = totalAssetsAfterProfit > totalDebt
            ? totalAssetsAfterProfit - totalDebt
            : 0;

        (_debtPayment, _loss) = liquidatePosition(_debtOutstanding);
        _debtPayment = Math.min(_debtPayment, _debtOutstanding);
        // Net profit and loss calculation
        if (_loss > _profit) {
            _loss -= _profit;
            _profit = 0;
        } else {
            _profit -= _loss;
            _loss = 0;
        }
    }

    // NOTE: Try to adjust positions so that `_debtOutstanding` can be freed up on *next* harvest (not immediately)
    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 wantBalance = want.balanceOf(address(this));
        if (wantBalance > _debtOutstanding) {
            MORPHO.supply(
                cTokenAdd,
                address(this),
                wantBalance - _debtOutstanding,
                maxGasForMatching
            );
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 wantBalance = want.balanceOf(address(this));
        if (_amountNeeded > wantBalance) {
            _liquidatedAmount = Math.min(
                _amountNeeded - wantBalance,
                balanceOfcToken()
            );
            MORPHO.withdraw(cTokenAdd, _liquidatedAmount);
            _liquidatedAmount = Math.min(
                want.balanceOf(address(this)),
                _amountNeeded
            );
            _loss = _amountNeeded > _liquidatedAmount
                ? _amountNeeded - _liquidatedAmount
                : 0;
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {
        uint256 balanceToWithdraw = balanceOfcToken();
        if (balanceToWithdraw > 0) {
            MORPHO.withdraw(cTokenAdd, balanceToWithdraw);
        }
        return want.balanceOf(address(this));
    }

    // NOTE: Can override `tendTrigger` and `harvestTrigger` if necessary
    function prepareMigration(address _newStrategy) internal override {
        liquidateAllPositions();
        claimComp();
        // sellComp();
        IERC20 comp = IERC20(COMP);
        comp.transfer(_newStrategy, comp.balanceOf(address(this)));
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

    // ******** functions for Morpho protocol ********

    /**
     * @notice
     *  Set the maximum amount of gas to consume to get matched in peer-to-peer.
     * @dev
     *  This value is needed in morpho supply liquidity calls.
     *  Supplyed liquidity goes to loop with current loans on Compound
     *  and creates a match for p2p deals. The loop starts from bigger liquidity deals.
     * @param _maxGasForMatching new maximum gas value for
     */
    function setMaxGasForMatching(uint256 _maxGasForMatching)
        external
        onlyAuthorized
    {
        maxGasForMatching = _maxGasForMatching;
    }

    /**
     * @notice
     *  Computes and returns the total amount of underlying ERC20 token a given user has supplied through Morpho
     *  on a given market, taking into account interests accrued.
     * @dev
     *  The value is in `want` precision, decimals so there is no need to convert this value if calculating with `want`.
     * @return _balance of `want` token supplied to Morpho in `want` precision
     */
    function balanceOfcToken() public view returns (uint256 _balance) {
        (, , _balance) = LENS.getCurrentSupplyBalanceInOf(
            cTokenAdd,
            address(this)
        );
    }

    function claimComp() internal {
        address[] memory pools = new address[](1);
        pools[0] = cTokenAdd;
        if (
            LENS.getUserUnclaimedRewards(pools, address(this)) >
            minCompToClaimOrSell
        ) {
            // claim the underlying pool's rewards, currently COMP token
            MORPHO.claimRewards(pools, false);
        }
    }

    // ******** functions for selling reward token COMP ********

    /**
     * @notice
     *  Set toggle v2 swap router between sushiv2 and univ2
     */
    function setToggleV2Router() external onlyAuthorized {
        currentV2Router = currentV2Router == SUSHI_V2_ROUTER
            ? UNI_V2_ROUTER
            : SUSHI_V2_ROUTER;
    }

    /**
     * @notice
     *  Set the minimum amount of compount token need to claim or sell it for `want` token.
     */
    function setMinCompToSell(uint256 _minCompToClaimOrSell)
        external
        onlyAuthorized
    {
        minCompToClaimOrSell = _minCompToClaimOrSell;
    }

    function sellComp() internal {
        if (tradeFactory == address(0)) {
            uint256 compBalance = IERC20(COMP).balanceOf(address(this));
            if (compBalance > minCompToClaimOrSell) {
                currentV2Router.swapExactTokensForTokens(
                    compBalance,
                    0,
                    getTokenOutPathV2(COMP, address(want)),
                    address(this),
                    block.timestamp
                );
            }
        }
    }

    function getTokenOutPathV2(address _tokenIn, address _tokenOut)
        internal
        pure
        returns (address[] memory _path)
    {
        bool isWeth = _tokenIn == address(WETH) || _tokenOut == address(WETH);
        _path = new address[](isWeth ? 2 : 3);
        _path[0] = _tokenIn;

        if (isWeth) {
            _path[1] = _tokenOut;
        } else {
            _path[1] = address(WETH);
            _path[2] = _tokenOut;
        }
    }

    // ---------------------- YSWAPS FUNCTIONS ----------------------
    function setTradeFactory(address _tradeFactory) external onlyGovernance {
        if (tradeFactory != address(0)) {
            _removeTradeFactoryPermissions();
        }
        IERC20(COMP).safeApprove(_tradeFactory, type(uint256).max);
        ITradeFactory tf = ITradeFactory(_tradeFactory);
        tf.enable(COMP, address(want));
        tradeFactory = _tradeFactory;
    }

    function removeTradeFactoryPermissions() external onlyEmergencyAuthorized {
        _removeTradeFactoryPermissions();
    }

    function _removeTradeFactoryPermissions() internal {
        IERC20(COMP).safeApprove(tradeFactory, 0);
        tradeFactory = address(0);
    }
}
