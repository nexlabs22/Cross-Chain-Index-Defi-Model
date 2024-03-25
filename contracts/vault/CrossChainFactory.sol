// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

// import "../token/IndexToken.sol";
import "../proposable/ProposableOwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";
import "../chainlink/ChainlinkClient.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "../libraries/OracleLibrary.sol";
import "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

// import "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import "../ccip/CCIPReceiver.sol";
import "./CrossChainVault.sol";
// import {Withdraw} from "./utils/Withdraw.sol";

/// @title Index Token
/// @author NEX Labs Protocol
/// @notice The main token contract for Index Token (NEX Labs Protocol)
/// @dev This contract uses an upgradeable pattern
contract CrossChainIndexFactory is
    CCIPReceiver,
    ChainlinkClient,
    ContextUpgradeable,
    ProposableOwnableUpgradeable,
    PausableUpgradeable
{
    enum PayFeesIn {
        Native,
        LINK
    }
    using Chainlink for Chainlink.Request;

    struct Message {
        uint64 sourceChainSelector; // The chain selector of the source chain.
        address sender; // The address of the sender.
        string message; // The content of the message.
        address token; // received token.
        uint256 amount; // received amount.
    }

    struct ReweightActionData {
        uint chainSelectorCurrentTokensCount;
        uint portfolioValue;
        uint chainSelectorTotalShares;
        uint swapWethAmount;
        uint chainValue;
    }

    

    // address public i_router;
    address public i_link;
    uint16 public i_maxTokensLength;
    bytes32[] public receivedMessages; // Array to keep track of the IDs of received messages.
    mapping(bytes32 => Message) public messageDetail; // Mapping from message ID to Message struct, storing details of each received message.

    // IndexToken public indexToken;
    CrossChainVault public crossChainVault;

    uint256 public fee;
    uint8 public feeRate; // 10/10000 = 0.1%
    uint256 public latestFeeUpdate;
    uint64 public currentChainSelector;
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

    uint256 public oraclePayment;
    AggregatorV3Interface public toUsdPriceFeed;

    ISwapRouter public swapRouterV3;
    IUniswapV3Factory public factoryV3;
    IUniswapV2Router02 public swapRouterV2;
    IUniswapV2Factory public factoryV2;
    IWETH public weth;
    IQuoter public quoter;

    // address public crossChainToken;
    mapping(uint64 => address) public crossChainToken;
    mapping(uint64 => mapping(address => uint)) public crossChainTokenSwapVersion;

    //nonce
    struct TokenOldAndNewValues {
        uint oldTokenValue;
        uint newTokenValue;
    }
    uint issuanceNonce;
    // mapping(uint => mapping(address => TokenOldAndNewValues)) public issuanceTokenOldAndNewValues;
    // mapping(uint => uint) public issuanceCompletedTokensCount;

    event Issuanced(
        address indexed user,
        address indexed inputToken,
        uint inputAmount,
        uint outputAmount,
        uint time
    );
    event Redemption(
        address indexed user,
        address indexed outputToken,
        uint inputAmount,
        uint outputAmount,
        uint time
    );
    event MessageSent(bytes32 messageId);

    function initialize(
        uint64 _currentChainSelector,
        address payable _crossChainVault,
        address _chainlinkToken,
        //ccip
        address _router,
        //addresses
        address _weth,
        // address _quoter,
        address _swapRouterV3,
        address _factoryV3,
        address _swapRouterV2,
        address _factoryV2,
        address _toUsdPriceFeed
    ) external initializer {
        CCIPReceiver(_router);
        __Ownable_init();
        __Pausable_init();
        //set chain selector
        currentChainSelector = _currentChainSelector;
        crossChainVault = CrossChainVault(_crossChainVault);
        //set oracle data
        setChainlinkToken(_chainlinkToken);

        //set ccip addresses
        i_router = _router;
        i_link = _chainlinkToken;
        i_maxTokensLength = 5;
        LinkTokenInterface(_chainlinkToken).approve(
            i_router,
            type(uint256).max
        );

        //set addresses
        weth = IWETH(_weth);
        // quoter = IQuoter(_quoter);
        swapRouterV3 = ISwapRouter(_swapRouterV3);
        factoryV3 = IUniswapV3Factory(_factoryV3);
        swapRouterV2 = IUniswapV2Router02(_swapRouterV2);
        factoryV2 = IUniswapV2Factory(_factoryV2);
        //oracle
        toUsdPriceFeed = AggregatorV3Interface(_toUsdPriceFeed);
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

    function convertEthToUsd(uint _ethAmount) public view returns (uint256) {
        return _ethAmount * priceInWei() / 1e18;
    }

    function setCcipRouter(address _router) public onlyOwner {
        i_router = _router;
    }

    function setCrossChainToken(
        uint64 _chainSelector,
        address _crossChainToken,
        uint _swapVersion
    ) public onlyOwner {
        crossChainToken[_chainSelector] = _crossChainToken;
        crossChainTokenSwapVersion[_chainSelector][_crossChainToken] = _swapVersion;
    }

    function setCrossChainVault(
        address payable _crossChainVault
    ) public onlyOwner {
        crossChainVault = CrossChainVault(_crossChainVault);
    }

    /**
     * @dev The contract's fallback function that does not allow direct payments to the contract.
     * @notice Prevents users from sending ether directly to the contract by reverting the transaction.
     */
    receive() external payable {
        // revert DoNotSendFundsDirectlyToTheContract();
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _swapSingle(
        address tokenIn,
        address tokenOut,
        uint amountIn,
        address _recipient,
        uint _swapVersion
    ) internal returns (uint) {
        // uint amountOut = getAmountOut(
        //     tokenIn,
        //     tokenOut,
        //     amountIn,
        //     _swapVersion
        // );
        // uint amountOut;
        // uint swapAmountOut;
        // if (amountOut > 0) {
            // swapAmountOut = crossChainVault.swapSingle(
            //     tokenIn,
            //     tokenOut,
            //     amountIn,
            //     _recipient,
            //     _swapVersion
            // );
        // }
        if (_swapVersion == 3) {
            uint swapAmountOut = crossChainVault.swapSingle(
                tokenIn,
                tokenOut,
                amountIn,
                _recipient,
                _swapVersion
            );
            return swapAmountOut;
        } else {
            uint amountOut = getAmountOut(
                tokenIn,
                tokenOut,
                amountIn,
                _swapVersion
            );
            crossChainVault.swapSingle(
                tokenIn,
                tokenOut,
                amountIn,
                _recipient,
                _swapVersion
            );
            return amountOut;
        }
    }

    function swap(
        address tokenIn,
        address tokenOut,
        uint amountIn,
        address _recipient,
        uint _swapVersion
    ) public returns (uint) {
        if (_swapVersion == 3) {
            IERC20(tokenIn).approve(address(swapRouterV3), amountIn);
            ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
                .ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    // pool fee 0.3%
                    fee: 3000,
                    recipient: _recipient,
                    deadline: block.timestamp,
                    amountIn: amountIn,
                    amountOutMinimum: 0,
                    // NOTE: In production, this value can be used to set the limit
                    // for the price the swap will push the pool to,
                    // which can help protect against price impact
                    sqrtPriceLimitX96: 0
                });
            uint finalAmountOut = swapRouterV3.exactInputSingle(params);
            return finalAmountOut;
        } else {
            address[] memory path = new address[](2);
            path[0] = tokenIn;
            path[1] = tokenOut;

            IERC20(tokenIn).approve(address(swapRouterV2), amountIn);
            swapRouterV2.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                amountIn, //amountIn
                0, //amountOutMin
                path, //path
                _recipient, //to
                block.timestamp //deadline
            );
            return 0;
        }
    }

    function getAmountOut(
        address tokenIn,
        address tokenOut,
        uint amountIn,
        uint _swapVersion
    ) public view returns (uint finalAmountOut) {
        uint finalAmountOut;
        if (amountIn > 0) {
            if (_swapVersion == 3) {
                finalAmountOut = estimateAmountOut(
                    tokenIn,
                    tokenOut,
                    uint128(amountIn),
                    1
                );
            } else {
                address[] memory path = new address[](2);
                path[0] = tokenIn;
                path[1] = tokenOut;
                uint[] memory v2amountOut = swapRouterV2.getAmountsOut(
                    amountIn,
                    path
                );
                finalAmountOut = v2amountOut[1];
            }
        }
        return finalAmountOut;
    }

    function estimateAmountOut(
        address tokenIn,
        address tokenOut,
        uint128 amountIn,
        uint32 secondsAgo
    ) public view returns (uint amountOut) {
        address _pool = factoryV3.getPool(tokenIn, tokenOut, 3000);

        (int24 tick, ) = OracleLibrary.consult(_pool, secondsAgo);
        amountOut = OracleLibrary.getQuoteAtTick(
            tick,
            amountIn,
            tokenIn,
            tokenOut
        );
    }

    function sendToken(
        uint64 destinationChainSelector,
        bytes memory _data,
        address receiver,
        Client.EVMTokenAmount[] memory tokensToSendDetails,
        PayFeesIn payFeesIn
    ) internal {
        uint256 length = tokensToSendDetails.length;
        require(
            length <= i_maxTokensLength,
            "Maximum 5 different tokens can be sent per CCIP Message"
        );

        for (uint256 i = 0; i < length; ) {
            if (tokensToSendDetails[i].token != i_link) {
                IERC20(tokensToSendDetails[i].token).approve(
                    i_router,
                    tokensToSendDetails[i].amount
                );
            }
            unchecked {
                ++i;
            }
        }

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(receiver),
            data: _data,
            tokenAmounts: tokensToSendDetails,
            // extraArgs: "",
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({gasLimit: 900_000, strict: false}) // Additional arguments, setting gas limit and non-strict sequency mode
            ),
            feeToken: payFeesIn == PayFeesIn.LINK ? i_link : address(0)
        });

        uint256 fee = IRouterClient(i_router).getFee(
            destinationChainSelector,
            message
        );

        bytes32 messageId;

        if (payFeesIn == PayFeesIn.LINK) {
            // LinkTokenInterface(i_link).approve(i_router, fee);
            messageId = IRouterClient(i_router).ccipSend(
                destinationChainSelector,
                message
            );
        } else {
            messageId = IRouterClient(i_router).ccipSend{value: fee}(
                destinationChainSelector,
                message
            );
        }

        emit MessageSent(messageId);
    }

    // address public targetAddressF;
    uint64 public sourceChainSelectorF;
    // /// handle a received message
    function _ccipReceive(
        Client.Any2EVMMessage memory any2EvmMessage
    ) internal override {
        // bytes32 messageId = any2EvmMessage.messageId; // fetch the messageId
        uint64 sourceChainSelector = any2EvmMessage.sourceChainSelector; // fetch the source chain identifier (aka selector)
        address sender = abi.decode(any2EvmMessage.sender, (address)); // abi-decoding of the sender address

        (
            uint actionType,
            address[] memory targetAddresses,
            address[] memory targetAddresses2,
            uint[] memory targetVersions,
            uint[] memory targetVersions2,
            uint nonce,
            uint[] memory percentages,
            uint[] memory extraValues
        ) = abi.decode(
                any2EvmMessage.data,
                (uint, address[], address[], uint[], uint[], uint, uint[], uint[])
            ); // abi-decoding of the sent string message
        if (actionType == 0) {
            Client.EVMTokenAmount[] memory tokenAmounts = any2EvmMessage
            .destTokenAmounts;
            _handleIssuance(
                tokenAmounts,
                targetAddresses,
                targetVersions,
                nonce,
                sourceChainSelector,
                sender,
                percentages,
                extraValues
            );
            
        } else if (actionType == 1) {
            _handleRedemption(
                targetAddresses,
                targetVersions,
                nonce,
                sourceChainSelector,
                sender,
                extraValues
            );
            
        } else if (actionType == 2) {
            _handleAskValues(
                targetAddresses,
                targetVersions,
                nonce,
                sourceChainSelector,
                sender
            );
            
        } else if (actionType == 3) {
            //first reweight action
            _handleFirstReweightAction(
                HandleFirstReweightActionInputs(
                    targetAddresses,
                    targetAddresses2,
                    targetVersions,
                    targetVersions2,
                    percentages,
                    sourceChainSelector,
                    sender,
                    nonce,
                    extraValues
                )
            );
            
        } else if (actionType == 4) {
            Client.EVMTokenAmount[] memory tokenAmounts = any2EvmMessage
                .destTokenAmounts;
            
            _handleSecondReweightAction(
                HandleSecondReweightActionInputs(
                    targetAddresses,
                    targetAddresses2,
                    targetVersions,
                    targetVersions2,
                    percentages,
                    tokenAmounts[0].token,
                    tokenAmounts[0].amount,
                    sourceChainSelector,
                    sender,
                    nonce,
                    extraValues
                )
            );
            }
    }

    struct HandleIssuanceLocalVars {
        uint wethAmount;
        uint[] oldTokenValues;
        uint[] newTokenValues;
        bytes data;
    }

    function _handleIssuance(
        Client.EVMTokenAmount[] memory tokenAmounts,
        address[] memory targetAddresses,
        uint[] memory targetVersions,
        uint nonce,
        uint64 sourceChainSelector,
        address sender,
        uint[] memory percentages,
        uint[] memory extraValues
    ) private {
        // Client.EVMTokenAmount[] memory tokenAmounts = any2EvmMessage
        //     .destTokenAmounts;
        HandleIssuanceLocalVars memory vars;

        vars.wethAmount = swap(
            tokenAmounts[0].token,
            address(weth),
            tokenAmounts[0].amount,
            address(crossChainVault),
            crossChainTokenSwapVersion[sourceChainSelector][tokenAmounts[0].token]
        );
        vars.oldTokenValues = new uint[](targetAddresses.length);
        vars.newTokenValues = new uint[](targetAddresses.length);
        for (uint i = 0; i < targetAddresses.length; i++) {
            uint wethToSwap = (vars.wethAmount * percentages[i]) /
                extraValues[0];
            
            uint oldTokenValue;
            if(targetAddresses[i] == address(weth)){
                oldTokenValue = IERC20(targetAddresses[i]).balanceOf(
                    address(crossChainVault)
                );
                weth.transfer(address(crossChainVault), wethToSwap);
            }else{
            oldTokenValue = getAmountOut(
                targetAddresses[i],
                address(weth),
                IERC20(targetAddresses[i]).balanceOf(
                    address(crossChainVault)
                ),
                3
            );
            _swapSingle(
                address(weth),
                address(targetAddresses[i]),
                wethToSwap,
                address(crossChainVault),
                targetVersions[i]
            );
            }
            uint newTokenValue = oldTokenValue + vars.wethAmount;
            vars.oldTokenValues[i] = convertEthToUsd(oldTokenValue);
            vars.newTokenValues[i] = convertEthToUsd(newTokenValue);
        }
        
        vars.data = abi.encode(
            0,
            targetAddresses,
            new address[](0),
            nonce,
            vars.oldTokenValues,
            vars.newTokenValues
        );
        sendMessage(
            sourceChainSelector,
            address(sender),
            vars.data,
            PayFeesIn.LINK
        );
    }
    
    function _handleRedemption(
        address[] memory targetAddresses,
        uint[] memory targetVersions,
        uint nonce,
        uint64 sourceChainSelector,
        address sender,
        uint[] memory extraValues
    ) private {
            uint wethSwapAmountOut;
            for (uint i = 0; i < targetAddresses.length; i++) {
                uint swapAmount = (extraValues[0] *
                    IERC20(address(targetAddresses[i])).balanceOf(
                        address(crossChainVault)
                    )) / 1e18;
                if(address(targetAddresses[i]) == address(weth)){
                    crossChainVault.wethTransfer(address(this), swapAmount);
                    wethSwapAmountOut += swapAmount;
                }else{
                wethSwapAmountOut += _swapSingle(
                    address(targetAddresses[i]),
                    address(weth),
                    swapAmount,
                    address(this),
                    targetVersions[i]
                );
                }
            }
            sourceChainSelectorF = sourceChainSelector;
            uint crossChainTokenAmount = swap(
                address(weth),
                address(crossChainToken[sourceChainSelector]),
                wethSwapAmountOut,
                address(this),
                crossChainTokenSwapVersion[sourceChainSelector][crossChainToken[sourceChainSelector]]
            );
            Client.EVMTokenAmount[]
                memory tokensToSendArray = new Client.EVMTokenAmount[](1);
            tokensToSendArray[0].token = crossChainToken[sourceChainSelector];
            tokensToSendArray[0].amount = crossChainTokenAmount;
            uint[] memory zeroArr = new uint[](0);
            bytes memory data = abi.encode(
                1,
                targetAddresses,
                new address[](0),
                nonce,
                zeroArr,
                zeroArr
            );
            sendToken(
                sourceChainSelector,
                data,
                sender,
                tokensToSendArray,
                PayFeesIn.LINK
            );
    }

    function _handleAskValues(
        address[] memory targetAddresses,
        uint[] memory targetVersions,
        uint nonce,
        uint64 sourceChainSelector,
        address sender
    ) internal {
        uint[] memory zeroArr = new uint[](0);
        uint[] memory tokenValueArr = new uint[](targetAddresses.length);
        for (uint i = 0; i < targetAddresses.length; i++) {
            if(targetAddresses[i] == address(weth)){
            tokenValueArr[i] = convertEthToUsd(IERC20(targetAddresses[i]).balanceOf(address(crossChainVault)));
            }else{
            uint tokenValue = getAmountOut(
                targetAddresses[i],
                address(weth),
                IERC20(targetAddresses[i]).balanceOf(address(crossChainVault)),
                targetVersions[i]
            );
            tokenValueArr[i] = convertEthToUsd(tokenValue);
            }
        }
        bytes memory data = abi.encode(
            2,
            targetAddresses,
            new address[](0),
            nonce,
            tokenValueArr,
            zeroArr
        );
        sendMessage(sourceChainSelector, sender, data, PayFeesIn.LINK);
    }

    struct HandleFirstReweightActionInputs {
        address[] currentTokens;
        address[] oracleTokens;
        uint[] targetVersions;
        uint[] targetVersions2;
        uint[] oracleTokenShares;
        uint64 sourceChainSelector;
        address sender;
        uint nonce;
        uint[] extraData;
    }

    function _handleFirstReweightAction(
        HandleFirstReweightActionInputs memory inputData
    ) private {
        ReweightActionData memory data;
        data.chainSelectorCurrentTokensCount = inputData.currentTokens.length;
        data.portfolioValue = inputData.extraData[0];
        data.chainSelectorTotalShares = inputData.extraData[1];
        data.chainValue = inputData.extraData[2];

        uint extraWethAmount = swapFirstReweightAction(
                                    data,
                                    inputData.currentTokens,
                                    inputData.oracleTokens,
                                    inputData.targetVersions,
                                    inputData.targetVersions2,
                                    inputData.oracleTokenShares,
                                    inputData.sender,
                                    inputData.nonce
                                );
        
        uint crossChainTokenAmount = swap(
            address(weth),
            address(crossChainToken[inputData.sourceChainSelector]),
            extraWethAmount,
            address(this),
            crossChainTokenSwapVersion[inputData.sourceChainSelector][crossChainToken[inputData.sourceChainSelector]]
        );
        Client.EVMTokenAmount[]
            memory tokensToSendArray = new Client.EVMTokenAmount[](1);
        tokensToSendArray[0].token = crossChainToken[inputData.sourceChainSelector];
        tokensToSendArray[0].amount = crossChainTokenAmount;
        uint[] memory zeroArr = new uint[](0);
        bytes memory encodedData = abi.encode(
            3,
            inputData.currentTokens,
            inputData.oracleTokens,
            inputData.nonce,
            zeroArr,
            zeroArr
        );
        sendToken(
            inputData.sourceChainSelector,
            encodedData,
            inputData.sender,
            tokensToSendArray,
            PayFeesIn.LINK
        );
    }

    struct SwapFirstReweightActionVars {
        uint chainSelectorCurrentTokensCount;
        uint portfolioValue;
        uint chainSelectorTotalShares;
        uint swapWethAmount;
        uint chainValue;
        uint initialWethBalance;
        uint chainSelectorOracleTokensCount;
        uint chainCurrentRealShare;
        uint wethAmountToSwap;
        uint extraWethAmount;
    }

    function swapFirstReweightAction(
        ReweightActionData memory data,
        address[] memory currentTokens,
        address[] memory oracleTokens,
        uint[] memory targetVersions,
        uint[] memory targetVersions2,
        uint[] memory oracleTokenShares,
        address sender,
        uint nonce
    ) internal returns (uint) {
        SwapFirstReweightActionVars memory vars;
        // swapData.chainSelectorCurrentTokensCount = data.chainSelectorCurrentTokensCount;
        vars.initialWethBalance = weth.balanceOf(address(crossChainVault));
        for (uint i = 0; i < vars.chainSelectorCurrentTokensCount; i++) {
            
            uint wethAmount;
            if(currentTokens[i] == address(weth)){
            wethAmount = vars.initialWethBalance;
            }else{
            wethAmount = _swapSingle(
                currentTokens[i],
                address(weth),
                IERC20(currentTokens[i]).balanceOf(address(crossChainVault)),
                address(crossChainVault),
                targetVersions[i]
            );
            }
            vars.swapWethAmount += wethAmount;
        }

        vars.chainSelectorOracleTokensCount = oracleTokens.length;

        vars.chainCurrentRealShare = (data.chainValue * 100e18) /
            data.portfolioValue;
        vars.wethAmountToSwap = (vars.swapWethAmount *
            vars.chainSelectorTotalShares) / vars.chainCurrentRealShare;
        vars.extraWethAmount = vars.swapWethAmount - vars.wethAmountToSwap;

        for (uint i = 0; i < vars.chainSelectorOracleTokensCount; i++) {
            
            if(oracleTokens[i] != address(weth)){
            uint wethAmount = _swapSingle(
                address(weth),
                oracleTokens[i],
                (vars.wethAmountToSwap * oracleTokenShares[i]) /
                    vars.chainSelectorTotalShares,
                address(crossChainVault),
                targetVersions2[i]
            );
            }
            
        }

        return vars.extraWethAmount;
    }
    
    
    struct HandleSecondReweightActionInputs {
        address[] currentTokens;
        address[] oracleTokens;
        uint[] targetVersions;
        uint[] targetVersions2;
        uint[] oracleTokenShares;
        address tokenAddress;
        uint tokenAmount;
        uint64 sourceChainSelector;
        address sender;
        uint nonce;
        uint[] extraData;
    }
    function _handleSecondReweightAction(
        HandleSecondReweightActionInputs memory inputData
    ) internal {
        uint crossChainWethAmount = swap(
            inputData.tokenAddress,
            address(weth),
            inputData.tokenAmount,
            address(crossChainVault),
            3
        );

        swapSecondReweightAction(
            inputData.currentTokens,
            inputData.oracleTokens,
            inputData.targetVersions,
            inputData.targetVersions2,
            inputData.oracleTokenShares,
            crossChainWethAmount,
            inputData.extraData
        );

        uint[] memory zeroUintArr = new uint[](0);
        address[] memory zeroAddArr = new address[](0);
    
        bytes memory data = abi.encode(
            4,
            zeroAddArr,
            zeroAddArr,
            inputData.nonce,
            zeroUintArr,
            zeroUintArr
        );
        sendMessage(inputData.sourceChainSelector, inputData.sender, data, PayFeesIn.LINK);
        
        
    }

    struct SwapSecondReweightActionVars{
        uint chainSelectorTotalShares;
        uint chainSelectorCurrentTokensCount;
        uint initialWethBalance;
        uint swapWethAmount;
        uint wethAmountToSwap;
        uint chainSelectorOracleTokensCount;
    }

    function swapSecondReweightAction(
        address[] memory currentTokens,
        address[] memory oracleTokens,
        uint[] memory targetVersions,
        uint[] memory targetVersions2,
        uint[] memory oracleTokenShares,
        uint crossChainWethAmount,
        uint[] memory extraData
    ) internal {
        SwapSecondReweightActionVars memory vars;
        vars.chainSelectorTotalShares = extraData[1];
        vars.chainSelectorCurrentTokensCount = currentTokens.length;
        vars.initialWethBalance = weth.balanceOf(address(crossChainVault));
        vars.swapWethAmount = 0; // Initialize swapWethAmount to 0
        for (uint i = 0; i < vars.chainSelectorCurrentTokensCount; i++) {
            address tokenAddress = currentTokens[i];
            uint wethAmount;
            if (tokenAddress == address(weth)) {
                wethAmount = vars.initialWethBalance;
            } else {
                wethAmount = _swapSingle(
                    tokenAddress,
                    address(weth),
                    IERC20(tokenAddress).balanceOf(address(crossChainVault)),
                    address(crossChainVault),
                    targetVersions[i]
                );
            }
            vars.swapWethAmount += wethAmount; // Accumulate wethAmount in swapWethAmount
        }
        vars.wethAmountToSwap = crossChainWethAmount + vars.swapWethAmount;
        vars.chainSelectorOracleTokensCount = oracleTokens.length;
        for (uint i = 0; i < vars.chainSelectorOracleTokensCount; i++) {
            address newTokenAddress = oracleTokens[i];
            uint newTokenMarketShare = oracleTokenShares[i];
            if (newTokenAddress != address(weth)) {
                uint wethAmount = _swapSingle(
                    address(weth),
                    newTokenAddress,
                    (vars.wethAmountToSwap * newTokenMarketShare) /
                        vars.chainSelectorTotalShares,
                    address(crossChainVault),
                    targetVersions2[i]
                );
            }
        }
    }

    function sendMessage(
        uint64 destinationChainSelector,
        address receiver,
        bytes memory _data,
        PayFeesIn payFeesIn
    ) public {
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(receiver),
            data: _data,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            // extraArgs: "",
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({gasLimit: 900_000, strict: false}) // Additional arguments, setting gas limit and non-strict sequency mode
            ),
            feeToken: payFeesIn == PayFeesIn.LINK ? i_link : address(0)
        });

        uint256 fee = IRouterClient(i_router).getFee(
            destinationChainSelector,
            message
        );

        bytes32 messageId;

        if (payFeesIn == PayFeesIn.LINK) {
            // LinkTokenInterface(i_link).approve(i_router, fee);
            messageId = IRouterClient(i_router).ccipSend(
                destinationChainSelector,
                message
            );
        } else {
            messageId = IRouterClient(i_router).ccipSend{value: fee}(
                destinationChainSelector,
                message
            );
        }

        emit MessageSent(messageId);
    }
}
