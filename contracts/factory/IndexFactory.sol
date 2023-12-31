// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

import "../token/IndexToken.sol";
import "../proposable/ProposableOwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";
import "../chainlink/ChainlinkClient.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/// @title Index Token
/// @author NEX Labs Protocol
/// @notice The main token contract for Index Token (NEX Labs Protocol)
/// @dev This contract uses an upgradeable pattern
contract IndexFactory is
    ChainlinkClient,
    ContextUpgradeable,
    ProposableOwnableUpgradeable,
    PausableUpgradeable
{
    using Chainlink for Chainlink.Request;

    IndexToken public indexToken;

    uint256 public fee;
    uint8 public feeRate; // 10/10000 = 0.1%
    uint256 public latestFeeUpdate;
    
    uint256 internal constant SCALAR = 1e20;

    // Inflation rate (per day) on total supply, to be accrued to the feeReceiver.
    uint256 public feeRatePerDayScaled;

    // Most recent timestamp when fee was accured.
    uint256 public feeTimestamp;

    // Address that can claim fees accrued.
    address public feeReceiver;

    // Address that can publish a new methodology.
    address public methodologist;

    // Address that has privilege to mint and burn. It will be Controller and Admin to begin.
    address public minter;

    string public methodology;

    uint256 public supplyCeiling;

    mapping(address => bool) public isRestricted;

    enum DexStatus {
        UNISWAP_V2,
        UNISWAP_V3
    }

    
    
    string baseUrl;
    string urlParams;

    bytes32 public externalJobId;
    uint256 public oraclePayment;
    AggregatorV3Interface public toUsdPriceFeed;
    uint public lastUpdateTime;
    // address[] public oracleList;
    // address[] public currentList;

    uint public totalOracleList;
    uint public totalCurrentList;

    mapping(uint => address) public oracleList;
    mapping(uint => address) public currentList;

    mapping(address => uint) public tokenOracleListIndex;
    mapping(address => uint) public tokenCurrentListIndex;

    mapping(address => uint) public tokenCurrentMarketShare;
    mapping(address => uint) public tokenOracleMarketShare;
    mapping(address => uint) public tokenSwapVersion;

    
    ISwapRouter public swapRouterV3;
    IUniswapV3Factory public factoryV3;
    IUniswapV2Router02 public swapRouterV2;
    IUniswapV2Factory public factoryV2;
    IWETH public weth;
    IQuoter public quoter;

    event FeeReceiverSet(address indexed feeReceiver);
    event FeeRateSet(uint256 indexed feeRatePerDayScaled);
    event MethodologistSet(address indexed methodologist);
    event MethodologySet(string methodology);
    event MinterSet(address indexed minter);
    event SupplyCeilingSet(uint256 supplyCeiling);
    event MintFeeToReceiver(address feeReceiver, uint256 timestamp, uint256 totalSupply, uint256 amount);
    event ToggledRestricted(address indexed account, bool isRestricted);

    event Issuanced(address indexed user, address indexed inputToken, uint inputAmount, uint outputAmount, uint time);
    event Redemption(address indexed user, address indexed outputToken, uint inputAmount, uint outputAmount, uint time);

    modifier onlyMethodologist() {
        require(msg.sender == methodologist, "IndexToken: caller is not the methodologist");
        _;
    }

    modifier onlyMinter() {
        require(msg.sender == minter, "IndexToken: caller is not the minter");
        _;
    }

    
    function initialize(
        address payable _token,
        address _chainlinkToken, 
        address _oracleAddress, 
        bytes32 _externalJobId,
        address _toUsdPriceFeed,
        //addresses
        address _weth,
        address _quoter,
        address _swapRouterV3,
        address _factoryV3,
        address _swapRouterV2,
        address _factoryV2
    ) external initializer {

        __Ownable_init();
        __Pausable_init();
        indexToken = IndexToken(_token);
        //set oracle data
        setChainlinkToken(_chainlinkToken);
        setChainlinkOracle(_oracleAddress);
        externalJobId = _externalJobId;
        // externalJobId = "81027ac9198848d79a8d14235bf30e16";
        oraclePayment = ((1 * LINK_DIVISIBILITY) / 10); // n * 10**18
        toUsdPriceFeed = AggregatorV3Interface(_toUsdPriceFeed);
        //set addresses
        feeRate = 10;
        latestFeeUpdate = block.timestamp;

        baseUrl = "https://app.nexlabs.io/api/allFundingRates";
        urlParams = "?multiplyFunc=18&timesNegFund=true&arrays=true";
        // s_requestCount = 1;
    }

  /**
    * @dev Sets the price feed address of the native coin to USD from the Chainlink oracle.
    * @param _toUsdPricefeed The address of native coin to USD price feed.
    */    
    function setPriceFeed(address _toUsdPricefeed) external onlyOwner {
        require(_toUsdPricefeed != address(0), "ICO: Price feed address cannot be zero address");
        toUsdPriceFeed = AggregatorV3Interface(_toUsdPricefeed);        
    }

    
    function _toWei(int256 _amount, uint8 _amountDecimals, uint8 _chainDecimals) private pure returns (int256) {        
        if (_chainDecimals > _amountDecimals)
            return _amount * int256(10 **(_chainDecimals - _amountDecimals));
        else
            return _amount * int256(10 **(_amountDecimals - _chainDecimals));
    }

    function priceInWei() public view returns (uint256) {
        (,int price,,,) = toUsdPriceFeed.latestRoundData();
        uint8 priceFeedDecimals = toUsdPriceFeed.decimals();
        price = _toWei(price, priceFeedDecimals, 18);
        return uint256(price);
    }
    


    //Notice: newFee should be between 1 to 100 (0.01% - 1%)
  function setFeeRate(uint8 _newFee) public onlyOwner {
    uint256 distance = block.timestamp - latestFeeUpdate;
    require(distance / 60 / 60 > 12, "You should wait at least 12 hours after the latest update");
    require(_newFee <= 100 && _newFee >= 1, "The newFee should be between 1 and 100 (0.01% - 1%)");
    feeRate = _newFee;
    latestFeeUpdate = block.timestamp;
  }

   /**
    * @dev The contract's fallback function that does not allow direct payments to the contract.
    * @notice Prevents users from sending ether directly to the contract by reverting the transaction.
    */
    receive() external payable {
        // revert DoNotSendFundsDirectlyToTheContract();
    }

    function concatenation(string memory a, string memory b) public pure returns (string memory) {
        return string(bytes.concat(bytes(a), bytes(b)));
    }

    function setUrl(string memory _beforeAddress, string memory _afterAddress) public onlyOwner{
    baseUrl = _beforeAddress;
    urlParams = _afterAddress;
    }
    
    function requestAssetsData(
    )
        public
        returns(bytes32)
    {
        
        string memory url = concatenation(baseUrl, urlParams);
        Chainlink.Request memory req = buildChainlinkRequest(externalJobId, address(this), this.fulfillAssetsData.selector);
        req.add("get", url);
        req.add("path1", "results,tokens");
        req.add("path2", "results,marketShares");
        req.add("path3", "results,swapVersions");
        // sendOperatorRequest(req, oraclePayment);
        return sendChainlinkRequestTo(chainlinkOracleAddress(), req, oraclePayment);
    }

  function fulfillAssetsData(bytes32 requestId, address[] memory _tokens, uint256[] memory _marketShares, uint256[] memory _swapVersions)
    public
    recordChainlinkFulfillment(requestId)
  {
    
    address[] memory tokens0 = _tokens;
    uint[] memory marketShares0 = _marketShares;
    uint[] memory swapVersions0 = _swapVersions;

    // //save mappings
    for(uint i =0; i < tokens0.length; i++){
        oracleList[i] = tokens0[i];
        tokenOracleListIndex[tokens0[i]] = i;
        tokenOracleMarketShare[tokens0[i]] = marketShares0[i];
        tokenSwapVersion[tokens0[i]] = swapVersions0[i];
        if(totalCurrentList == 0){
            currentList[i] = tokens0[i];
            tokenCurrentMarketShare[tokens0[i]] = marketShares0[i];
            tokenCurrentListIndex[tokens0[i]] = i;
        }
    }
    totalOracleList = tokens0.length;
    if(totalCurrentList == 0){
        totalCurrentList  = tokens0.length;
    }
    lastUpdateTime = block.timestamp;
    }


    function mockFillAssetsList(address[] memory _tokens, uint256[] memory _marketShares, uint256[] memory _swapVersions)
    public
    onlyOwner
  {
    
    address[] memory tokens0 = _tokens;
    uint[] memory marketShares0 = _marketShares;
    uint[] memory swapVersions0 = _swapVersions;

    // //save mappings
    for(uint i =0; i < tokens0.length; i++){
        oracleList[i] = tokens0[i];
        tokenOracleListIndex[tokens0[i]] = i;
        tokenOracleMarketShare[tokens0[i]] = marketShares0[i];
        tokenSwapVersion[tokens0[i]] = swapVersions0[i];
        if(totalCurrentList == 0){
            currentList[i] = tokens0[i];
            tokenCurrentMarketShare[tokens0[i]] = marketShares0[i];
            tokenCurrentListIndex[tokens0[i]] = i;
        }
    }
    totalOracleList = tokens0.length;
    if(totalCurrentList == 0){
        totalCurrentList  = tokens0.length;
    }
    lastUpdateTime = block.timestamp;
    }


    
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }


    // function send(
    //     uint64 destinationChainSelector,
    //     address receiver,
    //     Client.EVMTokenAmount[] memory tokensToSendDetails,
    //     PayFeesIn payFeesIn
    // ) external {
    //     uint256 length = tokensToSendDetails.length;
    //     require(
    //         length <= i_maxTokensLength,
    //         "Maximum 5 different tokens can be sent per CCIP Message"
    //     );

    //     for (uint256 i = 0; i < length; ) {
    //         IERC20(tokensToSendDetails[i].token).transferFrom(
    //             msg.sender,
    //             address(this),
    //             tokensToSendDetails[i].amount
    //         );
    //         IERC20(tokensToSendDetails[i].token).approve(
    //             i_router,
    //             tokensToSendDetails[i].amount
    //         );

    //         unchecked {
    //             ++i;
    //         }
    //     }

    //     Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
    //         receiver: abi.encode(receiver),
    //         data: "",
    //         tokenAmounts: tokensToSendDetails,
    //         extraArgs: "",
    //         feeToken: payFeesIn == PayFeesIn.LINK ? i_link : address(0)
    //     });

    //     uint256 fee = IRouterClient(i_router).getFee(
    //         destinationChainSelector,
    //         message
    //     );

    //     bytes32 messageId;

    //     if (payFeesIn == PayFeesIn.LINK) {
    //         // LinkTokenInterface(i_link).approve(i_router, fee);
    //         messageId = IRouterClient(i_router).ccipSend(
    //             destinationChainSelector,
    //             message
    //         );
    //     } else {
    //         messageId = IRouterClient(i_router).ccipSend{value: fee}(
    //             destinationChainSelector,
    //             message
    //         );
    //     }

    //     emit MessageSent(messageId);
    // }



    // /// handle a received message
    // function _ccipReceive(
    //     Client.Any2EVMMessage memory any2EvmMessage
    // ) internal override {
    //     bytes32 messageId = any2EvmMessage.messageId; // fetch the messageId
    //     uint64 sourceChainSelector = any2EvmMessage.sourceChainSelector; // fetch the source chain identifier (aka selector)
    //     address sender = abi.decode(any2EvmMessage.sender, (address)); // abi-decoding of the sender address
    //     Client.EVMTokenAmount[] memory tokenAmounts = any2EvmMessage
    //         .destTokenAmounts;
    //     address token = tokenAmounts[0].token; // we expect one token to be transfered at once but of course, you can transfer several tokens.
    //     uint256 amount = tokenAmounts[0].amount; // we expect one token to be transfered at once but of course, you can transfer several tokens.
    //     string memory message = abi.decode(any2EvmMessage.data, (string)); // abi-decoding of the sent string message
    //     receivedMessages.push(messageId);
    //     Message memory detail = Message(
    //         sourceChainSelector,
    //         sender,
    //         message,
    //         token,
    //         amount
    //     );
    //     messageDetail[messageId] = detail;

    //     emit MessageReceived(
    //         messageId,
    //         sourceChainSelector,
    //         sender,
    //         message,
    //         tokenAmounts[0]
    //     );
    // }

    
}