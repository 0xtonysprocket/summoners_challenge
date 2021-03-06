pragma solidity ^0.8.4;

import "./lib/chainlink/VRFCoordinatorV2Interface.sol";
import "./lib/chainlink/VRFConsumerBaseV2.sol";
import "./lib/openzeppelin/access/Ownable.sol";
import "./lib/openzeppelin/token/IERC20.sol"; //this should be Zkasino Token Interface

contract SummonerChallenge is VRFConsumerBaseV2, Ownable {

    event SummonerChallenged(address indexed challenger, uint256 indexed VRFRequestId);
    event SummonerTypeSelected(uint256 indexed VRFRequestId, uint8 indexed monsterType);
    event ChallengerTypeDominant();
    event SummonerTypeDominant();
    event SummonerWins(uint8 summonerRoll, uint8 adjustedChallengerRoll, string summonerSays);
    event ChallengerWins(uint8 summonerRoll, uint8 adjustedChallengerRoll, uint houseCut, uint winnings);

    struct Challenge {
        address challenger;
        uint256 wager;
        uint8 monsterTypeSelection;
        bool result;
    }

    //maps exactly one request id to exactly one challenger address
    mapping(uint256 => address) private IDToChallenger;

    //maps one challenger address to all their challenge IDs
    mapping(address => uint256[]) public ChallengerToIDs;

    // Valid Monster Types 
    // 1 : Water
    // 2 : Stone
    // 3 : Heat
    // 4 : Toxic
    mapping(uint256 => uint8) private IDToMonsterTypeSelection;

    // Request ID to wager for the challenge
    mapping(uint256 => uint256) private IDToWager;

    // true for challenger won and false for summoner (house) won 
    mapping(uint256 => bool) public IDToChallengeResult;

    // rake for the zkasino
    // interpreted as a decimal (1 is .001, 2 is .002, ... 500 is .5, ... 1000 is 1)
    uint16 RAKE_DENOMINATOR = 1000;
    uint16 public rake;

    // amount of ZKasino tokens the house has earned since last transferring winnings
    uint256 public houseEarningsSinceLastTransfer;

    constructor(uint64 subscriptionId, address vrfCoordinator, address ZKasinoToken, uint16 _rake) VRFConsumerBaseV2(vrfCoordinator) {
        require(_rake <= 1000, "invalid rake");
        VRFCoordinatorV2Interface COORDINATOR = VRFCoordinatorV2Interface(vrfCoordinator);
        IERC20 ZKT = IERC20(ZKasinoToken);
        rake = _rake;
    }


    //////////////////
    //// CORE LOGIC
    //////////////////

    function ChallengeSummoner(uint8 calldata monsterType, uint256 bet_amount) external returns(uint256 VRFRequestId) {
        require(monsterType <= 4, "invalid monster type");
        require(monsterType != 0, "monster type cannot be 0");
        require(ZKT.balanceOf(msg.sender) > bet_amount, "not enough tokens to cover wager");
        require(ZKT.allowance(msg.sender, address(this)) > bet_amount, "not enough approval for bet size");

        VRFRequestId = COORDINATOR.requestRandomWords(
        keyHash,
        subscriptionId,
        requestConfirmations,
        callbackGasLimit,
        numWords
       );

        ChallengerToIDs[msg.sender].push(VRFRequestId);
        IDToChallenger[VRFRequestId] = msg.sender;
        IDToMonsterTypeSelection[VRFRequestId] = monsterType;
        IDToWager[VRFRequestId] = bet_amount;

        emit SummonerChallenged(msg.sender, VRFRequestId);

        //transfer wager from challenger to contract
        ZKT.transferFrom(msg.sender, address(this), bet_amount);

        return (VRFRequestId);
    }

    function fullfilRandomWords(uint256 VRFRequestId, uint256[] memory randomWords) internal override {
        address challenger = IDToChallenger[VRFRequestId];
        uint8 challengerType = IDToMonsterTypeSelection[VRFRequestId];
        uint256 wager = IDToWager[VRFRequestId];
        int8 monsterTypeAdjustment = 0;

        //randomness
        uint8 summonersType = (randomWords[0] % 4) + 1;
        uint8 challengerRoll = (randomWords[1] % 100) + 1;
        uint8 summonerRoll = (randomWords[2] % 101) + 1; //Summoner has slightly better odds

        emit SummonerTypeSelected(VRFRequestId, summonersType);

        // logic to check for type dominance

        // challenger type is dominated
        if ((challengerType - summonersType) % 4 == 1) {
            monsterTypeAdjustment = -2;

            emit SummonerTypeDominant();
        }
        // challenger type dominates
        else if ((summonersType - challengerType) % 4 == 1) {
            monsterTypeAdjustment = 2;

            emit ChallengerTypeDominant();
        }

        // adjust roll for Challenger based on types
        uint8 adjustedChallengerRoll = (int8(challengerRoll) + monsterTypeAdjustment);


        if (summonerRoll >= adjustedChallengerRoll) { //summoner wins in a tie
            
            //summoner wins
            IDToChallengeResult[VRFRequestId] = false;

            houseEarningsSinceLastTransfer += wager;

            emit SummonerWins(summonerRoll, adjustedChallengerRoll, "Better Luck Next Time");
        }
        else {

            //challenger wins
            IDToChallengeResult[VRFRequestId] = true;

            //calculate rake
            uint houseCut = (wager * rake) / RAKE_DENOMINATOR;
            houseEarningsSinceLastTransfer += houseCut;

            //calculate winnings
            uint winnings = (wager * 2) - houseCut;

            ZKT.transfer(challenger, winnings);
            emit ChallengerWins(summonerRoll, adjustedChallengerRoll, houseCut, winnings);
        }
    }

    //////////////////
    //// VIEW METHODS
    //////////////////

    function getChallenges() public view returns (uint256[] challenges) {
        uint256[] _challenges = ChallengerToIDs[msg.sender];

        return (_challenges);
    }

    function getChallengeFromID(uint256 VRFRequestID) public view returns (Challenge challenge) {
        
        Challenge _challenge = Challenge(
            IDToChallenger[VRFRequestID],
            IDToWager[VRFRequestID],
            IDToMonsterTypeSelection[VRFRequestID],
            IDToChallengeResult[VRFRequestID]
        );

        return (_challenge);
    }

    //////////////////
    //// ADMIN METHODS
    //////////////////

    function collectHouseWinnings(address recipient) external onlyOwner() returns (bool success) {
        ZKT.transfer(recipient, houseEarningsSinceLastTransfer);

        houseEarningsSinceLastTransfer = 0;
    }
}