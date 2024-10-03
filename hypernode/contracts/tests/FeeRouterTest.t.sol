// // SPDX-License-Identifier: Unlicensed
// pragma solidity ^0.8.2;

// import {Test} from "forge-std/Test.sol";
// import {console} from "forge-std/console.sol";
// import {FeeRouter} from "../src/FeeRouter.sol";
// import {RiftExchange} from "../src/RiftExchange.sol";
// import {MockUSDT} from "./MockUSDT.sol";
// import {ISP1Verifier} from "@sp1-contracts/ISP1Verifier.sol";
// import {BlockHashStorage} from "../src/BlockHashStorage.sol";

// contract FeeRouterExchangeTest is Test {
//     FeeRouter public feeRouter;
//     RiftExchange public riftExchange;
//     MockUSDT public depositToken;

//     address public owner;
//     address public manager1;
//     address public manager2;
//     address public manager3;
//     address public nonManager;
//     address public user1;
//     address public verifierAddress;

//     function setUp() public {
//         depositToken = new MockUSDT();
//         owner = address(this);
//         manager1 = address(0x1);
//         manager2 = address(0x2);
//         manager3 = address(0x3);
//         nonManager = address(0x4);
//         user1 = address(0x5);
//         verifierAddress = address(0x6);

//         // Set up partition owners
//         address[] memory partitionOwners = new address[](4);
//         partitionOwners[0] = manager1;
//         partitionOwners[1] = manager2;
//         partitionOwners[2] = manager3;
//         partitionOwners[3] = nonManager;

//         uint256[] memory percentages = new uint256[](4);
//         percentages[0] = 3200; // 32%
//         percentages[1] = 3200; // 32%
//         percentages[2] = 3200; // 32%
//         percentages[3] = 400; // 4%

//         bool[] memory isManager = new bool[](4);
//         isManager[0] = true;
//         isManager[1] = true;
//         isManager[2] = true;
//         isManager[3] = false;

//         // Deploy FeeRouter
//         feeRouter = new FeeRouter(owner, partitionOwners, percentages, isManager, address(depositToken));

//         // Mint tokens to test addresses
//         depositToken.mint(address(this), 100000 * 10 ** 18);
//         depositToken.mint(user1, 50000 * 10 ** 18);

//         // Approve RiftExchange to spend tokens on behalf of user1
//         vm.prank(user1);
//         depositToken.approve(address(riftExchange), type(uint256).max);

//         // Approve RiftExchange to spend tokens on behalf of this contract (if needed)
//         depositToken.approve(address(riftExchange), type(uint256).max);

//         // Deploy RiftExchange with necessary parameters
//         // Note: You need to replace '...parameters...' with actual parameters
//         riftExchange = new RiftExchange(
//             0, // initialCheckpointHeight
//             bytes32(0), // initialBlockHash
//             bytes32(0), // initialRetargetBlockHash
//             0, // initialChainwork
//             verifierAddress, // verifierContractAddress
//             address(depositToken), // depositTokenAddress
//             address(feeRouter), // feeRouterAddress
//             owner, // owner
//             bytes32(0), // circuitVerificationKey
//             6 // minimumConfirmationDelta
//         );

//         // Approve RiftExchange to spend tokens on behalf of this contract
//         depositToken.approve(address(riftExchange), type(uint256).max);
//     }

//     function testFeeRouterWithExchange() public {
//         uint256 depositAmount = 10000 * 10 ** 18; // 10,000 tokens
//         uint64 exchangeRate = 1000; // Arbitrary exchange rate
//         bytes22 btcPayoutLockingScript = hex"0014841b80d2cc75f5345c482af96294d04fdd66b2b7";

//         // Simulate depositing liquidity into the exchange by manager1
//         vm.startPrank(manager1);
//         depositToken.mint(manager1, depositAmount);
//         depositToken.approve(address(riftExchange), depositAmount);

//         riftExchange.depositLiquidity(depositAmount, exchangeRate, btcPayoutLockingScript);
//         vm.stopPrank();

//         // Simulate a user reserving liquidity (generating fees)
//         address reservationOwner = user1;
//         uint256[] memory vaultIndexesToReserve = new uint256[](1);
//         vaultIndexesToReserve[0] = 0; // Assuming the first vault

//         uint192[] memory amountsToReserve = new uint192[](1);
//         amountsToReserve[0] = 1000 * 10 ** 18; // Reserving 1,000 tokens

//         address ethPayoutAddress = user1;
//         uint256 totalSatsInputIncludingProxyFee = 100000; // Arbitrary value

//         vm.prank(user1);
//         riftExchange.reserveLiquidity(
//             reservationOwner,
//             vaultIndexesToReserve,
//             amountsToReserve,
//             ethPayoutAddress,
//             totalSatsInputIncludingProxyFee,
//             new uint256[](0)
//         );

//         // Simulate fee distribution
//         // Assuming the exchange contract calls feeRouter.receiveFees internally
//         // You might need to adjust your RiftExchange contract to call feeRouter.receiveFees
//         // For testing, we can simulate the fee transfer to the FeeRouter

//         uint256 expectedFee = (amountsToReserve[0] * riftExchange.protocolFeeBP()) / riftExchange.BP_SCALE();
//         // Transfer the protocol fee to the FeeRouter
//         depositToken.transfer(address(feeRouter), expectedFee);

//         // Simulate the FeeRouter distributing fees
//         vm.prank(address(feeRouter));
//         feeRouter.receiveFees(address(0), address(0));

//         // Verify that the FeeRouter's totalReceived has increased
//         assertEq(feeRouter.totalReceived(), expectedFee);

//         // Verify the balances of partition owners
//         uint256 managerShare = (expectedFee * 3200) / 10000; // 32% of expectedFee
//         uint256 nonManagerShare = (expectedFee * 400) / 10000; // 4% of expectedFee

//         assertEq(depositToken.balanceOf(manager1), managerShare);
//         assertEq(depositToken.balanceOf(manager2), managerShare);
//         assertEq(depositToken.balanceOf(manager3), managerShare);
//         assertEq(depositToken.balanceOf(nonManager), nonManagerShare);

//         // Ensure that the total distributed equals the expected fee
//         uint256 totalDistributed = managerShare * 3 + nonManagerShare;
//         assertEq(totalDistributed, expectedFee);
//     }

//     function testMultipleReferralSwaps() public {
//         uint256 amount = 2000 * 10 ** 18; // 2,000 tokens

//         // Set up referrers and swappers
//         address ethReferrer1 = address(0x9);
//         address btcReferrer1 = address(0xA);
//         address swapperEthAddress1 = address(0xB);
//         address swapperBtcAddress1 = address(0xC);

//         address ethReferrer2 = address(0xD);
//         address btcReferrer2 = address(0xE);
//         address swapperEthAddress2 = address(0xF);
//         address swapperBtcAddress2 = address(0x10);

//         // Add ETH and BTC referrers
//         vm.prank(manager1);
//         feeRouter.addApprovedEthReferrer(swapperEthAddress1, ethReferrer1);
//         vm.prank(manager1);
//         feeRouter.addApprovedBtcReferrer(swapperBtcAddress1, btcReferrer1);

//         vm.prank(manager2);
//         feeRouter.addApprovedEthReferrer(swapperEthAddress2, ethReferrer2);
//         vm.prank(manager2);
//         feeRouter.addApprovedBtcReferrer(swapperBtcAddress2, btcReferrer2);

//         // Mint tokens to this contract and approve FeeRouter
//         depositToken.mint(address(this), amount);
//         depositToken.approve(address(feeRouter), amount);

//         // First referral swap
//         feeRouter.receiveFees(swapperEthAddress1, swapperBtcAddress1);

//         // Mint tokens and approve again for the second swap
//         depositToken.mint(address(this), amount);
//         depositToken.approve(address(feeRouter), amount);

//         // Second referral swap
//         feeRouter.receiveFees(swapperEthAddress2, swapperBtcAddress2);

//         // Verify balances
//         uint256 perSwapAmount = amount;
//         uint256 totalAmount = amount * 2;

//         // Referral fees
//         uint256 ethReferralFee = perSwapAmount / 2; // 50% per swap
//         uint256 btcReferralFee = perSwapAmount / 2; // 50% per swap

//         // Remaining amount after referral fees
//         uint256 remainingAmount = perSwapAmount - ethReferralFee - btcReferralFee;

//         // Manager shares per swap
//         uint256 managerSharePerSwap = (remainingAmount * 3200) / 10000; // 32%
//         uint256 nonManagerSharePerSwap = (remainingAmount * 400) / 10000; // 4%

//         // First swap assertions
//         assertEq(depositToken.balanceOf(ethReferrer1), ethReferralFee);
//         assertEq(depositToken.balanceOf(btcReferrer1), btcReferralFee);

//         // Second swap assertions
//         assertEq(depositToken.balanceOf(ethReferrer2), ethReferralFee);
//         assertEq(depositToken.balanceOf(btcReferrer2), btcReferralFee);

//         // Managers and non-manager balances
//         uint256 totalManagerShare = managerSharePerSwap * 3 * 2; // For two swaps
//         uint256 totalNonManagerShare = nonManagerSharePerSwap * 2;

//         assertEq(depositToken.balanceOf(manager1), managerSharePerSwap * 2);
//         assertEq(depositToken.balanceOf(manager2), managerSharePerSwap * 2);
//         assertEq(depositToken.balanceOf(manager3), managerSharePerSwap * 2);
//         assertEq(depositToken.balanceOf(nonManager), totalNonManagerShare);

//         // Total distributed tokens
//         uint256 totalDistributed = (ethReferralFee + btcReferralFee) * 2 + totalManagerShare + totalNonManagerShare;
//         uint256 leftover = totalAmount - totalDistributed;
//         assertEq(leftover, 0);
//     }
// }
