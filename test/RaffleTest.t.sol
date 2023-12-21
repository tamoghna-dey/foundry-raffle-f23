//SPDX-License-Identifier:MIT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {Raffle} from "../src/Raffle.sol";
import {DeployRaffle} from "../script/DeployRaffle.s.sol";
import {HelperConfig} from "../script/HelperConfig.s.sol";
import {Vm} from "forge-std/Vm.sol";
import {VRFCoordinatorV2Mock} from "../node_modules/@chainlink/contracts/src/v0.8/mocks/VRFCoordinatorV2Mock.sol";

contract RaffleTest is Test {
    /**Events */
    event EnteredRaffle(address indexed player);
    Raffle raffle;
    HelperConfig helperConfig;

    uint256 entranceFee;
    uint256 interval;
    address vrfCoordinator;
    bytes32 gasLane;
    uint64 subscriptionId;
    uint32 callbackGasLimit;
    address link;

    address public PLAYER = makeAddr("player");
    uint256 public constant STARTING_USER_BALANCE = 10 ether;

    modifier raffleEnterWhenTimePassed() {
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);
        _;
    }

    modifier skipFork() {
        if (block.chainid != 31337) {
            return;
        }
        _;
    }

    function setUp() external {
        DeployRaffle deployer = new DeployRaffle();
        (raffle, helperConfig) = deployer.run();
        (
            entranceFee,
            interval,
            vrfCoordinator,
            gasLane,
            subscriptionId,
            callbackGasLimit,
            link,

        ) = helperConfig.activeNetworkConfig();
        vm.deal(PLAYER, STARTING_USER_BALANCE);
    }

    function testRaffleInitializesInOpenState() public view {
        assert(raffle.getRaffleState() == Raffle.RaffleState.OPEN);
    }

    function testRaffleRevertWhenYouDontPayEnough() public {
        //arrange
        vm.prank(PLAYER);
        //act/assert
        vm.expectRevert(Raffle.Raffle__NotEnoughEthSent.selector);
        raffle.enterRaffle();
    }

    function testRaffleRecordsPlayerWhenTheyEnter() public {
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        address playerRecorded = raffle.getPlayer(0);
        assert(playerRecorded == PLAYER);
    }

    function testEmitsAnEventOnEntrace() public {
        vm.prank(PLAYER);
        vm.expectEmit(true, false, false, false, address(raffle)); //foundry cheatcode to check
        emit EnteredRaffle(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
    }

    function testCantEnterWhenRaffleIsCalculated() public {
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);
        raffle.performUpkeep("");

        vm.expectRevert(Raffle.Raffle__RaffleNotOpen.selector);
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
    }

    function testCheckUpkeepReturnsFalseifItHasNoBalance() public {
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);

        (bool upkeepNeeded, ) = raffle.checkUpkeep("");
        assert(!upkeepNeeded);
    }

    function testCheckUpKeepReturnsFalseIfRaffleIsNotOpen() public {
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);

        raffle.performUpkeep("");

        (bool upkeepNeeded, ) = raffle.checkUpkeep("");
        assert(!upkeepNeeded);
    }

    function testPerformUpkeepCanOnlyRunIfCheckUpKeepIsTrue()
        public
        raffleEnterWhenTimePassed
    {
        raffle.performUpkeep("");
    }

    function testPerformUpkeepCanOnlyRunIfCheckUpKeepIsFalse() public {
        uint256 currentBalance = 0;
        uint256 numPlayer = 0;
        uint256 raffleState = 0;

        vm.expectRevert(
            abi.encodeWithSelector(
                Raffle.Raffle__UpkeepNotNeeded.selector,
                currentBalance,
                numPlayer,
                raffleState
            )
        );

        raffle.performUpkeep("");
    }

    function testPerformUpkeepUpdatesRaffleStateAndEmitRequestId()
        public
        raffleEnterWhenTimePassed
    {
        vm.recordLogs();
        raffle.performUpkeep("");
        Vm.Log[] memory entries = vm.getRecordedLogs(); //vm.getRecordedLogs(), Gets all the recorded logs
        bytes32 requestId = entries[1].topics[0];

        Raffle.RaffleState rstate = raffle.getRaffleState();

        assert(uint256(requestId) > 0);
        assertEq(uint256(rstate), 1);
    }

    function testFullfillRandomWordsCanOnlybeCalledAfterPerformUpKeep()
        public
        raffleEnterWhenTimePassed
        skipFork
    {
        vm.expectRevert("nonexsistent request");
        VRFCoordinatorV2Mock(vrfCoordinator).fulfillRandomWords(
            0,
            address(raffle)
        );
    }

    function testFulFillRandomWordsPicksWinnerAndResetsAndSendsMoney()
        public
        raffleEnterWhenTimePassed
        skipFork
    {
        uint256 additionalEntrants = 5;
        uint256 startingindex = 1;

        for (
            uint256 i = startingindex;
            i < startingindex + additionalEntrants;
            i++
        ) {
            address player = address(uint160(i));
            hoax(player, STARTING_USER_BALANCE);
            raffle.enterRaffle{value: entranceFee};
        }

        uint256 prize = entranceFee * (additionalEntrants + 1);

        vm.recordLogs();
        raffle.performUpkeep("");
        Vm.Log[] memory entries = vm.getRecordedLogs(); //vm.getRecordedLogs(), Gets all the recorded logs
        bytes32 requestId = entries[1].topics[0];
        uint256 previousTimeStamp = raffle.getLastTimeStamp();

        VRFCoordinatorV2Mock(vrfCoordinator).fulfillRandomWords(
            uint256(requestId),
            address(raffle)
        );

        assert(uint256(raffle.getRaffleState()) == 0);
        assert(raffle.getRecentWinner() != address(0));
        assert(raffle.getLengthoOfPlayers() == 0);
        assert(previousTimeStamp < raffle.getLastTimeStamp());
        assert(
            raffle.getRecentWinner().balance ==
                STARTING_USER_BALANCE + prize - entranceFee
        );
    }
}
