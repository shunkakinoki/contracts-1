// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import 'forge-std/Test.sol';
import 'forge-std/console2.sol';
import 'murky/Merkle.sol';
import '../../../contracts/core/Governor.sol';
import '../../../contracts/core/Membership.sol';
import '../../../contracts/core/Share.sol';
import '../../../contracts/core/Treasury.sol';
import {Errors} from '../../../contracts/libraries/Errors.sol';
import {DataTypes} from '../../../contracts/libraries/DataTypes.sol';

contract Helpers is Test {
    address deployer = msg.sender;
    bool enableMembershipTransfer = false;
    uint256 initialSupply;

    Merkle m;
    address[] allowlistAddresses;
    address[] voters;
    bytes32[] leafNodes;
    bytes32 merkleRoot;
    bytes32[][] merkleProofs;
    bytes32[] badProof;

    Share share;
    Treasury treasury;
    Membership membership;
    TreasuryGovernor membershipGovernor;
    TreasuryGovernor shareGovernor;

    function setUpMerkle() public {
        m = new Merkle();
    }

    function generateProof(uint256 i) public {
        setUpMerkle();
        allowlistAddresses = new address[](i + 1);
        leafNodes = new bytes32[](i + 1);
        merkleProofs = new bytes32[][](i + 1);
        allowlistAddresses[0] = deployer;
        console2.log(allowlistAddresses[0]);

        for (uint256 j = 1; j < i; j++) {
            allowlistAddresses[j] = address(uint160(j));
        }

        for (uint256 k = 0; k < allowlistAddresses.length; k++) {
            leafNodes[k] = keccak256(abi.encodePacked(allowlistAddresses[k]));
        }

        merkleRoot = m.getRoot(leafNodes);

        bytes32[] memory data = leafNodes;
        for (uint256 k = 0; k < allowlistAddresses.length; k++) {
            bytes32[] memory proof = m.getProof(data, k);
            merkleProofs[k] = proof;
        }

        voters = allowlistAddresses;
    }

    function setUpProof() public {
        generateProof(4);
        bytes32[] memory data = leafNodes;
        badProof = m.getProof(data, allowlistAddresses.length);
    }

    function contractsReady() public {
        membership = new Membership(
            DataTypes.BaseToken({name: 'CodeforDAO', symbol: 'CODE'}),
            'https://codefordao.org/member/',
            'https://codefordao.org/membership/'
        );
        share = new Share('CodeforDAOShare', 'CFD');
        treasury = new Treasury(
            1,
            address(membership),
            address(share),
            DataTypes.InvestmentSettings(
                true,
                1,
                2,
                new address[](0),
                new uint256[](0),
                new uint256[](0)
            )
        );
        if (initialSupply > 0) {
            share.mint(address(treasury), 1_000_000);
            treasury.updateShareSplit(DataTypes.ShareSplit(20, 10, 30, 40));
        }
        membership.grantRole(keccak256('DEFAULT_ADMIN_ROLE'), address(treasury));

        share.grantRole(keccak256('DEFAULT_ADMIN_ROLE'), address(treasury));
        share.grantRole(keccak256('MINTER_ROLE'), address(treasury));
        share.grantRole(keccak256('PAUSER_ROLE'), address(treasury));
        share.revokeRole(keccak256('DEFAULT_ADMIN_ROLE'), deployer);
        share.revokeRole(keccak256('MINTER_ROLE'), deployer);
        share.revokeRole(keccak256('PAUSER_ROLE'), deployer);

        // All membership NFT is set to be non-transferable by default
        if (!enableMembershipTransfer) {
            membership.pause();
        }
        membership.revokeRole(keccak256('PAUSER_ROLE'), deployer);

        membershipGovernor = new TreasuryGovernor(
            string.concat(membership.name(), '-MembershipGovernor'),
            address(membership),
            treasury,
            DataTypes.GovernorSettings(0, 2, 3, 1)
        );
        shareGovernor = new TreasuryGovernor(
            string.concat(membership.name(), '-ShareGovernor'),
            address(share),
            treasury,
            DataTypes.GovernorSettings(1000, 10000, 4, 100)
        );
        treasury.grantRole(keccak256('PROPOSER_ROLE'), address(membershipGovernor));
        treasury.grantRole(keccak256('PROPOSER_ROLE'), address(shareGovernor));
        membership.setupGovernor(
            address(share),
            address(treasury),
            address(membershipGovernor),
            address(shareGovernor)
        );
        membership.revokeRole(keccak256('DEFAULT_ADMIN_ROLE'), deployer);
    }

    function membershipMintAndDelegate() public {
        membership.updateAllowlist(merkleRoot);
        // Minus 1 loop for the deployer address
        for (uint256 i = 0; i < merkleProofs.length - 1; i++) {
            vm.prank(allowlistAddresses[i]);
            membership.mint(merkleProofs[i]);
            vm.prank(allowlistAddresses[i]);
            membership.delegate(allowlistAddresses[i]);
        }
    }

    function testDeployer() public {
        contractsReady();
        // Should default to default foundry `msg.sender` value
        assertEq(deployer, address(0x00a329c0648769A73afAc7F9381E08FB43dBEA72));
    }

    function testGenerateProofFixed() public {
        setUpProof();
        for (uint256 i = 0; i < 4 + 1; i++) {
            bytes32 valueToProve = keccak256(abi.encodePacked(allowlistAddresses[i]));
            assertTrue(m.verifyProof(merkleRoot, merkleProofs[i], valueToProve));
        }
    }

    // governor.js deployment check
    function testGovernorDeploymentCheck() public {
        setUpProof();
        contractsReady();
        membershipMintAndDelegate();
        // Make sure membership governor works properly
        assertEq(membershipGovernor.name(), 'CodeforDAO-MembershipGovernor');
        assertEq(address(membershipGovernor.token()), address(membership));
        assertEq(membershipGovernor.votingDelay(), 0);
        assertEq(membershipGovernor.votingPeriod(), 2);
        assertEq(membershipGovernor.proposalThreshold(), 1);
        assertEq(membershipGovernor.quorum(0), 0);
        assertEq(membershipGovernor.timelock(), address(treasury));
        // Make sure share governor works properly
        assertEq(shareGovernor.name(), 'CodeforDAO-ShareGovernor');
        assertEq(address(shareGovernor.token()), address(membership.shareToken()));
        assertEq(shareGovernor.votingDelay(), 1000);
        assertEq(shareGovernor.votingPeriod(), 10_000);
        assertEq(shareGovernor.proposalThreshold(), 100);
        assertEq(shareGovernor.quorum(0), 0);
        assertEq(shareGovernor.timelock(), address(treasury));

        // herlpers.js membershipMintAndDelegate
        // Minus 1 loop for the deployer address
        for (uint256 i = 0; i < voters.length - 1; i++) {
            assertEq(membership.balanceOf(voters[i]), 1);
            assertEq(membership.getVotes(voters[i]), 1);
        }
    }

    // membership.js deployment check
    function testMembershipDeploymentCheck() public {
        contractsReady();
        // Should bind a membership governor (1/1) contract
        assertEq(membership.governor(), address(membershipGovernor));
        // Should bind a share token (ERC20) contract
        assertEq(membership.shareToken(), address(share));
        assertEq(share.name(), 'CodeforDAOShare');
        assertEq(share.symbol(), 'CFD');
        // Should bind a share governor (ERC20 IVotes) contract
        assertEq(membership.shareGovernor(), address(shareGovernor));
        // Should bind a treasury (timelock) contract
        assertEq(membershipGovernor.timelock(), address(treasury));
    }

    // treasury.js deployment check
    function testTreasuryDeploymentCheck() public {
        contractsReady();
        // Should created with related contracts
        assertEq(treasury.share(), membership.shareToken());
        assertEq(treasury.membership(), address(membership));
    }
}
