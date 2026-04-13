// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapRouter} from "../Interface/ISwapRouter.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "../Interface/IAutomationRegistrar.sol";
import "../Interface/IAutomationRegistryConsumer.sol";
import "../Interface/LinkTokenInterface.sol";
import "../Interface/IPegSwap.sol";
import "../Interface/IDoppiTrader.sol";
import "../Interface/IDoppiTraderFactory.sol";
import "./DoppiUpkeepManagerTypes.sol";
import {DALiquidityLib} from "../Library/DALiquidityLib.sol";
import {AggregatorV3Interface} from "../Interface/AggregatorV3Interface.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
// import "forge-std/console.sol";

contract DoppiUpkeepManager is Ownable {
    using SafeERC20 for IERC20;
    
    // Chainlink Registrar and LINK token interfaces
    IAutomationRegistrar public registrar;
    IAutomationRegistryConsumer public registryConsumer;
    LinkTokenInterface public linkToken;
    IDoppiTraderFactory public doppiTraderFactory;
    IERC20 public fundToken;
    IERC20 public link;
    
    
    // State variables
    mapping(address => DoppiUpkeepInfo) public doppiUpkeeps;
    mapping(uint256 => address) public doppiUpKeepsId;
    mapping(address => address[]) public traderToBot;
    mapping(uint256 => DoppiUpkeepPayment) public doppiUpkeepPayment;
    
    AggregatorV3Interface immutable chainLinkFeed;
    address public immutable router;
    IPegSwap public immutable pegSwap;
    uint8 public constant TRIGGER_CONDITION = 0; // CONDITION trigger
    uint24 public constant MAX_SLIPPAGE = 500;  // 5%
    uint32 public maxDelay = 10 minutes; 
    uint32 public DEFAULT_GASLIMIT = 2_500_000;
    uint96 public DEFAULT_AMOUNT = 50 ether;
    uint24 public slippage = 100; //1.0%
    uint24 public doppiBotFee = 2000; // 20% of chainlink fee
    uint256 public MINSPENT = 0.5 ether; // in link token
    uint256 public priceDecimals; 
    bytes public multihopPathFrom;
    bytes public multihopPathTo;
    address public treasury;
    address public s_forwarderAddress;
        
    // Events
    event UpkeepRegistered(uint256 indexed upkeepId, address targetContract, uint256 fundTokenAmount, uint256 linkAmount);
    event UpkeepFunded(uint256 indexed upkeepId, uint256 fundTokenAmount, uint256 linkAmount, uint256 fee);
    event UpkeepCanceled(uint256 indexed upkeepId);
    event TopUpPerformed(uint256 indexed upkeepId, address bot, uint256 topUpAmountInfundToken, uint256 linkOut, uint256 fee);

    
    modifier onlyTrader(uint256 _upkeepId) {
        require(doppiUpkeeps[doppiUpKeepsId[_upkeepId]].trader == msg.sender, "only trader");
        _;
    }
    
    modifier validUpkeepId(uint256 _upkeepId) {
        require(doppiUpKeepsId[_upkeepId] != address(0), "Invalid upkeep ID");
        _;
    }

    modifier onlyForwarder() {
        require(msg.sender == s_forwarderAddress, "invalid forwarder");
        _;
    }
    
    constructor(
        address _registryConsumer,
        address _registrar,
        address _chainLinkFeed,
        address _router,
        address _pegSwap,
        address _fundToken,
        address _linkToken,
        address _link,
        address _doppiTraderFactory,
        address _treasury
    ) Ownable(msg.sender) {
        treasury = _treasury;
        registrar = IAutomationRegistrar(_registrar); 
        registryConsumer = IAutomationRegistryConsumer(_registryConsumer); 
        chainLinkFeed = AggregatorV3Interface(_chainLinkFeed);
        priceDecimals = 10 ** DALiquidityLib.getPriceDecimals(chainLinkFeed);
        fundToken = IERC20(_fundToken);
        router = _router; 
        pegSwap = IPegSwap(_pegSwap);
        doppiTraderFactory = IDoppiTraderFactory(_doppiTraderFactory);
        linkToken = LinkTokenInterface(_linkToken);
        link = IERC20(_link); 
        
        multihopPathFrom = abi.encodePacked(
            address(fundToken), // USDT
            uint24(100),                                       // fee
            address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c), // WBNB
            uint24(2500),                                       // fee
            address(link) // LINK
        );

        multihopPathTo = abi.encodePacked(
            address(link), // LINK
            uint24(2500),     
            address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c), // WBNB
            uint24(100),                                       // fee
            address(fundToken) // USDT                                  // fee
        );
        IERC20(fundToken).approve(router, type(uint256).max);
        IERC20(link).approve(address(pegSwap), type(uint256).max);
        linkToken.approve(address(pegSwap), type(uint256).max);
        link.approve(address(router), type(uint256).max);
    }
    
    function setMaxDelay(uint32 _maxDelay) external onlyOwner {
        maxDelay = _maxDelay;
    }

    function setForwarderAddress(address forwarderAddress) external onlyOwner {
        require(forwarderAddress != address(0), "zero forwarder");
        s_forwarderAddress = forwarderAddress;
    }

    function setRegistryConsumer(address _registryConsumer) external onlyOwner {
        registryConsumer = IAutomationRegistryConsumer(_registryConsumer);
    }

    function setMinSpent(uint24 _min) external onlyOwner {
        MINSPENT = _min;
    }

    function setDoppiBotFee(uint24 _doppiBotFee) external onlyOwner {
        require(_doppiBotFee <= 3000, "fee exceeds 30%"); 
        doppiBotFee = _doppiBotFee;
    }

    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "zero treasury");
        treasury = _treasury;
    }

    function setSwapPathFrom(bytes calldata _multihopPath) external onlyOwner {
        multihopPathFrom = _multihopPath;
    }

    function setSwapPathTo(bytes calldata _multihopPath) external onlyOwner {
        multihopPathTo = _multihopPath;
    }

    function setDefault_GasLimit(uint32 _gasLimit) external onlyOwner {
        DEFAULT_GASLIMIT = _gasLimit;
    }

    function setDefault_Amount(uint96 _topUp) external onlyOwner {
        DEFAULT_AMOUNT = _topUp;
    }

    function setSlippage(uint24 _slippage) external onlyOwner {
        require(_slippage <= MAX_SLIPPAGE, "slippage too high");
        slippage = _slippage;
    }

    function stopWithdraw(uint256 _upkeepId) external onlyTrader(_upkeepId) validUpkeepId(_upkeepId) {
        
        IAutomationRegistryConsumer.UpkeepInfo memory result = registryConsumer.getUpkeep(_upkeepId);
        require(result.maxValidBlocknumber < block.number, "not cancel yet");
        uint256 initBal = linkToken.balanceOf(address(this));
        registryConsumer.withdrawFunds(_upkeepId, address(this));
        (uint96 fee, address trader) = _getUnPaidDoppiFee(_upkeepId);
        uint256 finalBal = linkToken.balanceOf(address(this));
        // back to trader
        uint256 diff = finalBal - initBal;
        uint256 refund = diff > fee ? diff - fee : 0;

        // reset 
        address targetContract = doppiUpKeepsId[_upkeepId];
        doppiUpkeeps[targetContract].upkeepId = 0;
        doppiUpkeeps[targetContract].isRegistered = false;
        doppiUpkeepPayment[_upkeepId].lastBlockCharged = block.number;
        doppiUpkeepPayment[_upkeepId].lastPaidAmount = 0;
        doppiUpkeepPayment[_upkeepId].trader = address(0);
        
        // reset forwarder in trader bot 
        IDoppiTrader(targetContract).setForwarderAddress(address(0));

        if(finalBal >= fee) IERC20(address(linkToken)).safeTransfer(treasury, fee);
        if(refund > 0) {
            uint256 fundTokenOut = _swapERC677ToFundToken(refund);
            fundToken.safeTransfer(trader, fundTokenOut);
        }
    }

    // trader top up using USDT manually
    function fundUpkeep(uint256 _upkeepId, uint96 _amount) external onlyTrader(_upkeepId) validUpkeepId(_upkeepId) {
        
        require(_amount > 0, "invalid amount");
        fundToken.safeTransferFrom(msg.sender, address(this), _amount);
        uint256 linkAmount = _swapToLinkERC677(_amount);
        (uint256 fee, ) = _getUnPaidDoppiFee(_upkeepId);
        uint256 finalamount = linkAmount - fee;
        _fundUpkeep(_upkeepId, uint96(finalamount));
        if(fee > 0) IERC20(address(linkToken)).safeTransfer(treasury, fee);
        emit UpkeepFunded(_upkeepId, _amount, finalamount, fee);
    }
    
    function cancelUpkeep(uint256 _upkeepId) external onlyTrader(_upkeepId) validUpkeepId(_upkeepId) {
        
        registryConsumer.cancelUpkeep(_upkeepId);
        emit UpkeepCanceled(_upkeepId);
    }

    function getUpkeep(uint256 _upkeepId) external view returns (
        IAutomationRegistryConsumer.UpkeepInfo memory result) {
        result = registryConsumer.getUpkeep(_upkeepId);
    }
    
    function getUpkeepIdByBot(address _traderbot) external view returns (uint256) {
        return doppiUpkeeps[_traderbot].upkeepId;
    }
    
    function getTraderBotByTrader(address _trader) external view returns (address[] memory) {
        return traderToBot[_trader];
    }
    
    function getUpkeepBalance(uint256 _upkeepId) external view returns (uint256) {
        IAutomationRegistryConsumer.UpkeepInfo memory out = registryConsumer.getUpkeep(_upkeepId);
        (uint256 fee, ) = _getUnPaidDoppiFee(_upkeepId);
        return out.balance > fee ? out.balance - fee : 0;
    }

     function getPaymentStatus(uint256 _upkeepId) external view returns (DoppiUpkeepPayment memory payment) {
        return doppiUpkeepPayment[_upkeepId];
    }

    function getForwarder(uint256 _upkeepId) external view returns (address) {
        return registryConsumer.getForwarder(_upkeepId);
    }

    function getUnPaidDoppiFee(uint256 _upkeepId) external view returns (uint96 fee, address trader) {
        return _getUnPaidDoppiFee(_upkeepId);
    }

    function getDefault_Amount() external view returns (uint256) {
        return DEFAULT_AMOUNT;
    }
    
    // function withdrawLINK(uint96 _amount) external onlyOwner {
    //     require(linkToken.transfer(msg.sender, _amount), "LINK transfer failed");
    // }

    function insertNewBot(address trader, address bot) external {

        require(doppiTraderFactory.isTraderBot(msg.sender), "only traderbot can call");
        require(DEFAULT_AMOUNT > 0, "cannot register upkeep");

        DoppiUpkeepInfo storage info = doppiUpkeeps[bot];
        
        if(info.targetContract == address(0) && !info.isRegistered){
            traderToBot[trader].push(bot);
            uint256 upKeepId = _setupAutomation(bot, trader);
            info.targetContract = bot;
            info.trader = trader;
            info.upkeepId = upKeepId;
            info.isRegistered = true;
        }else{
            if(!info.isRegistered && info.targetContract == bot){
                uint256 upKeepId = _setupAutomation(bot, trader);
                info.upkeepId = upKeepId;
                info.isRegistered = true;
            }
        }
    }

    function shouldTopUpkeep(uint256 upkeepId) external view returns (TopUpInfo memory topUpInfo, bool needTopUp) {
 
        (topUpInfo, needTopUp) = _getTopUpInfo(upkeepId);
    }

    function _getTopUpInfo(uint256 upkeepId) internal view returns (TopUpInfo memory topUpInfo, bool needTopUp) {
 
        IAutomationRegistryConsumer.UpkeepInfo memory result = registryConsumer.getUpkeep(upkeepId);
        DoppiUpkeepPayment memory p = doppiUpkeepPayment[upkeepId];
        uint96 amountSpent = result.amountSpent;
        uint96 amountLastSpent = amountSpent - p.lastPaidAmount;
        if(p.lastBlockCharged < block.number && amountLastSpent >= MINSPENT){
            uint96 minBalance = registryConsumer.getMinBalance(upkeepId);
            uint256 topUpBorder = minBalance * 13000 / 10000; 
            needTopUp = result.balance < topUpBorder;
            if((needTopUp)){
                uint256 fee = amountLastSpent * doppiBotFee / 10000;
                uint256 price = DALiquidityLib.getPrice(chainLinkFeed, maxDelay);
                uint256 feeInfundToken = (fee * price) / priceDecimals;
                topUpInfo.fee = fee;
                topUpInfo.amountSpent = amountSpent;
                topUpInfo.feeInfundToken = feeInfundToken;
                topUpInfo.topUpAmountInfundToken = DEFAULT_AMOUNT;
                topUpInfo.totalInfundToken = DEFAULT_AMOUNT + feeInfundToken;
            }
        }
    }
    
    function performTopUpkeep(uint256 upkeepId) external validUpkeepId(upkeepId) {
        
        require(doppiTraderFactory.isTraderBot(msg.sender), "only traderbot can call");
        (TopUpInfo memory topUpInfo, bool needTopUp) = _getTopUpInfo(upkeepId); 
        
        require(needTopUp == true, "no need to top up"); 
        uint256 bal = fundToken.balanceOf(address(this));
        require(bal >= topUpInfo.totalInfundToken, "balance not enough");

        uint256 linkOut = _swapToLinkERC677(topUpInfo.topUpAmountInfundToken);
        _fundUpkeep(upkeepId, uint96(linkOut));
        fundToken.safeTransfer(treasury, topUpInfo.feeInfundToken);
        DoppiUpkeepPayment storage p = doppiUpkeepPayment[upkeepId];
        p.lastPaidAmount = topUpInfo.amountSpent;
        p.lastBlockCharged = block.number;
        emit TopUpPerformed(upkeepId, msg.sender, topUpInfo.topUpAmountInfundToken, linkOut, topUpInfo.fee);
    }

    function _setupAutomation(address _traderbot, address trader) internal returns (uint256 upKeepId) {
        
        DoppiUpkeepInfo storage info = doppiUpkeeps[_traderbot];
        require(!info.isRegistered, "already register");
        
        uint256 linkAmount = _swapToLinkERC677(DEFAULT_AMOUNT);
        upKeepId = _registerUpkeep(_traderbot, uint96(linkAmount));
        doppiUpKeepsId[upKeepId] = _traderbot;

        address forwarder = registryConsumer.getForwarder(upKeepId);
        if(forwarder != address(0)){
            IDoppiTrader(_traderbot).setForwarderAddress(forwarder);
        }
        
        doppiUpkeepPayment[upKeepId].lastBlockCharged = block.number;
        doppiUpkeepPayment[upKeepId].lastPaidAmount = 0;
        doppiUpkeepPayment[upKeepId].trader = trader;
        

        emit UpkeepRegistered(upKeepId, _traderbot, DEFAULT_AMOUNT, linkAmount);
        return upKeepId;
    }

    function _getUnPaidDoppiFee(uint256 _upkeepId) internal view returns (uint96 fee, address trader) {
        
        IAutomationRegistryConsumer.UpkeepInfo memory result = registryConsumer.getUpkeep(_upkeepId);
        DoppiUpkeepPayment memory p = doppiUpkeepPayment[_upkeepId];
        uint96 amountSpent = result.amountSpent;
        uint96 amountLastSpent = amountSpent - p.lastPaidAmount;
        fee = amountLastSpent * doppiBotFee / 10000;
        trader = p.trader;
    }

    function _fundUpkeep(uint256 _upkeepId, uint96 _amount) internal {
        
        linkToken.approve(address(registryConsumer), _amount);
        registryConsumer.addFunds(_upkeepId, _amount);
    }

    function _swapToLinkERC677(uint256 _amount) internal returns (uint256 linkOut) {
        // swap fundToken to link
        uint256 price = DALiquidityLib.getPrice(chainLinkFeed, maxDelay);
        require(price > 0, "invalid oracle price");
        uint256 amountOut = (_amount * priceDecimals) / price;
        // bridge link to erc677 link
        linkOut = _swapExactInputV3(_amount, address(this), amountOut, true);
        require(linkOut > 0, "swap to link returned zero");
        pegSwap.swap(linkOut, address(link), address(linkToken));
    }

    function _swapERC677ToFundToken(uint256 linkIn) internal returns (uint256 fundTokenOut) {
        // bridge erc677 link to link
        pegSwap.swap(linkIn, address(linkToken), address(link));

        uint256 price = DALiquidityLib.getPrice(chainLinkFeed, maxDelay);
        require(price > 0, "invalid oracle price");
        uint256 amountOut = (linkIn * price) / priceDecimals;
        fundTokenOut = _swapExactInputV3(linkIn, address(this), amountOut, false);
        require(fundTokenOut > 0, "swap to fund token failed");
    }

    function _registerUpkeep(
        address targetContract,
        uint96 _linkAmount 
    ) internal returns (uint256) {
        
        // Approve LINK tokens to registrar
        linkToken.approve(address(registrar), _linkAmount);
        IAutomationRegistrar.RegistrationParams memory params = IAutomationRegistrar.RegistrationParams({
            name: "Doppi TraderBot",
            encryptedEmail: hex"",
            upkeepContract: targetContract,
            gasLimit: DEFAULT_GASLIMIT,
            adminAddress: address(this),
            triggerType: TRIGGER_CONDITION,
            checkData: hex"",
            triggerConfig: hex"",
            offchainConfig: hex"",
            amount: _linkAmount
        });        
        // Register the upkeep
        uint256 upkeepId = registrar.registerUpkeep(params);
        return upkeepId;
    }

    function _swapExactInputV3(uint256 _amount, address _recipient, uint256 amountOutQuote, bool toLink)
        internal
        returns (uint256)
    {
        bytes memory path = toLink ? multihopPathFrom : multihopPathTo;
        require(path.length > 0, "invalid swap path");

        uint256 amountOutMinimum = amountOutQuote * (10000 - slippage) / 10000;
        require(amountOutMinimum > 0, "output min zero");

        ISwapRouter.ExactInputParams memory params = ISwapRouter
            .ExactInputParams({
                path: path,
                recipient: _recipient,
                amountIn: _amount,
                amountOutMinimum: amountOutMinimum
            });

        uint256 out = ISwapRouter(router).exactInput(params);
        require(out > 0, "swap output zero");
        return out;
    }
}
