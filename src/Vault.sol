//SPDX-License-Identifier:MIT

pragma solidity ^0.8.13;

import {AggregatorV3Interface} from "lib/chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {IERC20} from "lib/yield-utils-v2/src/token/IERC20.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {TransferHelper} from "lib/yield-utils-v2/src/token/TransferHelper.sol";

interface IERC20Decimals is IERC20 {
    function decimals() external view returns (uint256);
}

contract Vault is Ownable {
    // Attach library for safetransfer methods
    using TransferHelper for IERC20Decimals;

    // Vault records collateral deposits of each user
    mapping(address => uint256) public deposits;

    // Vault records debt holdings of each user
    mapping(address => uint256) public debts;

    // ERC20 interface specifying token contracts functions
    IERC20Decimals public immutable collateral;
    IERC20Decimals public immutable debt;

    // Asset Pricefeed interface from Chainlink
    AggregatorV3Interface public immutable priceFeed;

    // Emitted on deposit()
    event Deposit(address indexed user, uint256 collateralAmount);

    // Emitted on borrow()
    event Borrow(address indexed user, uint256 debtAmount);

    // Emitted on repay()
    event Repay(address indexed user, uint256 debtAmount);

    // Emitted on withdraw()
    event Withdraw(address indexed user, uint256 collateralAmount);

    // Emitted on liquidation()
    event Liquidation(
        address indexed user,
        uint256 debtToCover,
        uint256 liquidatedCollateralAmount
    );

    // Returns decimal places of price dictated by Chainlink Oracle
    uint256 public immutable scalarFactor;

    // Returns decimal places of tokens as dictated by their respective contracts
    uint256 public collateralDecimals;
    uint256 public debtDecimals;

    constructor(address dai_, address weth_, address priceFeedAddress) {
        collateral = IERC20Decimals(weth_);
        debt = IERC20Decimals(dai_);

        priceFeed = AggregatorV3Interface(priceFeedAddress);
        scalarFactor = 10 ** priceFeed.decimals();

        collateralDecimals = collateral.decimals();
        debtDecimals = debt.decimals();
    }

    /*////////////////////////////////////////////////////////////////////////*/
    /*                             TRANSACTIONS                               */
    /*////////////////////////////////////////////////////////////////////////*/

    // Users deposit collateral asset into Vault
    function deposit(uint256 collateralAmount) external {
        deposits[msg.sender] += collateralAmount;

        collateral.safeTransferFrom(
            msg.sender,
            address(this),
            collateralAmount
        );
        emit Deposit(msg.sender, collateralAmount);
    }

    // Users borrow debt asset calculated based on collateralisation level and their deposits
    function borrow(uint256 debtAmount) external {
        uint256 newDebt = debts[msg.sender] + debtAmount;
        require(
            _isCollateralised(newDebt, deposits[msg.sender]),
            "Would become uncollateralised"
        );

        debts[msg.sender] = newDebt;
        debt.safeTransfer(msg.sender, debtAmount);
        emit Borrow(msg.sender, debtAmount);
    }

    // Users repay their debt, in debt asset terms
    function repay(uint256 debtAmount) external {
        debts[msg.sender] -= debtAmount;

        debt.safeTransferFrom(msg.sender, address(this), debtAmount);
        emit Repay(msg.sender, debtAmount);
    }

    // Users withdraw their deposited collateral
    function withdraw(uint256 collateralAmount) external {
        uint256 newDeposit = deposits[msg.sender] - collateralAmount;
        require(
            _isCollateralised(debts[msg.sender], newDeposit),
            "Would become uncollateralised"
        );

        deposits[msg.sender] = newDeposit;
        collateral.safeTransfer(msg.sender, collateralAmount);
        emit Withdraw(msg.sender, collateralAmount);
    }

    /*////////////////////////////////////////////////////////////////////////*/
    /*                           COLLATERALIZATION                            */
    /*////////////////////////////////////////////////////////////////////////*/

    // Checks conditionals in return statement sequentially; first if debt is 0, otherwise, check that debt amount can be supported with given collateral
    function _isCollateralised(
        uint256 debtAmount,
        uint256 collateralAmount
    ) internal view returns (bool collateralised) {
        return
            debtAmount == 0 ||
            debtAmount <= _collateralToDebt(collateralAmount);
    }

    // For a given collateral amount, calculate the debt it can support at current market prices
    function _collateralToDebt(
        uint256 collateralAmount
    ) internal view returns (uint256 debtAmount) {
        (, int price, , , ) = priceFeed.latestRoundData();
        debtAmount = (collateralAmount * scalarFactor) / uint256(price);
        debtAmount = _scaleDecimals(
            debtAmount,
            debtDecimals,
            collateralDecimals
        );
    }

    // Calculates minimum collateral required of a user to support existing debts, at current market prices
    function minimumCollateral(
        address user
    ) public view returns (uint256 collateralAmount) {
        collateralAmount = _debtToCollateral(debts[user]);
    }

    // Calculates minimum collateral required to support given amount of debt, at current market prices
    function _debtToCollateral(
        uint256 debtAmount
    ) internal view returns (uint256 collateralAmount) {
        (, int price, , , ) = priceFeed.latestRoundData();
        collateralAmount = (debtAmount * uint256(price)) / scalarFactor;
        collateralAmount = _scaleDecimals(
            collateralAmount,
            collateralDecimals,
            debtDecimals
        );
    }

    // For rebasement of trailing zeros which are representative of decimal precision
    function _scaleDecimals(
        uint256 integer,
        uint256 from,
        uint256 to
    ) internal pure returns (uint256) {
        // downscaling | 10^(to - from)  => 10^(-ve) | cannot have negative powers, bring down as division => interger / 10^(from - to)
        if (from > to) {
            return integer / 10 ** (from - to);
        }
        // upscaling | (to >= from) => +ve
        else {
            return integer * 10 ** (to - from);
        }
    }

    /*///////////////////////////////////////////////////////////////////////*/
    /*                               LIQUIDATIONS                            */
    /*///////////////////////////////////////////////////////////////////////*/

    // Can only be called by Vault owner; triggers liquidation check on supplied user address
    function liquidation(address user) external onlyOwner {
        uint256 userDebt = debts[user]; // saves an extra SLOAD
        uint256 userDeposit = deposits[user]; // saves an extra SLOAD

        require(
            !_isCollateralised(userDebt, userDeposit),
            "Not undercollateralised"
        );

        delete deposits[user];
        delete debts[user];
        emit Liquidation(user, userDebt, userDeposit);
    }
}
