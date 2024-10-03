// SPDX-License-Identifier: Unlicensed
pragma solidity ^0.8.2;

import { console } from "forge-std/console.sol";
import { Owned } from "../lib/solmate/src/auth/Owned.sol";

error InvalidPartitionLayout();
error NotManager();
error MismatchOwnersPercentages();
error InsufficientManagers();
error TotalPercentageInvalid();
error NoAllowanceForTransfer();
error TokenTransferFailed();
error InvalidAddress();
error ProposalAlreadyExecuted();
error AlreadyApproved();
error NotEnoughApprovals();

interface IERC20 {
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);

    function transfer(address recipient, uint256 amount) external returns (bool);

    function balanceOf(address account) external view returns (uint256);

    function allowance(address owner, address spender) external view returns (uint256);

    function approve(address spender, uint256 amount) external returns (bool);

    function decimals() external view returns (uint8);
}

contract FeeRouter is Owned {
    IERC20 public immutable DEPOSIT_TOKEN;

    struct Partition {
        address owner;
        uint256 percentage; // in basis points
        bool isManager;
    }

    struct Proposal {
        Partition[] newPartitions;
        uint256 approvalCount;
        mapping(address => bool) hasApproved;
        bool executed;
    }

    Partition[] public partitions;
    uint256 public totalReceived;
    uint256 constant BP_SCALE = 10000;
    uint256 public proposalCount;
    uint256 public totalManagers;
    mapping(uint256 => Proposal) public proposals;
    mapping(address => address) public approvedReferredEthAddresses;
    mapping(address => address) public approvedReferredBTCAddresses;

    // ----------- MODIFIERS ----------- //
    modifier onlyManager() {
        if (!isManager(msg.sender)) revert NotManager();
        _;
    }

    // ----------- CONSTRUCTOR ----------- //

    constructor(
        address _owner,
        address[] memory _partitionOwners,
        uint256[] memory _percentages,
        bool[] memory _isManager,
        address _depositToken
    ) Owned(_owner) {
        if (_partitionOwners.length != _percentages.length) revert MismatchOwnersPercentages();
        uint256 totalPercentage = 0;
        for (uint256 i = 0; i < _partitionOwners.length; i++) {
            totalPercentage += _percentages[i];
            partitions.push(Partition(_partitionOwners[i], _percentages[i], _isManager[i]));
            if (_isManager[i]) {
                totalManagers += 1;
            }
        }
        if (totalManagers < 1) revert InsufficientManagers();
        if (totalPercentage != BP_SCALE) revert TotalPercentageInvalid();
        DEPOSIT_TOKEN = IERC20(_depositToken);
    }

    // ----------- MAIN FUNCTION ----------- //

    function receiveFees(address swapperEthAddress, address swapperBtcAddress) public {
        // [0] transfer tokens to contract
        uint256 amount = DEPOSIT_TOKEN.allowance(msg.sender, address(this));
        if (amount == 0) revert NoAllowanceForTransfer();
        if (!DEPOSIT_TOKEN.transferFrom(msg.sender, address(this), amount)) revert TokenTransferFailed();

        uint256 remainingAmount = amount;

        // [1] handle referral fees (ETH swapper)
        if (approvedReferredEthAddresses[swapperEthAddress] != address(0)) {
            address ethReferrer = approvedReferredEthAddresses[swapperEthAddress];
            uint256 ethReferralFee = amount / 2;
            if (!DEPOSIT_TOKEN.transfer(ethReferrer, ethReferralFee)) revert TokenTransferFailed();
            remainingAmount -= ethReferralFee;
        }

        // [2] handle referral fees (BTC swapper)
        if (approvedReferredBTCAddresses[swapperBtcAddress] != address(0)) {
            address btcReferrer = approvedReferredBTCAddresses[swapperBtcAddress];
            uint256 btcReferralFee = amount / 2;
            if (!DEPOSIT_TOKEN.transfer(btcReferrer, btcReferralFee)) revert TokenTransferFailed();
            remainingAmount -= btcReferralFee;
        }

        // [3] divide remaining amount amongst partitions
        uint256 totalDistributed = 0;
        for (uint256 i = 0; i < partitions.length; i++) {
            uint256 partitionAmount = (remainingAmount * partitions[i].percentage) / BP_SCALE;
            totalDistributed += partitionAmount;
            if (!DEPOSIT_TOKEN.transfer(partitions[i].owner, partitionAmount)) revert TokenTransferFailed();
        }

        // [4] handle leftover tokens
        uint256 leftover = remainingAmount - totalDistributed;
        if (leftover > 0) {
            // allocate leftover to the last partition owner
            address lastPartitionOwner = partitions[partitions.length - 1].owner;
            if (!DEPOSIT_TOKEN.transfer(lastPartitionOwner, leftover)) revert TokenTransferFailed();
        }

        totalReceived += amount;
    }

    // ----------- MANAGER FUNCTIONS ----------- //

    function addApprovedEthReferrer(address swapperEthAddress, address payoutEthAddress) external onlyManager {
        if (swapperEthAddress == address(0) || payoutEthAddress == address(0)) revert InvalidAddress();
        approvedReferredEthAddresses[swapperEthAddress] = payoutEthAddress;
    }

    function removeApprovedBtcReferrer(address swapperBtcAddress) external onlyManager {
        if (swapperBtcAddress == address(0)) revert InvalidAddress();
        delete approvedReferredBTCAddresses[swapperBtcAddress];
    }

    function removeApprovedEthReferrer(address swapperEthAddress) external onlyManager {
        if (swapperEthAddress == address(0)) revert InvalidAddress();
        delete approvedReferredEthAddresses[swapperEthAddress];
    }

    function addApprovedBtcReferrer(address swapperBtcAddress, address payoutEthAddress) external onlyManager {
        if (swapperBtcAddress == address(0) || payoutEthAddress == address(0)) revert InvalidAddress();
        approvedReferredBTCAddresses[swapperBtcAddress] = payoutEthAddress;
    }

    function proposeNewPartitionLayout(Partition[] memory _newPartitions) public onlyManager {
        if (!validateNewPartitions(_newPartitions)) revert InvalidPartitionLayout();

        proposalCount++;
        Proposal storage newProposal = proposals[proposalCount];
        uint256 newTotalManagers = 0;

        for (uint256 i = 0; i < _newPartitions.length; i++) {
            if (_newPartitions[i].isManager) {
                newTotalManagers += 1;
            }
            newProposal.newPartitions.push(_newPartitions[i]);
        }
        if (newTotalManagers < 1) revert InsufficientManagers();

        newProposal.approvalCount = 1;
        newProposal.hasApproved[msg.sender] = true;

        if (newProposal.approvalCount == totalManagers) {
            executeProposal(proposalCount);
        }
    }

    function approveProposal(uint256 _proposalId) public onlyManager {
        Proposal storage proposal = proposals[_proposalId];
        if (proposal.executed) revert ProposalAlreadyExecuted();
        if (proposal.hasApproved[msg.sender]) revert AlreadyApproved();

        proposal.approvalCount++;
        proposal.hasApproved[msg.sender] = true;

        if (proposal.approvalCount == totalManagers) {
            executeProposal(_proposalId);
        }
    }

    // ----------- INTERNAL FUNCTIONS ----------- //

    function executeProposal(uint256 _proposalId) internal {
        Proposal storage proposal = proposals[_proposalId];
        if (proposal.executed) revert ProposalAlreadyExecuted();
        if (proposal.approvalCount < totalManagers) revert NotEnoughApprovals();

        delete partitions;
        uint256 newTotalManagers = 0;
        for (uint256 i = 0; i < proposal.newPartitions.length; i++) {
            partitions.push(proposal.newPartitions[i]);
            if (proposal.newPartitions[i].isManager) {
                newTotalManagers++;
            }
        }
        totalManagers = newTotalManagers;

        proposal.executed = true;
    }

    function isManager(address _address) internal view returns (bool) {
        for (uint256 i = 0; i < partitions.length; i++) {
            if (partitions[i].owner == _address && partitions[i].isManager) {
                return true;
            }
        }
        return false;
    }

    function validateNewPartitions(Partition[] memory _newPartitions) internal pure returns (bool) {
        uint256 totalPercentage = 0;
        uint256 managerCount = 0;
        for (uint256 i = 0; i < _newPartitions.length; i++) {
            totalPercentage += _newPartitions[i].percentage;
            if (_newPartitions[i].isManager) {
                managerCount++;
            }
        }
        return totalPercentage == BP_SCALE && managerCount >= 1;
    }
}
