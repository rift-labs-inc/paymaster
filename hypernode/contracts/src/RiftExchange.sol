// SPDX-License-Identifier: Unlicensed
pragma solidity ^0.8.2;

import {Owned} from "solmate/auth/Owned.sol";
import {ISP1Verifier} from "@sp1-contracts/ISP1Verifier.sol";
import {BlockHashStorage} from "./BlockHashStorage.sol";
import {console} from "forge-std/console.sol";

error InvalidExchangeRate();
error NotVaultOwner();
error NotEnoughLiquidity();
error WithdrawalAmountError();
error UpdateExchangeRateError();
error ReservationNotExpired();
error ReservationNotProved();
error StillInChallengePeriod();
error OverwrittenProposedBlock();
error NewDepositsPaused();
error InvalidInputArrays();
error InvalidReservationState();
error NotApprovedHypernode();
error AmountToReserveTooLow(uint256 index);

interface IERC20 {
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);

    function transfer(address recipient, uint256 amount) external returns (bool);

    function balanceOf(address account) external view returns (uint256);

    function allowance(address owner, address spender) external view returns (uint256);

    function approve(address spender, uint256 amount) external returns (bool);

    function decimals() external view returns (uint8);
}

contract RiftExchange is BlockHashStorage, Owned {
    // --------- TYPES --------- //
    enum ReservationState {
        None, // 0
        Created, // 1
        Proved, // 2
        Completed, // 3
        Expired // 4
    }

    struct SwapReservation {
        address owner;
        uint32 confirmationBlockHeight;
        uint64 reservationTimestamp;
        uint64 liquidityUnlockedTimestamp; // timestamp when reservation was proven and unlocked
        ReservationState state;
        address ethPayoutAddress;
        bytes32 lpReservationHash;
        bytes32 nonce; // sent in bitcoin tx calldata from buyer -> lps to prevent replay attacks
        uint256 totalSatsInputIncludingProxyFee; // in sats (including proxy wallet fee)
        uint256 totalSwapOutputAmount; // in token's smallest unit (wei, μUSDT, etc)
        uint256 proposedBlockHeight;
        bytes32 proposedBlockHash;
        uint256[] vaultIndexes;
        uint192[] amountsToReserve;
        uint64[] expectedSatsOutput;
    }

    struct LiquidityProvider {
        uint256[] depositVaultIndexes;
    }

    struct DepositVault {
        address owner;
        uint64 depositTimestamp;
        uint256 initialBalance; // in token's smallest unit (wei, μUSDT, etc)
        uint256 unreservedBalance; // in token's smallest unit (wei, μUSDT, etc) - true balance = unreservedBalance + sum(ReservationState.Created && expired SwapReservations on this vault)
        uint256 withdrawnAmount; // in token's smallest unit (wei, μUSDT, etc)
        uint64 exchangeRate; // amount of token's smallest unit (buffered to 18 digits) per 1 sat
        bytes22 btcPayoutLockingScript;
    }

    struct ProofPublicInputs {
        bytes32 natural_txid;
        bytes32 merkle_root;
        bytes32 lp_reservation_hash;
        bytes32 order_nonce;
        uint64 lp_count;
        bytes32 retarget_block_hash;
        uint64 safe_block_height;
        uint64 safe_block_height_delta;
        uint64 confirmation_block_height_delta;
        bytes32[] block_hashes;
        uint256[] block_chainworks;
        bool is_transaction_proof;
    }

    // --------- CONSTANTS --------- //
    uint256 public constant SCALE = 1e18;
    uint256 public constant BP_SCALE = 10000;
    uint32 public constant RESERVATION_LOCKUP_PERIOD = 4 hours;
    uint32 public constant CHALLENGE_PERIOD = 5 minutes;
    uint8 public constant MINIMUM_CONFIRMATION_DELTA = 1;
    IERC20 public immutable DEPOSIT_TOKEN;
    uint8 public immutable TOKEN_DECIMALS;
    bytes32 public immutable CIRCUIT_VERIFICATION_KEY;
    ISP1Verifier public immutable VERIFIER_CONTRACT;

    // --------- STATE --------- //
    bool public isDepositNewLiquidityPaused = false;
    uint8 public protocolFeeBP = 10; // 10 bps = 0.1%
    address feeRouterAddress;

    DepositVault[] public depositVaults;
    SwapReservation[] public swapReservations;
    mapping(address => LiquidityProvider) liquidityProviders;
    mapping(address => bool) public permissionedHypernodes;

    // --------- EVENTS --------- //
    event LiquidityDeposited(address indexed depositor, uint256 depositVaultIndex, uint256 amount, uint64 exchangeRate);
    event LiquidityReserved(address indexed reserver, uint256 swapReservationIndex, bytes32 orderNonce);
    event ProofSubmitted(address indexed prover, uint256 swapReservationIndex, bytes32 orderNonce);
    event ExchangeRateUpdated(uint256 indexed globalVaultIndex, uint64 newExchangeRate, uint256 unreservedBalance);
    event SwapComplete(uint256 swapReservationIndex, SwapReservation swapReservation, uint256 protocolFee);
    event LiquidityWithdrawn(uint256 indexed globalVaultIndex, uint192 amountWithdrawn, uint256 remainingBalance);

    // --------- MODIFIERS --------- //
    modifier newDepositsNotPaused() {
        if (isDepositNewLiquidityPaused) {
            revert NewDepositsPaused();
        }
        _;
    }

    modifier onlyApprovedHypernode() {
        if (!permissionedHypernodes[msg.sender]) {
            revert NotApprovedHypernode();
        }
        _;
    }

    //--------- CONSTRUCTOR ---------//
    constructor(
        uint256 initialCheckpointHeight,
        bytes32 initialBlockHash,
        bytes32 initialRetargetBlockHash,
        uint256 initialChainwork,
        address verifierContractAddress,
        address depositTokenAddress,
        address initialFeeRouterAddress,
        address owner,
        bytes32 circuitVerificationKey,
        address[] memory initialPermissionedHypernodes
    )
        BlockHashStorage(
            initialCheckpointHeight,
            initialChainwork,
            initialBlockHash,
            initialRetargetBlockHash,
            minimumConfirmationDelta
        )
        Owned(owner)
    {
        // [0] set verifier contract and deposit token
        CIRCUIT_VERIFICATION_KEY = circuitVerificationKey;
        VERIFIER_CONTRACT = ISP1Verifier(verifierContractAddress);
        DEPOSIT_TOKEN = IERC20(depositTokenAddress);
        TOKEN_DECIMALS = DEPOSIT_TOKEN.decimals();

        // [1] set fee router address
        feeRouterAddress = initialFeeRouterAddress;

        // [2] set initial permissioned hypernodes
        for (uint256 i = 0; i < initialPermissionedHypernodes.length; i++) {
            permissionedHypernodes[initialPermissionedHypernodes[i]] = true;
        }
    }

    //--------- WRITE FUNCTIONS ---------//
    function depositLiquidity(
        uint256 depositAmount,
        uint64 exchangeRate,
        bytes22 btcPayoutLockingScript
    ) public newDepositsNotPaused {
        // [0] validate btc exchange rate
        if (exchangeRate == 0) {
            revert InvalidExchangeRate();
        }

        // [1] create new liquidity provider if it doesn't exist
        if (liquidityProviders[msg.sender].depositVaultIndexes.length == 0) {
            liquidityProviders[msg.sender] = LiquidityProvider({depositVaultIndexes: new uint256[](0)});
        }

        // [2] create new deposit vault
        depositVaults.push(
            DepositVault({
                owner: msg.sender,
                depositTimestamp: uint64(block.timestamp),
                initialBalance: depositAmount,
                unreservedBalance: depositAmount,
                withdrawnAmount: 0,
                exchangeRate: exchangeRate,
                btcPayoutLockingScript: btcPayoutLockingScript
            })
        );

        // [3] add deposit vault index to liquidity provider
        addDepositVaultIndexToLP(msg.sender, depositVaults.length - 1);

        // [4] transfer deposit token to contract
        DEPOSIT_TOKEN.transferFrom(msg.sender, address(this), depositAmount);

        emit LiquidityDeposited(msg.sender, depositVaults.length - 1, depositAmount, exchangeRate);
    }

    function updateExchangeRate(
        uint256 globalVaultIndex, // index of vault in depositVaults
        uint64 newExchangeRate,
        uint256[] memory expiredSwapReservationIndexes
    ) public {
        // [0] ensure msg.sender is vault owner
        if (depositVaults[globalVaultIndex].owner != msg.sender) {
            revert NotVaultOwner();
        }

        // [1] validate new exchange rate
        if (newExchangeRate == 0) {
            revert InvalidExchangeRate();
        }

        // [2] retrieve deposit vault
        DepositVault storage vault = depositVaults[globalVaultIndex];
        uint256 unreservedBalance = vault.unreservedBalance;

        // [3] cleanup dead swap reservations
        cleanUpDeadSwapReservations(expiredSwapReservationIndexes);

        // [4] if the entire vault is unreserved, update the exchange rate
        if (unreservedBalance == vault.initialBalance) {
            vault.exchangeRate = newExchangeRate;
            emit ExchangeRateUpdated(globalVaultIndex, newExchangeRate, unreservedBalance);
        }
        // [5] ensure there is some unreserved balance to create a new deposit vault
        else if (unreservedBalance == 0) {
            revert UpdateExchangeRateError();
        }
        // [6] otherwise make a new fork deposit vault with the new exchange rate and unreserved balance
        else {
            uint256 newVaultIndex = depositVaults.length;
            depositVaults.push(
                DepositVault({
                    owner: vault.owner,
                    depositTimestamp: uint64(block.timestamp),
                    initialBalance: unreservedBalance,
                    unreservedBalance: unreservedBalance,
                    withdrawnAmount: 0,
                    exchangeRate: newExchangeRate,
                    btcPayoutLockingScript: vault.btcPayoutLockingScript
                })
            );

            vault.withdrawnAmount += unreservedBalance;
            vault.unreservedBalance = 0;

            // [7] add deposit vault index to liquidity provider
            addDepositVaultIndexToLP(msg.sender, newVaultIndex);

            emit ExchangeRateUpdated(newVaultIndex, newExchangeRate, unreservedBalance);
        }
    }

    function withdrawLiquidity(
        uint256 globalVaultIndex, // index of vault in depositVaults
        uint192 amountToWithdraw,
        uint256[] memory expiredSwapReservationIndexes
    ) public {
        // [0] ensure msg.sender is vault owner
        if (depositVaults[globalVaultIndex].owner != msg.sender) {
            revert NotVaultOwner();
        }

        // [2] clean up dead swap reservations
        cleanUpDeadSwapReservations(expiredSwapReservationIndexes);

        // [3] retrieve the vault
        DepositVault storage vault = depositVaults[globalVaultIndex];

        // [4] validate amount to withdraw
        if (amountToWithdraw == 0 || amountToWithdraw > vault.unreservedBalance) {
            revert WithdrawalAmountError();
        }

        // [5] withdraw funds to vault owner
        vault.unreservedBalance -= amountToWithdraw;
        vault.withdrawnAmount += amountToWithdraw;

        DEPOSIT_TOKEN.transfer(msg.sender, amountToWithdraw);

        emit LiquidityWithdrawn(globalVaultIndex, amountToWithdraw, vault.unreservedBalance);
    }

    function reserveLiquidity(
        address reservationOwner,
        uint256[] memory vaultIndexesToReserve,
        uint192[] memory amountsToReserve,
        address ethPayoutAddress,
        uint256 totalSatsInputIncludingProxyFee,
        uint256[] memory expiredSwapReservationIndexes
    ) public {
        // [0] validate input arrays
        if (vaultIndexesToReserve.length == 0 || vaultIndexesToReserve.length != amountsToReserve.length) {
            revert InvalidInputArrays();
        }

        // [1] validate total amount to reserve is greater than zero
        for (uint256 i = 0; i < amountsToReserve.length; i++) {
            if (amountsToReserve[i] == 0) {
                revert AmountToReserveTooLow(i);
            }
        }

        // [2] calculate & validate total amount of input/output the user is attempting to reserve
        uint256 combinedAmountsToReserve = 0;
        uint256 combinedExpectedSatsOutput = 0;
        uint64[] memory expectedSatsOutputArray = new uint64[](vaultIndexesToReserve.length);

        for (uint256 i = 0; i < amountsToReserve.length; i++) {
            uint256 exchangeRate = depositVaults[vaultIndexesToReserve[i]].exchangeRate;
            combinedAmountsToReserve += amountsToReserve[i];
            uint256 bufferedAmountToReserve = bufferTo18Decimals(amountsToReserve[i], TOKEN_DECIMALS);
            uint256 expectedSatsOutput = bufferedAmountToReserve / exchangeRate;
            combinedExpectedSatsOutput += expectedSatsOutput;
            expectedSatsOutputArray[i] = uint64(expectedSatsOutput);
        }

        // [3] clean up dead swap reservations
        cleanUpDeadSwapReservations(expiredSwapReservationIndexes);

        // [4] compute the aggregated vault hash && ensure there is enough liquidity in each vault
        bytes32 vaultHash;
        for (uint256 i = 0; i < vaultIndexesToReserve.length; i++) {
            vaultHash = sha256(
                abi.encode(
                    expectedSatsOutputArray[i],
                    depositVaults[vaultIndexesToReserve[i]].btcPayoutLockingScript,
                    vaultHash
                )
            );

            if (amountsToReserve[i] > depositVaults[vaultIndexesToReserve[i]].unreservedBalance) {
                revert NotEnoughLiquidity();
            }
        }

        // [5] compute order nonce
        bytes32 orderNonce = keccak256(
            abi.encode(ethPayoutAddress, block.timestamp, block.chainid, vaultHash, swapReservations.length) // TODO_BEFORE_AUDIT: fully audit nonce attack vector
        );

        // [6] create new swap reservation
        swapReservations.push(
            SwapReservation({
                owner: reservationOwner,
                state: ReservationState.Created,
                confirmationBlockHeight: 0,
                ethPayoutAddress: ethPayoutAddress,
                reservationTimestamp: uint64(block.timestamp),
                liquidityUnlockedTimestamp: 0,
                totalSwapOutputAmount: combinedAmountsToReserve,
                nonce: orderNonce,
                totalSatsInputIncludingProxyFee: totalSatsInputIncludingProxyFee,
                proposedBlockHeight: 0,
                proposedBlockHash: bytes32(0),
                lpReservationHash: vaultHash,
                vaultIndexes: vaultIndexesToReserve,
                amountsToReserve: amountsToReserve,
                expectedSatsOutput: expectedSatsOutputArray
            })
        );

        // [7] update unreserved balances in deposit vaults
        for (uint256 i = 0; i < vaultIndexesToReserve.length; i++) {
            depositVaults[vaultIndexesToReserve[i]].unreservedBalance -= amountsToReserve[i];
        }

        emit LiquidityReserved(reservationOwner, getReservationLength() - 1, orderNonce);
    }

    function buildPublicInputs(
        uint256 swapReservationIndex,
        bytes32 bitcoinTxId,
        bytes32 merkleRoot,
        uint32 safeBlockHeight,
        uint64 proposedBlockHeight,
        uint64 confirmationBlockHeight,
        bytes32[] memory blockHashes,
        uint256[] memory blockChainworks,
        bool isTransactionProof
    ) public view returns (ProofPublicInputs memory) {
        SwapReservation storage swapReservation = swapReservations[swapReservationIndex];
        return
            ProofPublicInputs({
                natural_txid: bitcoinTxId,
                merkle_root: merkleRoot,
                lp_reservation_hash: swapReservation.lpReservationHash,
                order_nonce: swapReservation.nonce,
                lp_count: uint64(swapReservation.vaultIndexes.length),
                retarget_block_hash: getBlockHash(calculateRetargetHeight(safeBlockHeight)),
                safe_block_height: safeBlockHeight,
                safe_block_height_delta: proposedBlockHeight - safeBlockHeight,
                confirmation_block_height_delta: confirmationBlockHeight - proposedBlockHeight,
                block_hashes: blockHashes,
                block_chainworks: blockChainworks,
                is_transaction_proof: isTransactionProof
            });
    }

    function submitSwapProof(
        uint256 swapReservationIndex,
        bytes32 bitcoinTxId,
        bytes32 merkleRoot,
        uint32 safeBlockHeight,
        uint64 proposedBlockHeight,
        uint64 confirmationBlockHeight,
        bytes32[] memory blockHashes,
        uint256[] memory blockChainworks,
        bytes memory proof
    ) public onlyApprovedHypernode {
        // [0] retrieve swap reservation
        SwapReservation storage swapReservation = swapReservations[swapReservationIndex];

        // [1] ensure swap reservation is created
        if (swapReservation.state != ReservationState.Created) {
            revert InvalidReservationState();
        }

        // [2] craft public inputs
        bytes memory publicInputs = abi.encode(
            buildPublicInputs(
                swapReservationIndex,
                bitcoinTxId,
                merkleRoot,
                safeBlockHeight,
                proposedBlockHeight,
                confirmationBlockHeight,
                blockHashes,
                blockChainworks,
                true
            )
        );

        // [3] verify proof (will revert if invalid)
        VERIFIER_CONTRACT.verifyProof(CIRCUIT_VERIFICATION_KEY, publicInputs, proof);

        // [4] add verified block to block hash storage contract
        addBlock(safeBlockHeight, proposedBlockHeight, confirmationBlockHeight, blockHashes, blockChainworks); // TODO: audit

        // [5] update swap reservation
        swapReservation.state = ReservationState.Proved;
        swapReservation.liquidityUnlockedTimestamp = uint64(block.timestamp) + CHALLENGE_PERIOD;
        swapReservation.proposedBlockHeight = proposedBlockHeight;
        swapReservation.proposedBlockHash = blockHashes[proposedBlockHeight - safeBlockHeight];

        emit ProofSubmitted(msg.sender, swapReservationIndex, swapReservation.nonce);
    }

    function releaseLiquidity(uint256 swapReservationIndex) public {
        // [0] retrieve swap order
        SwapReservation storage swapReservation = swapReservations[swapReservationIndex];

        // [1] validate swap proof has been submitted
        if (swapReservation.state != ReservationState.Proved) {
            revert ReservationNotProved();
        }

        // [2] ensure challenge period has passed since proof submission
        if (block.timestamp < swapReservation.liquidityUnlockedTimestamp) {
            revert StillInChallengePeriod();
        }

        // [3] ensure swap block is still part of longest chain
        console.log("proposedBlockHash actual");
        console.logBytes32(getBlockHash(swapReservation.proposedBlockHeight));
        console.log("proposedBlockHash expected");
        console.logBytes32(swapReservation.proposedBlockHash);
        if (getBlockHash(swapReservation.proposedBlockHeight) != swapReservation.proposedBlockHash) {
            revert OverwrittenProposedBlock();
        }

        // [4] mark swap reservation as completed
        swapReservation.state = ReservationState.Completed;

        // [5] release protocol fee
        uint256 protocolFee = (swapReservation.totalSwapOutputAmount * protocolFeeBP) / BP_SCALE;
        DEPOSIT_TOKEN.transfer(feeRouterAddress, protocolFee);

        // [6] release funds to buyers ETH payout address
        DEPOSIT_TOKEN.transfer(swapReservation.ethPayoutAddress, swapReservation.totalSwapOutputAmount - protocolFee);

        emit SwapComplete(swapReservationIndex, swapReservation, protocolFee);
    }

    function proveBlocks(
        uint32 safeBlockHeight,
        uint64 proposedBlockHeight,
        uint64 confirmationBlockHeight,
        bytes32[] memory blockHashes,
        uint256[] memory blockChainworks,
        bytes calldata proof
    ) external {
        // [0] craft public inputs
        bytes memory publicInputs = abi.encode(
            buildPublicInputs(
                0,
                bytes32(0),
                bytes32(0),
                safeBlockHeight,
                proposedBlockHeight,
                confirmationBlockHeight,
                blockHashes,
                blockChainworks,
                false
            )
        );

        // [1] verify proof (will revert if invalid)
        VERIFIER_CONTRACT.verifyProof(CIRCUIT_VERIFICATION_KEY, publicInputs, proof);

        // [2] add verified blocks to block hash storage contract
        addBlock(safeBlockHeight, proposedBlockHeight, confirmationBlockHeight, blockHashes, blockChainworks);
    }

    // --------- ONLY OWNER --------- //
    function updateNewLiquidityDepositsPaused(bool newPauseState) external onlyOwner {
        isDepositNewLiquidityPaused = newPauseState;
    }

    function updateFeeRouter(address payable newProtocolAddress) public onlyOwner {
        // TODO: make this only fee router?
        feeRouterAddress = newProtocolAddress;
    }

    function updateProtocolFee(uint8 newProtocolFeeBP) public onlyOwner {
        protocolFeeBP = newProtocolFeeBP;
    }

    function addPermissionedHypernode(address hypernode) external onlyOwner {
        permissionedHypernodes[hypernode] = true;
    }

    function removePermissionedHypernode(address hypernode) external onlyOwner {
        permissionedHypernodes[hypernode] = false;
    }

    //--------- READ FUNCTIONS ---------//

    function getLiquidityProvider(address lpAddress) public view returns (LiquidityProvider memory) {
        return liquidityProviders[lpAddress];
    }

    function getDepositVaultsLength() public view returns (uint256) {
        return depositVaults.length;
    }

    function getDepositVaultUnreservedBalance(uint256 depositIndex) public view returns (uint256) {
        return depositVaults[depositIndex].unreservedBalance;
    }

    function getReservationLength() public view returns (uint256) {
        return swapReservations.length;
    }

    function getAreDepositsPaused() public view returns (bool) {
        return isDepositNewLiquidityPaused;
    }

    function getReservation(uint256 reservationIndex) public view returns (SwapReservation memory) {
        return swapReservations[reservationIndex];
    }

    function getDepositVault(uint256 depositIndex) public view returns (DepositVault memory) {
        return depositVaults[depositIndex];
    }

    //--------- INTERNAL FUNCTIONS ---------//

    function cleanUpDeadSwapReservations(uint256[] memory expiredSwapReservationIndexes) internal {
        verifyExpiredReservations(expiredSwapReservationIndexes);

        for (uint256 i = 0; i < expiredSwapReservationIndexes.length; i++) {
            // [0] verify reservations are expired

            // [1] extract reservation
            SwapReservation storage expiredSwapReservation = swapReservations[expiredSwapReservationIndexes[i]];

            // [2] add expired reservation amounts to deposit vaults
            for (uint256 j = 0; j < expiredSwapReservation.vaultIndexes.length; j++) {
                DepositVault storage expiredVault = depositVaults[expiredSwapReservation.vaultIndexes[j]];
                expiredVault.unreservedBalance += expiredSwapReservation.amountsToReserve[j];
            }

            // [3] mark as expired
            expiredSwapReservation.state = ReservationState.Expired;
        }
    }

    function verifyExpiredReservations(uint256[] memory expiredSwapReservationIndexes) internal view {
        for (uint256 i = 0; i < expiredSwapReservationIndexes.length; i++) {
            SwapReservation storage reservation = swapReservations[expiredSwapReservationIndexes[i]];

            // [0] skip if already marked as expired
            if (reservation.state == ReservationState.Expired) {
                continue;
            }

            // [1] ensure reservation is expired
            if (
                block.timestamp - reservation.reservationTimestamp < RESERVATION_LOCKUP_PERIOD ||
                reservation.state != ReservationState.Created
            ) {
                revert ReservationNotExpired();
            }
        }
    }

    function bufferTo18Decimals(uint256 amount, uint8 tokenDecimals) internal pure returns (uint256) {
        if (tokenDecimals < 18) {
            return amount * (10 ** (18 - tokenDecimals));
        }
        return amount;
    }

    function addDepositVaultIndexToLP(address lpAddress, uint256 vaultIndex) internal {
        liquidityProviders[lpAddress].depositVaultIndexes.push(vaultIndex);
    }
}
