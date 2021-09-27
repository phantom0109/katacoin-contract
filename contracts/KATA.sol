// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import "./KATADividendTracker.sol";
import "./FTPAntiBot.sol";
import "./SafeMath.sol";
import "./Ownable.sol";
import "./IUniswapV2Pair.sol";
import "./IUniswapV2Factory.sol";
import "./IUniswapV2Router.sol";

contract KATA is ERC20, Ownable {
    using SafeMath for uint256;

    FTPAntiBot private antiBot;
    bool public useAntiBot = true;

    IUniswapV2Router02 public uniswapV2Router;
    address public immutable uniswapV2Pair;

    bool private liquidating;

    KATADividendTracker public dividendTracker;

    address public liquidityWallet;

    uint256 public constant MAX_SELL_TRANSACTION_AMOUNT = 1000000 * (10**18);

    uint256 public constant ETH_REWARDS_FEE = 4;
    uint256 public constant LIQUIDITY_FEE = 2;
    uint256 public constant TOTAL_FEES = ETH_REWARDS_FEE + LIQUIDITY_FEE;

    // burn percentage per transaction
    uint256 public constant BUYBACK_FEE = 2;

    // use by default 150,000 gas to process auto-claiming dividends
    uint256 public gasForProcessing = 150000;

    // liquidate tokens for ETH when the contract reaches 100k tokens by default
    uint256 public liquidateTokensAtAmount = 100000 * (10**18);

    // whether the token can already be traded
    bool public tradingEnabled;

    // exclude from fees and max transaction amount
    mapping (address => bool) private _isExcludedFromFees;

    // addresses that can make transfers before presale is over
    mapping (address => bool) public canTransferBeforeTradingIsEnabled;

    // store addresses that a automatic market maker pairs. Any transfer *to* these addresses
    // could be subject to a maximum transfer amount
    mapping (address => bool) public automatedMarketMakerPairs;

    event UpdatedAntiBot(address indexed newAddress, address indexed oldAddress);

    event ToggledAntiBot(bool newValue, bool oldValue);

    event UpdatedDividendTracker(address indexed newAddress, address indexed oldAddress);

    event UpdatedUniswapV2Router(address indexed newAddress, address indexed oldAddress);

    event SetAutomatedMarketMakerPair(address indexed pair, bool indexed value);

    event LiquidityWalletUpdated(address indexed newLiquidityWallet, address indexed oldLiquidityWallet);

    event GasForProcessingUpdated(uint256 indexed newValue, uint256 indexed oldValue);

    event LiquidationThresholdUpdated(uint256 indexed newValue, uint256 indexed oldValue);

    event Liquified(
        uint256 tokensSwapped,
        uint256 ethReceived,
        uint256 tokensIntoLiqudity
    );

    event SentDividends(
        uint256 tokensSwapped,
        uint256 amount
    );

    event ProcessedDividendTracker(
        uint256 iterations,
        uint256 claims,
        uint256 lastProcessedIndex,
        bool indexed automatic,
        uint256 gas,
        address indexed processor
    );

    constructor() ERC20("KATA", "KATA") {
        assert(TOTAL_FEES == 6);

        dividendTracker = new KATADividendTracker();
        liquidityWallet = owner();

        IUniswapV2Router02 _uniswapV2Router = IUniswapV2Router02(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
        // Create a uniswap pair for this new token
        address _uniswapV2Pair = IUniswapV2Factory(_uniswapV2Router.factory()).createPair(address(this), _uniswapV2Router.WETH());

        FTPAntiBot _antiBot = FTPAntiBot(0xCD5312d086f078D1554e8813C27Cf6C9D1C3D9b3);
        antiBot = _antiBot;

        uniswapV2Router = _uniswapV2Router;
        uniswapV2Pair = _uniswapV2Pair;

        _setAutomatedMarketMakerPair(_uniswapV2Pair, true);

        // exclude from receiving dividends
        dividendTracker.excludeFromDividends(address(dividendTracker));
        dividendTracker.excludeFromDividends(address(this));
        dividendTracker.excludeFromDividends(owner());
        dividendTracker.excludeFromDividends(address(_uniswapV2Router));

        // exclude from paying fees or having max transaction amount
        excludeFromFees(liquidityWallet);
        excludeFromFees(address(this));

        // enable owner wallet to send tokens before presales are over.
        canTransferBeforeTradingIsEnabled[owner()] = true;

        /*
            _mint is an internal function in ERC20.sol that is only called here,
            and CANNOT be called ever again
        */
        _mint(owner(), 50 * (10**9) * (10**18));   // 50B supply; 1B = 1e9
    }

    receive() external payable {

    }

    function activate() external onlyOwner {
        require(!tradingEnabled, "KATA: Trading is already enabled");
        tradingEnabled = true;
    }

    function updateDividendTracker(address newAddress) external onlyOwner {
        require(newAddress != address(dividendTracker), "KATA: The dividend tracker already has that address");
        require(newAddress != address(0), "KATA: newAddress is a zero address");

        KATADividendTracker newDividendTracker = KATADividendTracker(payable(newAddress));

        require(newDividendTracker.owner() == address(this), "KATA: The new dividend tracker must be owned by the KATA token contract");

        newDividendTracker.excludeFromDividends(address(newDividendTracker));
        newDividendTracker.excludeFromDividends(address(this));
        newDividendTracker.excludeFromDividends(owner());
        newDividendTracker.excludeFromDividends(address(uniswapV2Router));

        emit UpdatedDividendTracker(newAddress, address(dividendTracker));

        dividendTracker = newDividendTracker;
    }

    function updateUniswapV2Router(address newAddress) external onlyOwner {
        require(newAddress != address(uniswapV2Router), "KATA: The router already has that address");
        require(newAddress != address(0), "KATA: newAddress is a zero address");

        emit UpdatedUniswapV2Router(newAddress, address(uniswapV2Router));
        uniswapV2Router = IUniswapV2Router02(newAddress);
    }

    function excludeFromFees(address account) public onlyOwner {
        require(!_isExcludedFromFees[account], "KATA: Account is already excluded from fees");
        _isExcludedFromFees[account] = true;
    }

    function setAutomatedMarketMakerPair(address pair, bool value) external onlyOwner {
        require(pair != uniswapV2Pair, "KATA: The Uniswap pair cannot be removed from automatedMarketMakerPairs");
        require(pair != address(0), "KATA: pair is a zero address");

        _setAutomatedMarketMakerPair(pair, value);
    }

    function _setAutomatedMarketMakerPair(address pair, bool value) private {
        require(automatedMarketMakerPairs[pair] != value, "KATA: Automated market maker pair is already set to that value");
        automatedMarketMakerPairs[pair] = value;

        if (value) {
            dividendTracker.excludeFromDividends(pair);
        }

        emit SetAutomatedMarketMakerPair(pair, value);
    }

    function allowTransferBeforeTradingIsEnabled(address account) external onlyOwner {
        require(!canTransferBeforeTradingIsEnabled[account], "KATA: Account is already allowed to transfer before trading is enabled");
        canTransferBeforeTradingIsEnabled[account] = true;
    }

    function updateLiquidityWallet(address newLiquidityWallet) external onlyOwner {
        require(newLiquidityWallet != liquidityWallet, "KATA: The liquidity wallet is already this address");
        require(newLiquidityWallet != address(0), "KATA: newLiquidityWallet is a zero address");
        excludeFromFees(newLiquidityWallet);
        emit LiquidityWalletUpdated(newLiquidityWallet, liquidityWallet);
        liquidityWallet = newLiquidityWallet;
    }

    function updateGasForProcessing(uint256 newValue) external onlyOwner {
        // Need to make gas fee customizable to future-proof against Ethereum network upgrades.
        require(newValue != gasForProcessing, "KATA: Cannot update gasForProcessing to same value");
        emit GasForProcessingUpdated(newValue, gasForProcessing);
        gasForProcessing = newValue;
    }

    function updateLiquidationThreshold(uint256 newValue) external onlyOwner {
        require(newValue <= 200000 * (10 ** 18), "KATA: liquidateTokensAtAmount must be less than 200,000");
        require(newValue != liquidateTokensAtAmount, "KATA: Cannot update gasForProcessing to same value");
        emit LiquidationThresholdUpdated(newValue, liquidateTokensAtAmount);
        liquidateTokensAtAmount = newValue;
    }

    function updateGasForTransfer(uint256 gasForTransfer) external onlyOwner {
        dividendTracker.updateGasForTransfer(gasForTransfer);
    }

    function updateClaimWait(uint256 claimWait) external onlyOwner {
        dividendTracker.updateClaimWait(claimWait);
    }

    function getGasForTransfer() external view returns(uint256) {
        return dividendTracker.gasForTransfer();
    }

    function getClaimWait() external view returns(uint256) {
        return dividendTracker.claimWait();
    }

    function getTotalDividendsDistributed() external view returns (uint256) {
        return dividendTracker.totalDividendsDistributed();
    }

    function isExcludedFromFees(address account) external view returns(bool) {
        return _isExcludedFromFees[account];
    }

    function withdrawableDividendOf(address account) external view returns(uint256) {
        return dividendTracker.withdrawableDividendOf(account);
    }

    function dividendTokenBalanceOf(address account) external view returns (uint256) {
        return dividendTracker.balanceOf(account);
    }

    function getAccountDividendsInfo(address account)
    external view returns (
        address,
        int256,
        int256,
        uint256,
        uint256,
        uint256,
        uint256,
        uint256) {
        return dividendTracker.getAccount(account);
    }

    function getAccountDividendsInfoAtIndex(uint256 index)
    external view returns (
        address,
        int256,
        int256,
        uint256,
        uint256,
        uint256,
        uint256,
        uint256) {
        return dividendTracker.getAccountAtIndex(index);
    }

    function processDividendTracker(uint256 gas) external {
        (uint256 iterations, uint256 claims, uint256 lastProcessedIndex) = dividendTracker.process(gas);
        emit ProcessedDividendTracker(iterations, claims, lastProcessedIndex, false, gas, tx.origin);
    }

    function claim() external {
        dividendTracker.processAccount(payable(msg.sender), false);
    }

    function getLastProcessedIndex() external view returns(uint256) {
        return dividendTracker.getLastProcessedIndex();
    }

    function getNumberOfDividendTokenHolders() external view returns(uint256) {
        return dividendTracker.getNumberOfTokenHolders();
    }

    function updateAntiBot(address newAddress) external onlyOwner {
        require(newAddress != address(0), "KATA: newAddress is a zero address");
        FTPAntiBot _antiBot = FTPAntiBot(newAddress);
        emit UpdatedAntiBot(newAddress, address(antiBot));
        antiBot = _antiBot;
    }

    function toggleAntiBot() external onlyOwner {
        bool newValue = !useAntiBot;
        emit ToggledAntiBot(newValue, useAntiBot);
        useAntiBot = newValue;
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");

        bool tradingIsEnabled = tradingEnabled;

        // only whitelisted addresses can make transfers before the public presale is over.
        if (!tradingIsEnabled) {
            require(canTransferBeforeTradingIsEnabled[from], "KATA: This account cannot send tokens until trading is enabled");
        }

        if (useAntiBot) {
            if ((from == uniswapV2Pair || to == uniswapV2Pair) && tradingIsEnabled) {
                require(!antiBot.scanAddress(from, uniswapV2Pair, tx.origin),  "Beep Beep Boop, You're a piece of poop");
                require(!antiBot.scanAddress(to, uniswapV2Pair, tx.origin), "Beep Beep Boop, You're a piece of poop");
            }
        }

        if (amount == 0) {
            super._transfer(from, to, 0);
            return;
        }

        if (!liquidating &&
            tradingIsEnabled &&
            automatedMarketMakerPairs[to] && // sells only by detecting transfer to automated market maker pair
            from != address(uniswapV2Router) && //router -> pair is removing liquidity which shouldn't have max
            !_isExcludedFromFees[to] //no max for those excluded from fees
        ) {
            require(amount <= MAX_SELL_TRANSACTION_AMOUNT, "Sell transfer amount exceeds the MAX_SELL_TRANSACTION_AMOUNT.");
        }

        uint256 contractTokenBalance = balanceOf(address(this));

        bool canSwap = contractTokenBalance >= liquidateTokensAtAmount;

        if (tradingIsEnabled &&
            canSwap &&
            !liquidating &&
            !automatedMarketMakerPairs[from] &&
            from != liquidityWallet &&
            to != liquidityWallet
        ) {
            liquidating = true;

            uint256 swapTokens = contractTokenBalance.mul(LIQUIDITY_FEE).div(TOTAL_FEES);
            swapAndLiquify(swapTokens);

            uint256 sellTokens = balanceOf(address(this));
            swapAndSendDividends(sellTokens);

            liquidating = false;
        }

        bool takeFee = tradingIsEnabled && !liquidating;

        // if any account belongs to _isExcludedFromFee account then remove the fee
        if (_isExcludedFromFees[from] || _isExcludedFromFees[to]) {
            takeFee = false;
        }
        
        uint256 buyback_fee = amount.mul(BUYBACK_FEE).div(100);

        if (takeFee) {
            uint256 fees = amount.mul(TOTAL_FEES).div(100);
            amount = amount.sub(fees);

            super._transfer(from, address(this), fees);
        }

        if (from != uniswapV2Pair && to != uniswapV2Pair) {
            super._burn(from, buyback_fee);
        }
        super._transfer(from, to, amount.sub(buyback_fee));

        try dividendTracker.setBalance(payable(from), balanceOf(from)) {} catch {}
        try dividendTracker.setBalance(payable(to), balanceOf(to)) {} catch {}

        if (useAntiBot) {
            // Tells AntiBot to start watching.
            antiBot.registerBlock(from, to, tx.origin);
        }

        if (!liquidating) {
            uint256 gas = gasForProcessing;

            try dividendTracker.process(gas) returns (uint256 iterations, uint256 claims, uint256 lastProcessedIndex) {
                emit ProcessedDividendTracker(iterations, claims, lastProcessedIndex, true, gas, tx.origin);
            } catch {

            }
        }
    }

    function swapAndLiquify(uint256 tokens) private {
        // split the contract balance into halves
        uint256 half = tokens.div(2);
        uint256 otherHalf = tokens.sub(half);

        // capture the contract's current ETH balance.
        // this is so that we can capture exactly the amount of ETH that the
        // swap creates, and not make the liquidity event include any ETH that
        // has been manually sent to the contract
        uint256 initialBalance = address(this).balance;

        // swap tokens for ETH
        swapTokensForEth(half); // <- this breaks the ETH -> HATE swap when swap+liquify is triggered

        // how much ETH did we just swap into?
        uint256 newBalance = address(this).balance.sub(initialBalance);

        // add liquidity to uniswap
        addLiquidity(otherHalf, newBalance);

        emit Liquified(half, newBalance, otherHalf);
    }

    function swapTokensForEth(uint256 tokenAmount) private {
        // generate the uniswap pair path of token -> weth
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();

        _approve(address(this), address(uniswapV2Router), tokenAmount);

        // make the swap
        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            address(this),
            block.timestamp
        );
    }

    function addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {
        // approve token transfer to cover all possible scenarios
        _approve(address(this), address(uniswapV2Router), tokenAmount);

        // add the liquidity
        uniswapV2Router.addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            liquidityWallet,
            block.timestamp
        );
    }

    function swapAndSendDividends(uint256 tokens) private {
        swapTokensForEth(tokens);
        uint256 dividends = address(this).balance;

        (bool success,) = address(dividendTracker).call{value: dividends}("");
        if (success) {
            emit SentDividends(tokens, dividends);
        }
    }

    function burn(address account, uint256 amount) external onlyOwner {
        _burn(account, amount);
    }
}
