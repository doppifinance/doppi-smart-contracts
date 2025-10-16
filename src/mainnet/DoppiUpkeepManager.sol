// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapRouter} from "../Interface/ISwapRouter.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "../Interface/IAutomationRegistrar.sol";
import "../Interface/IAutomationRegistryConsumer.sol";
import "../Interface/LinkTokenInterface.sol";
import "../Interface/IPegSwap.sol";
import "../Interface/IDoppiTrader.sol";
import "../Interface/IDoppiTraderFactory.sol";
import {DALiquidityLib} from "../Library/DALiquidityLib.sol";
import {AggregatorV3Interface} from "../Interface/AggregatorV3Interface.sol";
import {AutomationCompatibleInterface} from "../Interface/AutomationCompatibleInterface.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "forge-std/console.sol";

contract DoppiUpkeepManager is Ownable, AutomationCompatibleInterface {
    using SafeERC20 for IERC20;
    
    struct DoppiUpkeepInfo {
        uint256 upkeepId;
        address targetContract;
        bool isRegistered;
        address trader;
    }
    
    struct DoppiUpkeepPayment {
        address trader;
        uint256 lastBlockCharged;
        uint96 lastPaidAmount;
    }

    struct CheckUpKeepStorage {

        uint256 upkeepId;
        uint256 tobepaid;
        bool topUp;
        uint256 fee;
        uint96 amountSpent;
        uint256 feeInfundToken;
    }

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
    address[] public upkeepIds;
    
    AggregatorV3Interface immutable chainLinkFeed;
    address public immutable router;
    IPegSwap public immutable pegSwap;
    uint8 public constant TRIGGER_CONDITION = 0; // Time-based trigger

    address public adminAddress;
    uint256 public currentUpkeepIndex;
    uint256 public UPKEEPS_PER_CHECK = 20; // Process 20 upkeeps per check
    uint32 public DEFAULT_GASLIMIT = 5_000_000;
    uint96 public DEFAULT_AMOUNT = 300 ether;
    uint24 public slippage = 200; //0.2%
    uint24 public doppiBotFee = 2000; // 20% of chainlink fee
    uint256 public MINSPENT = 0.1 ether; // in link token
    uint256 public priceDecimals; 
    bytes public multihopPath;
    address public treasury;
    address public s_forwarderAddress;
        
    // Events
    event UpkeepRegistered(uint256 indexed upkeepId, address targetContract, uint256 fundTokenAmount, uint256 linkAmount);
    
    event UpkeepFunded(uint256 indexed upkeepId, uint256 fundTokenAmount, uint256 linkAmount, uint256 fee);
    
    event UpkeepCanceled(
        uint256 indexed upkeepId
    );
    
    event UpkeepPerformed(
        uint256 indexed upkeepId
    );
    
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
        adminAddress = msg.sender;
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
        
        multihopPath = abi.encodePacked(
            fundToken, // USDT
            uint24(100),                                       // fee
            address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c), // WBNB
            uint24(2500),                                       // fee
            address(link) // LINK
        );

        IERC20(fundToken).approve(router, type(uint256).max);
        IERC20(link).approve(address(pegSwap), type(uint256).max);
    }
    
    function setForwarderAddress(address forwarderAddress) external onlyOwner {
        s_forwarderAddress = forwarderAddress;
    }

    function setUpkeeps_per_check(uint24 _percheck) external onlyOwner {
        UPKEEPS_PER_CHECK = _percheck;
    }

    function setRegistryConsumer(address _registryConsumer) external onlyOwner {
        registryConsumer = IAutomationRegistryConsumer(_registryConsumer); //IAutomationRegistryConsumer(address(0xDc21E279934fF6721CaDfDD112DAfb3261f09A2C));
    }

    function setMinSpent(uint24 _min) external onlyOwner {
        MINSPENT = _min;
    }

    function setDoppiBotFee(uint24 _doppiBotFee) external onlyOwner {
        doppiBotFee = _doppiBotFee;
    }

    function setTresury(address _treasury) external onlyOwner {
        treasury = _treasury;
    }

    function setSwapPath(bytes calldata _multihopPath) external onlyOwner {
        multihopPath = _multihopPath;
    }

    function setupAutomation(address _traderbot) external returns (uint256 upKeepId) {
        
        require(doppiUpkeeps[_traderbot].upkeepId == 0, "already exists");
        require(fundToken.transferFrom(msg.sender, address(this), DEFAULT_AMOUNT), "fundToken transfer failed");
        uint256 linkAmount = _swapToLinkERC677(DEFAULT_AMOUNT);
        // call registerUpkeep
        upKeepId = _registerUpkeep(_traderbot, uint96(linkAmount));
        
        doppiUpkeepPayment[upKeepId].lastBlockCharged = block.number;
        doppiUpkeepPayment[upKeepId].lastPaidAmount = 0;
        doppiUpkeepPayment[upKeepId].trader = msg.sender;

        traderToBot[msg.sender].push(_traderbot);
        
        emit UpkeepRegistered(upKeepId, _traderbot, DEFAULT_AMOUNT, linkAmount);
    
        return upKeepId;
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
        if(refund > 0) linkToken.transfer(trader, refund);
        if(finalBal >= fee) linkToken.transfer(treasury, fee);
    }
    
    // trader top up using USDT manually
    function fundUpkeep(uint256 _upkeepId, uint96 _amount) external onlyTrader(_upkeepId) validUpkeepId(_upkeepId) {
        
        require(fundToken.transferFrom(msg.sender, address(this), _amount), "fundToken transfer failed");
        uint256 linkAmount = _swapToLinkERC677(_amount);
        (uint256 fee, ) = _getUnPaidDoppiFee(_upkeepId);
        uint256 finalamount = linkAmount - fee;
        _fundUpkeep(_upkeepId, uint96(finalamount));
        linkToken.transfer(treasury, fee);
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
    
    function getAllUpkeeps() external view returns (DoppiUpkeepInfo[] memory) {
        uint256 length = upkeepIds.length;
        DoppiUpkeepInfo[] memory allUpkeeps = new DoppiUpkeepInfo[](length);
        for (uint256 i = 0; i < length;) {
            allUpkeeps[i] = doppiUpkeeps[upkeepIds[i]];
            unchecked { ++i; }
        }
        return allUpkeeps;
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

    
    function withdrawLINK(uint96 _amount) external onlyOwner {
        require(linkToken.transfer(msg.sender, _amount), "LINK transfer failed");
    }

    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory performData) {
        
        DoppiUpkeepInfo[] memory all = this.getAllUpkeeps();
        uint256 totalUpkeeps = all.length;
        if (totalUpkeeps == 0) {
            return (false, bytes(""));
        }

        // Calculate the range of upkeeps to check in this iteration
        uint256 startIndex = currentUpkeepIndex;
        uint256 endIndex = startIndex + UPKEEPS_PER_CHECK;
        if (endIndex > totalUpkeeps) {
            endIndex = totalUpkeeps;
        }

        IAutomationRegistryConsumer.UpkeepInfo memory result;
        CheckUpKeepStorage[] memory checkUpKeeps = new CheckUpKeepStorage[](totalUpkeeps);
        uint256 count = 0;

        for (uint256 i = startIndex; i < endIndex;) {
            uint256 upkeepId = all[i].upkeepId;
            
            result = this.getUpkeep(upkeepId);
            DoppiUpkeepPayment memory p = doppiUpkeepPayment[upkeepId];
            uint96 amountSpent = result.amountSpent;
            uint96 amountLastSpent = amountSpent - p.lastPaidAmount;
            if(p.lastBlockCharged < block.number && amountLastSpent >= MINSPENT){
                uint256 allowance = fundToken.allowance(p.trader, address(this));
                uint96 minBalance = registryConsumer.getMinBalance(upkeepId);
                uint256 topUpBorder = minBalance * 13000 / 10000; 
                uint256 fee = amountLastSpent * doppiBotFee / 10000;
                uint256 price = DALiquidityLib.getPrice(chainLinkFeed);
                uint256 feeInfundToken = (fee * price) / priceDecimals;
                bool needTopUp = result.balance < topUpBorder;
                if((needTopUp && allowance >= DEFAULT_AMOUNT) || (!needTopUp && allowance >= feeInfundToken)){
                    checkUpKeeps[count].topUp = result.balance < topUpBorder;
                    checkUpKeeps[count].tobepaid = amountLastSpent;
                    checkUpKeeps[count].upkeepId = upkeepId;
                    checkUpKeeps[count].fee = fee;
                    checkUpKeeps[count].amountSpent = amountSpent;
                    checkUpKeeps[count].feeInfundToken = feeInfundToken;
                    count++;
                }
            }
            unchecked { ++i; }
        }
         // Update the index for the next check (wrap around if needed)
        uint256 nextIndex = endIndex;
        if (nextIndex >= totalUpkeeps) {
            nextIndex = 0;
        }

        if (count > 0) {
            CheckUpKeepStorage[] memory checkUpKeepsTrimmed = new CheckUpKeepStorage[](count);
            for (uint256 i = 0; i < count;) {
                checkUpKeepsTrimmed[i] = checkUpKeeps[i];
                unchecked { ++i; }
            }
            // Include the next index in the performData for state update
            return (true, abi.encode(checkUpKeepsTrimmed, nextIndex));
        }
        return (false, bytes(""));
    }

    function performUpkeep(bytes calldata performData) external onlyForwarder override {
        
        (CheckUpKeepStorage[] memory checkUpKeeps, uint256 nextIndex) = abi.decode(performData, (CheckUpKeepStorage[], uint256));

        // Update the current index for the next check
        currentUpkeepIndex = nextIndex;

        uint256 length = checkUpKeeps.length;
        for (uint256 i = 0; i < length; ) {
            uint256 upkeepId = checkUpKeeps[i].upkeepId;
            DoppiUpkeepPayment storage p = doppiUpkeepPayment[upkeepId];
            p.lastPaidAmount = checkUpKeeps[i].amountSpent;
            p.lastBlockCharged = block.number;

            if(checkUpKeeps[i].topUp){
                fundToken.transferFrom(p.trader, address(this), DEFAULT_AMOUNT);
                uint256 linkOut = _swapToLinkERC677(DEFAULT_AMOUNT);
                _fundUpkeep(upkeepId, uint96(linkOut - checkUpKeeps[i].fee));
                linkToken.transfer(treasury, checkUpKeeps[i].fee);
            }else{
                // convert link to fundToken
                fundToken.transferFrom(p.trader, treasury, checkUpKeeps[i].feeInfundToken);
            }
            emit UpkeepPerformed(upkeepId);

            unchecked { ++i; }
        }
    }

    // internal functions
    function _getUnPaidDoppiFee(uint256 _upkeepId) internal view returns (uint96 fee, address trader) {
        
        IAutomationRegistryConsumer.UpkeepInfo memory result = this.getUpkeep(_upkeepId);
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
        uint256 price = DALiquidityLib.getPrice(chainLinkFeed);
        uint256 amountOut = (_amount * priceDecimals) / price;
        // bridge link to erc677 link
        linkOut = _swapExactInputV3(_amount, address(this), amountOut);
        pegSwap.swap(linkOut, address(link), address(linkToken));
    }

    function _registerUpkeep(
        address _targetContract,
        uint96 _linkAmount 
    ) internal returns (uint256) {
        
        // Approve LINK tokens to registrar
        linkToken.approve(address(registrar), _linkAmount);
        IAutomationRegistrar.RegistrationParams memory params = IAutomationRegistrar.RegistrationParams({
            name: "Doppi TraderBot",
            encryptedEmail: hex"",
            upkeepContract: _targetContract,
            gasLimit: DEFAULT_GASLIMIT,
            adminAddress: adminAddress,
            triggerType: TRIGGER_CONDITION,
            checkData: hex"",
            triggerConfig: hex"",
            offchainConfig: hex"",
            amount: _linkAmount
        });        
        // Register the upkeep
        uint256 upkeepId = registrar.registerUpkeep(params);
        // Store upkeep information
        doppiUpkeeps[_targetContract] = DoppiUpkeepInfo({
            upkeepId: upkeepId,
            targetContract: _targetContract,
            isRegistered: true,
            trader: msg.sender
        });
        
        doppiUpKeepsId[upkeepId] = _targetContract;
        upkeepIds.push(_targetContract);
        return upkeepId;
    }

    function _swapExactInputV3(uint256 _amount, address _recipient, uint256 amountOutQuote)
        internal
        returns (uint256)
    {
        ISwapRouter.ExactInputParams memory params = ISwapRouter
            .ExactInputParams({
                path: multihopPath,
                recipient: _recipient,
                amountIn: _amount,
                amountOutMinimum: amountOutQuote * (10000 - slippage) / 10000
            });
        return ISwapRouter(router).exactInput(params);
    }
    
    receive() external payable {}
}
