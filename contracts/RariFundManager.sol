/**
 * @file
 * @author David Lucid <david@rari.capital>
 *
 * @section LICENSE
 *
 * All rights reserved to David Lucid of David Lucid LLC.
 * Any disclosure, reproduction, distribution or other use of this code by any individual or entity other than David Lucid of David Lucid LLC, unless given explicit permission by David Lucid of David Lucid LLC, is prohibited.
 *
 * @section DESCRIPTION
 *
 * This file includes the Ethereum contract code for RariFundManager, the primary contract powering Rari Capital's RariFund.
 */

pragma solidity ^0.5.7;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/drafts/SignedSafeMath.sol";
import "@openzeppelin/contracts/ownership/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20Detailed.sol";

import "./lib/RariFundController.sol";
import "./RariFundToken.sol";

/**
 * @title RariFundManager
 * @dev This contract is the primary contract powering RariFund.
 * Anyone can deposit to the fund with deposit(string currencyCode, uint256 amount)
 * Anyone can withdraw their funds (with interest) from the fund with withdraw(string currencyCode, uint256 amount)
 */
contract RariFundManager is Ownable {
    using SafeMath for uint256;
    using SignedSafeMath for int256;

    /**
     * @dev Boolean that, if true, disables deposits to and withdrawals from this RariFundManager.
     */
    bool private _fundDisabled;

    /**
     * @dev Address of the RariFundToken.
     */
    address private _rariFundTokenContract;

    /**
     * @dev Address of the rebalancer.
     */
    address private _rariFundRebalancerAddress;

    /**
     * @dev Maps ERC20 token contract addresses to their currency codes.
     */
    string[] private _supportedCurrencies;

    /**
     * @dev Maps ERC20 token contract addresses to their currency codes.
     */
    mapping(string => address) private _erc20Contracts;

    /**
     * @dev Maps arrays of supported pools to currency codes.
     */
    mapping(string => uint8[]) private _poolsByCurrency;

    /**
     * @dev Struct for a pending withdrawal.
     */
    struct PendingWithdrawal {
        address payee;
        uint256 amount;
    }

    /**
     * @dev Mapping of withdrawal queues to currency codes.
     */
    mapping(string => PendingWithdrawal[]) private _withdrawalQueues;

    /**
     * @dev Constructor that sets supported ERC20 token contract addresses and supported pools for each supported token.
     */
    constructor () public {
        // Add currencies
        addCurrency("DAI", 0x6B175474E89094C44Da98b954EedeAC495271d0F);
        addPoolToCurrency("DAI", 0); // dYdX
        addPoolToCurrency("DAI", 1); // Compound
        addCurrency("USDC", 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        addPoolToCurrency("USDC", 0); // dYdX
        addPoolToCurrency("USDC", 1); // Compound
        addCurrency("USDT", 0xdAC17F958D2ee523a2206206994597C13D831ec7);
        addPoolToCurrency("USDT", 1); // Compound
    }

    /**
     * @dev Sets supported ERC20 token contract addresses for each supported token.
     * @param currencyCode The currency code of the token.
     * @param erc20Contract The ERC20 contract of the token.
     */
    function addCurrency(string memory currencyCode, address erc20Contract) internal {
        _supportedCurrencies.push(currencyCode);
        _erc20Contracts[currencyCode] = erc20Contract;
    }

    /**
     * @dev Adds a supported pool for a token.
     * @param currencyCode The currency code of the token.
     * @param pool Pool ID to be supported.
     */
    function addPoolToCurrency(string memory currencyCode, uint8 pool) internal {
        _poolsByCurrency[currencyCode].push(pool);
    }

    /**
     * @dev Emitted when RariFundManager is upgraded.
     */
    event FundManagerUpgraded(address newContract);

    /**
     * @dev Emitted when the RariFundToken of the RariFundManager is set.
     */
    event FundTokenSet(address newContract);

    /**
     * @dev Emitted when the rebalancer of the RariFundManager is set.
     */
    event FundRebalancerSet(address newAddress);

    /**
     * @dev Upgrades RariFundManager.
     * Sends data to the new contract, sets the new RariFundToken minter, and forwards tokens from the old to the new.
     * @param newContract The address of the new RariFundManager contract.
     */
    function upgradeFundManager(address newContract) external onlyOwner {
        // Pass data to the new contract
        FundManagerData memory data;

        data = FundManagerData(
            _netDeposits,
            _rawInterestAccruedAtLastFeeRateChange,
            _interestFeesGeneratedAtLastFeeRateChange,
            _interestFeesClaimed
        );

        RariFundManager(newContract).setFundManagerData(data);

        // Update RariFundToken minter
        if (_rariFundTokenContract != address(0)) {
            RariFundToken rariFundToken = RariFundToken(_rariFundTokenContract);
            rariFundToken.addMinter(newContract);
            rariFundToken.renounceMinter();
        }

        // Withdraw all tokens from all pools, process pending withdrawals, and transfer them to new FundManager
        for (uint256 i = 0; i < _supportedCurrencies.length; i++) {
            string memory currencyCode = _supportedCurrencies[i];

            for (uint256 j = 0; j < _poolsByCurrency[currencyCode].length; j++)
                if (RariFundController.getPoolBalance(_poolsByCurrency[currencyCode][j], _erc20Contracts[currencyCode]) > 0)
                    RariFundController.withdrawAllFromPool(_poolsByCurrency[currencyCode][j], _erc20Contracts[currencyCode]);

            processPendingWithdrawals(_supportedCurrencies[i]);

            ERC20 token = ERC20(_erc20Contracts[currencyCode]);
            uint256 balance = token.balanceOf(address(this));
            if (balance > 0) require(token.transfer(newContract, balance), "Failed to transfer tokens to new FundManager.");
        }

        emit FundManagerUpgraded(newContract);
    }

    /**
     * @dev Old RariFundManager contract authorized to migrate its data to the new one.
     */
    address private _authorizedFundManagerDataSource;

    /**
     * @dev Upgrades RariFundManager.
     * Authorizes the source for fund manager data (i.e., the old fund manager).
     * @param authorizedFundManagerDataSource Authorized source for data (i.e., the old fund manager).
     */
    function authorizeFundManagerDataSource(address authorizedFundManagerDataSource) external onlyOwner {
        _authorizedFundManagerDataSource = authorizedFundManagerDataSource;
    }

    /**
     * @dev Struct for data to transfer from the old RariFundManager to the new one.
     */
    struct FundManagerData {
        int256 netDeposits;
        int256 rawInterestAccruedAtLastFeeRateChange;
        int256 interestFeesGeneratedAtLastFeeRateChange;
        uint256 interestFeesClaimed;
    }

    /**
     * @dev Upgrades RariFundManager.
     * Sets data receieved from the old contract.
     * @param data The data from the old contract necessary to initialize the new contract.
     */
    function setFundManagerData(FundManagerData calldata data) external {
        require(_authorizedFundManagerDataSource != address(0) && msg.sender == _authorizedFundManagerDataSource, "Caller is not an authorized source.");
        
        _netDeposits = data.netDeposits;
        _rawInterestAccruedAtLastFeeRateChange = data.rawInterestAccruedAtLastFeeRateChange;
        _interestFeesGeneratedAtLastFeeRateChange = data.interestFeesGeneratedAtLastFeeRateChange;
        _interestFeesClaimed = data.interestFeesClaimed;
    }

    /**
     * @dev Sets or upgrades the RariFundToken of the RariFundManager.
     * @param newContract The address of the new RariFundToken contract.
     */
    function setFundToken(address newContract) external onlyOwner {
        _rariFundTokenContract = newContract;
        emit FundTokenSet(newContract);
    }

    /**
     * @dev Sets or upgrades the rebalancer of the RariFundManager.
     * @param newAddress The Ethereum address of the new rebalancer server.
     */
    function setFundRebalancer(address newAddress) external onlyOwner {
        _rariFundRebalancerAddress = newAddress;
        emit FundRebalancerSet(newAddress);
    }

    /**
     * @dev Throws if called by any account other than the rebalancer.
     */
    modifier onlyRebalancer() {
        require(_rariFundRebalancerAddress == msg.sender, "Caller is not the rebalancer.");
        _;
    }

    /**
     * @dev Emitted when deposits to and withdrawals from this RariFundManager have been disabled.
     */
    event FundDisabled();

    /**
     * @dev Emitted when deposits to and withdrawals from this RariFundManager have been enabled.
     */
    event FundEnabled();

    /**
     * @dev Disables deposits to and withdrawals from this RariFundManager so contract(s) can be upgraded.
     */
    function disableFund() external onlyOwner {
        require(!_fundDisabled, "Fund already disabled.");
        _fundDisabled = true;
        emit FundDisabled();
    }

    /**
     * @dev Enables deposits to and withdrawals from this RariFundManager once contract(s) are upgraded.
     */
    function enableFund() external onlyOwner {
        require(_fundDisabled, "Fund already enabled.");
        _fundDisabled = false;
        emit FundEnabled();
    }

    /**
     * @dev Returns the fund's raw total balance (all RFT holders' funds + all unclaimed fees) of the specified currency.
     * Ideally, we can add the view modifier, but Compound's getUnderlyingBalance function (called by RariFundController.getPoolBalance) potentially modifies the state.
     * @param currencyCode The currency code of the balance to be calculated.
     */
    function getRawFundBalance(string memory currencyCode) internal returns (uint256) {
        address erc20Contract = _erc20Contracts[currencyCode];
        require(erc20Contract != address(0), "Invalid currency code.");

        ERC20 token = ERC20(erc20Contract);
        uint256 totalBalance = token.balanceOf(address(this));
        for (uint256 i = 0; i < _poolsByCurrency[currencyCode].length; i++) totalBalance = totalBalance.add(RariFundController.getPoolBalance(_poolsByCurrency[currencyCode][i], erc20Contract));
        for (uint256 i = 0; i < _withdrawalQueues[currencyCode].length; i++) totalBalance = totalBalance.sub(_withdrawalQueues[currencyCode][i].amount);

        return totalBalance;
    }

    /**
     * @notice Returns the fund's raw total balance (all RFT holders' funds + all unclaimed fees but not pending withdrawals) of all currencies in USD (scaled by 1e18).
     * @dev Ideally, we can add the view modifier, but Compound's getUnderlyingBalance function (called by getRawFundBalance) potentially modifies the state.
     */
    function getRawFundBalance() public returns (uint256) {
        uint256 totalBalance = 0;

        for (uint256 i = 0; i < _supportedCurrencies.length; i++) {
            string memory currencyCode = _supportedCurrencies[i];
            ERC20Detailed token = ERC20Detailed(_erc20Contracts[currencyCode]);
            uint256 tokenDecimals = token.decimals();
            uint256 balance = getRawFundBalance(_supportedCurrencies[i]);
            uint256 balanceUsd = 18 >= tokenDecimals ? balance.mul(10 ** (uint256(18).sub(tokenDecimals))) : balance.div(10 ** (tokenDecimals.sub(18))); // TODO: Factor in prices; for now we assume the value of all supported currencies = $1
            totalBalance = totalBalance.add(balanceUsd);
        }

        return totalBalance;
    }

    /**
     * @notice Returns the fund's total investor balance (all RFT holders' funds but not unclaimed fees or pending withdrawals) of all currencies in USD (scaled by 1e18).
     * @dev Ideally, we can add the view modifier, but Compound's getUnderlyingBalance function (called by getRawFundBalance) potentially modifies the state.
     */
    function getFundBalance() public returns (uint256) {
        return getRawFundBalance().sub(getInterestFeesUnclaimed());
    }

    /**
     * @notice Returns an account's total balance in USD (scaled by 1e18).
     * @dev Ideally, we can add the view modifier, but Compound's getUnderlyingBalance function (called by getRawFundBalance) potentially modifies the state.
     * @param account The account whose balance we are calculating.
     */
    function balanceOf(address account) external returns (uint256) {
        require(_rariFundTokenContract != address(0), "RariFundToken contract not set.");
        RariFundToken rariFundToken = RariFundToken(_rariFundTokenContract);
        uint256 rftTotalSupply = rariFundToken.totalSupply();
        if (rftTotalSupply == 0) return 0;
        uint256 rftBalance = rariFundToken.balanceOf(account);
        uint256 fundBalanceUsd = getFundBalance();
        uint256 accountBalanceUsd = rftBalance.mul(fundBalanceUsd).div(rftTotalSupply);
        return accountBalanceUsd;
    }

    /**
     * @dev Fund balance limit in USD per Ethereum address.
     */
    uint256 private _accountBalanceLimitUsd;

    /**
     * @dev Sets or upgrades the account balance limit in USD.
     * @param accountBalanceLimitUsd The fund balance limit in USD per Ethereum address.
     */
    function setAccountBalanceLimitUsd(uint256 accountBalanceLimitUsd) external onlyOwner {
        _accountBalanceLimitUsd = accountBalanceLimitUsd;
    }

    /**
     * @dev Fund balance limit in USD per Ethereum address.
     */
    mapping(string => bool) private _acceptedCurrencies;

    /**
     * @notice Returns a boolean indicating if deposits in `currencyCode` are currently accepted.
     * @param currencyCode The currency code to check.
     */
    function isCurrencyAccepted(string memory currencyCode) public view returns (bool) {
        return _acceptedCurrencies[currencyCode];
    }

    /**
     * @dev Marks `currencyCode` as accepted or not accepted.
     * @param currencyCode The currency code to mark as accepted or not accepted.
     * @param accepted A boolean indicating if the `currencyCode` is to be accepted.
     */
    function setAcceptedCurrency(string calldata currencyCode, bool accepted) external onlyRebalancer {
        _acceptedCurrencies[currencyCode] = accepted;
    }

    /**
     * @dev Emitted when funds have been deposited to RariFund.
     */
    event Deposit(string indexed currencyCode, address indexed sender, uint256 amount);

    /**
     * @dev Emitted when funds have been withdrawn from RariFund.
     */
    event Withdrawal(string indexed currencyCode, address indexed payee, uint256 amount);

    /**
     * @dev Emitted when funds have been queued for withdrawal from RariFund.
     */
    event WithdrawalQueued(string indexed currencyCode, address indexed payee, uint256 amount);

    /**
     * @notice Deposits funds to RariFund in exchange for RFT.
     * Please note that you must approve RariFundManager to transfer of the necessary amount of tokens.
     * @param currencyCode The current code of the token to be deposited.
     * @param amount The amount of tokens to be deposited.
     * @return Boolean indicating success.
     */
    function deposit(string calldata currencyCode, uint256 amount) external returns (bool) {
        require(!_fundDisabled, "Deposits to and withdrawals from the fund are currently disabled.");
        require(_rariFundTokenContract != address(0), "RariFundToken contract not set.");
        address erc20Contract = _erc20Contracts[currencyCode];
        require(erc20Contract != address(0), "Invalid currency code.");
        require(isCurrencyAccepted(currencyCode), "This currency is not currently accepted; please convert your funds to an accepted currency before depositing.");
        require(amount > 0, "Deposit amount must be greater than 0.");

        ERC20Detailed token = ERC20Detailed(erc20Contract);
        uint256 tokenDecimals = token.decimals();
        RariFundToken rariFundToken = RariFundToken(_rariFundTokenContract);
        uint256 rftTotalSupply = rariFundToken.totalSupply();
        uint256 rftAmount = 0;
        uint256 amountUsd = 18 >= tokenDecimals ? amount.mul(10 ** (uint256(18).sub(tokenDecimals))) : amount.div(10 ** (tokenDecimals.sub(18)));
        uint256 fundBalanceUsd = rftTotalSupply > 0 ? getFundBalance() : 0; // Only set if used
        if (rftTotalSupply > 0 && fundBalanceUsd > 0) rftAmount = amountUsd.mul(rftTotalSupply).div(fundBalanceUsd);
        else rftAmount = amountUsd;
        require(rftAmount > 0, "Deposit amount is so small that no RFT would be minted.");
        
        uint256 initialBalanceUsd = rftTotalSupply > 0 && fundBalanceUsd > 0 ? rariFundToken.balanceOf(msg.sender).mul(fundBalanceUsd).div(rftTotalSupply) : 0; // Save gas by reusing value of getFundBalance() instead of calling balanceOf
        require(initialBalanceUsd.add(amountUsd) <= _accountBalanceLimitUsd || msg.sender == _interestFeeMasterBeneficiary, "Making this deposit would cause this account's balance to exceed the maximum.");

        // Make sure the user must approve the transfer of tokens before calling the deposit function
        require(token.transferFrom(msg.sender, address(this), amount), "Failed to transfer input tokens.");
        _netDeposits = _netDeposits.add(int256(amountUsd));
        require(rariFundToken.mint(msg.sender, rftAmount), "Failed to mint output tokens.");
        emit Deposit(currencyCode, msg.sender, amount);
        return true;
    }

    /**
     * @notice Withdraws funds from RariFund in exchange for RFT.
     * Please note that you must approve RariFundManager to burn of the necessary amount of RFT.
     * @param currencyCode The current code of the token to be withdrawn.
     * @param amount The amount of tokens to be withdrawn.
     * @return Boolean indicating success.
     */
    function withdraw(string calldata currencyCode, uint256 amount) external returns (bool) {
        require(!_fundDisabled, "Deposits to and withdrawals from the fund are currently disabled.");
        require(_rariFundTokenContract != address(0), "RariFundToken contract not set.");
        address erc20Contract = _erc20Contracts[currencyCode];
        require(erc20Contract != address(0), "Invalid currency code.");
        require(amount > 0, "Withdrawal amount must be greater than 0.");

        ERC20Detailed token = ERC20Detailed(erc20Contract);
        uint256 tokenDecimals = token.decimals();
        uint256 contractBalance = token.balanceOf(address(this));

        RariFundToken rariFundToken = RariFundToken(_rariFundTokenContract);
        uint256 rftTotalSupply = rariFundToken.totalSupply();
        uint256 fundBalanceUsd = getFundBalance();
        require(fundBalanceUsd > 0, "Fund balance is zero.");
        uint256 amountUsd = 18 >= tokenDecimals ? amount.mul(10 ** (uint256(18).sub(tokenDecimals))) : amount.div(10 ** (tokenDecimals.sub(18)));
        uint256 rftAmount = amountUsd.mul(rftTotalSupply).div(fundBalanceUsd);
        require(rftAmount <= rariFundToken.balanceOf(msg.sender), "Your RFT balance is too low for a withdrawal of this amount.");
        require(rftAmount > 0, "Withdrawal amount is so small that no RFT would be burned.");
        require(amountUsd <= fundBalanceUsd, "Fund balance is too low for a withdrawal of this amount.");

        // Make sure the user must approve the burning of tokens before calling the withdraw function
        rariFundToken.burnFrom(msg.sender, rftAmount);
        _netDeposits = _netDeposits.sub(int256(amountUsd));

        if (amount <= contractBalance) {
            require(token.transfer(msg.sender, amount), "Failed to transfer output tokens.");
            emit Withdrawal(currencyCode, msg.sender, amount);
        } else  {
            _withdrawalQueues[currencyCode].push(PendingWithdrawal(msg.sender, amount));
            emit WithdrawalQueued(currencyCode, msg.sender, amount);
        }

        return true;
    }

    /**
     * @dev Processes pending withdrawals in the queue for the specified currency.
     * @param currencyCode The currency code of the token for which to process pending withdrawals.
     * @return Boolean indicating success.
     */
    function processPendingWithdrawals(string memory currencyCode) public returns (bool) {
        address erc20Contract = _erc20Contracts[currencyCode];
        require(erc20Contract != address(0), "Invalid currency code.");
        ERC20 token = ERC20(erc20Contract);
        uint256 balanceHere = token.balanceOf(address(this));
        uint256 total = 0;
        for (uint256 i = 0; i < _withdrawalQueues[currencyCode].length; i++) total = total.add(_withdrawalQueues[currencyCode][i].amount);
        if (total > balanceHere) revert("Not enough balance to process pending withdrawals.");

        for (uint256 i = 0; i < _withdrawalQueues[currencyCode].length; i++) {
            require(token.transfer(_withdrawalQueues[currencyCode][i].payee, _withdrawalQueues[currencyCode][i].amount), "Failed to transfer tokens.");
            emit Withdrawal(currencyCode, _withdrawalQueues[currencyCode][i].payee, _withdrawalQueues[currencyCode][i].amount);
        }

        _withdrawalQueues[currencyCode].length = 0;
        return true;
    }

    /**
     * @notice Returns the number of pending withdrawals in the queue of the specified currency.
     * @param currencyCode The currency code of the pending withdrawals.
     */
    function countPendingWithdrawals(string calldata currencyCode) external view returns (uint256) {
        return _withdrawalQueues[currencyCode].length;
    }

    /**
     * @notice Returns the payee of a pending withdrawal of the specified currency.
     * @param currencyCode The currency code of the pending withdrawal.
     * @param index The index of the pending withdrawal.
     */
    function getPendingWithdrawalPayee(string calldata currencyCode, uint256 index) external view returns (address) {
        return _withdrawalQueues[currencyCode][index].payee;
    }

    /**
     * @notice Returns the amount of a pending withdrawal of the specified currency.
     * @param currencyCode The currency code of the pending withdrawal.
     * @param index The index of the pending withdrawal.
     */
    function getPendingWithdrawalAmount(string calldata currencyCode, uint256 index) external view returns (uint256) {
        return _withdrawalQueues[currencyCode][index].amount;
    }

    /**
     * @dev Approves tokens to the pool without spending gas on every deposit.
     * @param pool The name of the pool.
     * @param currencyCode The currency code of the token to be approved.
     * @param amount The amount of tokens to be approved.
     * @return Boolean indicating success.
     */
    function approveToPool(uint8 pool, string calldata currencyCode, uint256 amount) external onlyRebalancer returns (bool) {
        address erc20Contract = _erc20Contracts[currencyCode];
        require(erc20Contract != address(0), "Invalid currency code.");
        require(RariFundController.approveToPool(pool, erc20Contract, amount), "Pool approval failed.");
        return true;
    }

    /**
     * @dev Deposits funds from any supported pool.
     * @param pool The name of the pool.
     * @param currencyCode The currency code of the token to be deposited.
     * @param amount The amount of tokens to be deposited.
     * @return Boolean indicating success.
     */
    function depositToPool(uint8 pool, string calldata currencyCode, uint256 amount) external onlyRebalancer returns (bool) {
        address erc20Contract = _erc20Contracts[currencyCode];
        require(erc20Contract != address(0), "Invalid currency code.");
        require(RariFundController.depositToPool(pool, erc20Contract, amount), "Pool deposit failed.");
        return true;
    }

    /**
     * @dev Withdraws funds from any supported pool.
     * @param pool The name of the pool.
     * @param currencyCode The currency code of the token to be withdrawn.
     * @param amount The amount of tokens to be withdrawn.
     * @return Boolean indicating success.
     */
    function withdrawFromPool(uint8 pool, string calldata currencyCode, uint256 amount) external onlyRebalancer returns (bool) {
        address erc20Contract = _erc20Contracts[currencyCode];
        require(erc20Contract != address(0), "Invalid currency code.");
        require(RariFundController.withdrawFromPool(pool, erc20Contract, amount), "Pool withdrawal failed.");
        return true;
    }

    /**
     * @dev Withdraws all funds from any supported pool.
     * @param pool The name of the pool.
     * @param currencyCode The ERC20 contract of the token to be withdrawn.
     * @return Boolean indicating success.
     */
    function withdrawAllFromPool(uint8 pool, string calldata currencyCode) external onlyRebalancer returns (bool) {
        address erc20Contract = _erc20Contracts[currencyCode];
        require(erc20Contract != address(0), "Invalid currency code.");
        require(RariFundController.withdrawAllFromPool(pool, erc20Contract), "Pool withdrawal failed.");
        return true;
    }

    /**
     * @dev Approves tokens to 0x without spending gas on every deposit.
     * @param currencyCode The currency code of the token to be approved.
     * @param amount The amount of tokens to be approved.
     * @return Boolean indicating success.
     */
    function approveTo0x(string calldata currencyCode, uint256 amount) external onlyRebalancer returns (bool) {
        address erc20Contract = _erc20Contracts[currencyCode];
        require(erc20Contract != address(0), "Invalid currency code.");
        require(RariFundController.approveTo0x(erc20Contract, amount), "0x approval failed.");
        return true;
    }

    /**
     * @dev Fills 0x exchange orders up to a certain amount of input and up to a certain price.
     * We should be able to make this function external and use calldata for all parameters, but Solidity does not support calldata structs (https://github.com/ethereum/solidity/issues/5479).
     * @param orders The limit orders to be filled in ascending order of price.
     * @param signatures The signatures for the orders.
     * @param takerAssetFillAmount The amount of the taker asset to sell (excluding taker fees).
     * @return Boolean indicating success.
     */
    function fill0xOrdersUpTo(LibOrder.Order[] memory orders, bytes[] memory signatures, uint256 takerAssetFillAmount) public payable onlyRebalancer returns (bool) {
        uint256[2] memory filledAmounts = RariFundController.fill0xOrdersUpTo(orders, signatures, takerAssetFillAmount);
        require(filledAmounts[1] > 0, "Filling orders via 0x failed.");
        return true;
    }

    /**
     * @dev Net quantity of deposits to the fund (i.e., deposits - withdrawals).
     * On deposit, amount deposited is added to _netDeposits; on withdrawal, amount withdrawn is subtracted from _netDeposits.
     */
    int256 private _netDeposits;
    
    /**
     * @notice Returns the raw total amount of interest accrued by the fund as a whole (including the fees paid on interest) in USD (scaled by 1e18).
     * @dev Ideally, we can add the view modifier, but Compound's getUnderlyingBalance function (called by getRawFundBalance) potentially modifies the state.
     */
    function getRawInterestAccrued() public returns (int256) {
        return int256(getRawFundBalance()).sub(_netDeposits).add(int256(_interestFeesClaimed));
    }
    
    /**
     * @notice Returns the total amount of interest accrued by past and current RFT holders (excluding the fees paid on interest) in USD (scaled by 1e18).
     * @dev Ideally, we can add the view modifier, but Compound's getUnderlyingBalance function (called by getRawFundBalance) potentially modifies the state.
     */
    function getInterestAccrued() public returns (int256) {
        return int256(getFundBalance()).sub(_netDeposits);
    }

    /**
     * @dev The proportion of interest accrued that is taken as a service fee (scaled by 1e18).
     */
    uint256 private _interestFeeRate;

    /**
     * @dev Returns the fee rate on interest.
     */
    function getInterestFeeRate() public view returns (uint256) {
        return _interestFeeRate;
    }

    /**
     * @dev Sets the fee rate on interest.
     * @param rate The proportion of interest accrued to be taken as a service fee (scaled by 1e18).
     */
    function setInterestFeeRate(uint256 rate) external onlyOwner {
        require(rate != _interestFeeRate, "This is already the current interest fee rate.");
        _depositFees();
        _interestFeesGeneratedAtLastFeeRateChange = getInterestFeesGenerated(); // MUST update this first before updating _rawInterestAccruedAtLastFeeRateChange since it depends on it 
        _rawInterestAccruedAtLastFeeRateChange = getRawInterestAccrued();
        _interestFeeRate = rate;
    }

    /**
     * @dev The amount of interest accrued at the time of the most recent change to the fee rate.
     */
    int256 private _rawInterestAccruedAtLastFeeRateChange;

    /**
     * @dev The amount of fees generated on interest at the time of the most recent change to the fee rate.
     */
    int256 private _interestFeesGeneratedAtLastFeeRateChange;

    /**
     * @notice Returns the amount of interest fees accrued by beneficiaries in USD (scaled by 1e18).
     * @dev Ideally, we can add the view modifier, but Compound's getUnderlyingBalance function (called by getRawFundBalance) potentially modifies the state.
     */
    function getInterestFeesGenerated() public returns (int256) {
        int256 rawInterestAccruedSinceLastFeeRateChange = getRawInterestAccrued().sub(_rawInterestAccruedAtLastFeeRateChange);
        int256 interestFeesGeneratedSinceLastFeeRateChange = rawInterestAccruedSinceLastFeeRateChange.mul(int256(_interestFeeRate)).div(1e18);
        int256 interestFeesGenerated = _interestFeesGeneratedAtLastFeeRateChange.add(interestFeesGeneratedSinceLastFeeRateChange);
        return interestFeesGenerated;
    }

    /**
     * @dev The total claimed amount of interest fees.
     */
    uint256 private _interestFeesClaimed;

    /**
     * @dev Returns the total unclaimed amount of interest fees.
     * Ideally, we can add the view modifier, but Compound's getUnderlyingBalance function (called by getRawFundBalance) potentially modifies the state.
     */
    function getInterestFeesUnclaimed() public returns (uint256) {
        int256 interestFeesUnclaimed = getInterestFeesGenerated().sub(int256(_interestFeesClaimed));
        return interestFeesUnclaimed > 0 ? uint256(interestFeesUnclaimed) : 0;
    }

    /**
     * @dev The master beneficiary of fees on interest; i.e., the recipient of all fees on interest.
     */
    address private _interestFeeMasterBeneficiary;

    /**
     * @dev Sets the master beneficiary of interest fees.
     * @param beneficiary The master beneficiary of fees on interest; i.e., the recipient of all fees on interest.
     */
    function setInterestFeeMasterBeneficiary(address beneficiary) external onlyOwner {
        require(beneficiary != address(0), "Interest fee master beneficiary cannot be the zero address.");
        _interestFeeMasterBeneficiary = beneficiary;
    }

    /**
     * @dev Emitted when fees on interest are deposited back into the fund.
     */
    event InterestFeeDeposit(address beneficiary, uint256 amountUsd);

    /**
     * @dev Emitted when fees on interest are withdrawn.
     */
    event InterestFeeWithdrawal(address beneficiary, uint256 amountUsd, string currencyCode, uint256 amount);

    /**
     * @dev Internal function to deposit all accrued fees on interest back into the fund on behalf of the master beneficiary.
     * @return Boolean indicating success.
     */
    function _depositFees() internal returns (bool) {
        require(!_fundDisabled, "This RariFundManager contract is currently disabled.");
        require(_interestFeeMasterBeneficiary != address(0), "Master beneficiary cannot be the zero address.");
        require(_rariFundTokenContract != address(0), "RariFundToken contract not set.");
        
        uint256 amountUsd = getInterestFeesUnclaimed();
        if (amountUsd == 0) return false;

        RariFundToken rariFundToken = RariFundToken(_rariFundTokenContract);
        uint256 rftTotalSupply = rariFundToken.totalSupply();
        uint256 rftAmount = 0;
        
        if (rftTotalSupply > 0) {
            uint256 fundBalanceUsd = getFundBalance();
            if (fundBalanceUsd > 0) rftAmount = amountUsd.mul(rftTotalSupply).div(fundBalanceUsd);
            else rftAmount = amountUsd;
        } else rftAmount = amountUsd;

        if (rftAmount == 0) return false;
        _interestFeesClaimed = _interestFeesClaimed.add(amountUsd);
        _netDeposits = _netDeposits.add(int256(amountUsd));
        require(rariFundToken.mint(_interestFeeMasterBeneficiary, rftAmount), "Failed to mint output tokens.");
        emit Deposit("USD", _interestFeeMasterBeneficiary, amountUsd);
        
        emit InterestFeeDeposit(_interestFeeMasterBeneficiary, amountUsd);
        return true;
    }

    /**
     * @notice Deposits all accrued fees on interest back into the fund on behalf of the master beneficiary.
     * @return Boolean indicating success.
     */
    function depositFees() external onlyRebalancer returns (bool) {
        require(!_fundDisabled, "This RariFundManager contract is currently disabled.");
        require(_interestFeeMasterBeneficiary != address(0), "Master beneficiary cannot be the zero address.");
        require(_rariFundTokenContract != address(0), "RariFundToken contract not set.");
        
        uint256 amountUsd = getInterestFeesUnclaimed();
        require(amountUsd > 0, "No new fees are available to claim.");

        RariFundToken rariFundToken = RariFundToken(_rariFundTokenContract);
        uint256 rftTotalSupply = rariFundToken.totalSupply();
        uint256 rftAmount = 0;
        
        if (rftTotalSupply > 0) {
            uint256 fundBalanceUsd = getFundBalance();
            if (fundBalanceUsd > 0) rftAmount = amountUsd.mul(rftTotalSupply).div(fundBalanceUsd);
            else rftAmount = amountUsd;
        } else rftAmount = amountUsd;

        require(rftAmount > 0, "Deposit amount is so small that no RFT would be minted.");
        _interestFeesClaimed = _interestFeesClaimed.add(amountUsd);
        _netDeposits = _netDeposits.add(int256(amountUsd));
        require(rariFundToken.mint(_interestFeeMasterBeneficiary, rftAmount), "Failed to mint output tokens.");
        emit Deposit("USD", _interestFeeMasterBeneficiary, amountUsd);
        
        emit InterestFeeDeposit(_interestFeeMasterBeneficiary, amountUsd);
        return true;
    }

    /**
     * @notice Withdraws all accrued fees on interest to the master beneficiary.
     * @param currencyCode The currency code of the interest fees to be claimed.
     * @return Boolean indicating success.
     */
    function withdrawFees(string calldata currencyCode) external onlyRebalancer returns (bool) {
        require(!_fundDisabled, "This RariFundManager contract is currently disabled.");
        require(_interestFeeMasterBeneficiary != address(0), "Master beneficiary cannot be the zero address.");
        address erc20Contract = _erc20Contracts[currencyCode];
        require(erc20Contract != address(0), "Invalid currency code.");
        
        uint256 amountUsd = getInterestFeesUnclaimed();
        ERC20Detailed token = ERC20Detailed(erc20Contract);
        uint256 tokenDecimals = token.decimals();
        uint256 amount = 18 >= tokenDecimals ? amountUsd.div(10 ** (uint256(18).sub(tokenDecimals))) : amountUsd.mul(10 ** (tokenDecimals.sub(18))); // TODO: Factor in prices; for now we assume the value of all supported currencies = $1
        require(amount > 0, "No new fees are available to claim.");
        
        _interestFeesClaimed = _interestFeesClaimed.add(amountUsd);
        require(ERC20(erc20Contract).transfer(_interestFeeMasterBeneficiary, amount), "Failed to transfer fees to beneficiary.");
        
        emit InterestFeeWithdrawal(_interestFeeMasterBeneficiary, amountUsd, currencyCode, amount);
        return true;
    }
}
