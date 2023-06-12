// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.17;

import {SuperTokenV1Library} from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperTokenV1Library.sol";
import {SuperAppBaseCFA} from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperAppBaseCFA.sol";
import {ISuperfluid, ISuperToken} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

import {IConnext} from "@connext/interfaces/core/IConnext.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract SourceBridge is SuperAppBaseCFA {
    /// @dev super token library
    using SuperTokenV1Library for ISuperToken;

    struct SubscriptionData {
        address addr;
        int96 streamRate;
    }

    /// @dev Super token that may be streamed to this contract
    ISuperToken public immutable acceptedSuperToken;
    IERC20 public immutable acceptedToken;

    // The Connext contract on this domain
    IConnext public immutable connext;

    // Slippage (in BPS) for the transfer set to 10%
    uint256 public immutable slippage = 1000;

    SubscriptionData[] public subscribersDataList;
    bytes32 public merkleRoot;

    constructor(
        ISuperfluid _host,
        ISuperToken _acceptedSuperToken,
        address _connext
    ) SuperAppBaseCFA(_host, true, true, true) {
        acceptedSuperToken = _acceptedSuperToken;
        connext = IConnext(_connext);

        acceptedToken = IERC20(acceptedSuperToken.getUnderlyingToken());
    }

    // ---------------------------------------------------------------------------------------------
    // MODIFIERS

    ///@dev checks that only the acceptedToken is used when sending streams into this contract
    ///@param superToken the token being streamed into the contract
    function isAcceptedSuperToken(
        ISuperToken superToken
    ) public view override returns (bool) {
        return superToken == acceptedSuperToken;
    }

    // ---------------------------------------------------------------------------------------------
    // CONNEXT

    /** @notice Allows the transfer of funds from the current chain to the destination chain using Connext protocol.
     * @param target The address of the target contract on the destination chain.
     * @param destinationDomain Domain ID of the destination chain.
     * @param relayerFee The fee amount to be paid to the relayer.
     */
    function xBridgeFunds(
        address target,
        uint32 destinationDomain,
        uint256 relayerFee
    ) external payable {
        acceptedSuperToken.downgrade(
            acceptedSuperToken.balanceOf(address(this))
        );

        uint256 tokenAmount = acceptedToken.balanceOf(address(this));

        // This contract approves transfer to Connext
        acceptedToken.approve(address(connext), tokenAmount);

        // Encode calldata for the target contract call
        bytes memory callData = abi.encode(merkleRoot);

        connext.xcall{value: relayerFee}(
            destinationDomain, // _destination: Domain ID of the destination chain
            target, // _to: address of the target contract
            address(acceptedToken), // _asset: address of the token contract
            msg.sender, // _delegate: address that can revert or forceLocal on destination
            tokenAmount, // _amount: amount of tokens to transfer
            slippage, // _slippage: max slippage the user will accept in BPS (e.g. 300 = 3%)
            callData // _callData: the encoded calldata to send
        );
    }

    // ---------------------------------------------------------------------------------------------
    // CALLBACK LOGIC

    function onFlowCreated(
        ISuperToken /*superToken*/,
        address sender,
        bytes calldata ctx
    ) internal override returns (bytes memory /*newCtx*/) {
        int96 stremRate = acceptedSuperToken.getFlowRate(sender, address(this));
        addData(sender, stremRate);

        return ctx;
    }

    function onFlowUpdated(
        ISuperToken /*superToken*/,
        address sender,
        int96 /*previousFlowRate*/,
        uint256 /*lastUpdated*/,
        bytes calldata ctx
    ) internal override returns (bytes memory /*newCtx*/) {
        int96 streamRate = acceptedSuperToken.getFlowRate(
            sender,
            address(this)
        );
        addData(sender, streamRate);

        return ctx;
    }

    function onFlowDeleted(
        ISuperToken /*superToken*/,
        address sender,
        address /*receiver*/,
        int96 /*previousFlowRate*/,
        uint256 /*lastUpdated*/,
        bytes calldata ctx
    ) internal override returns (bytes memory /*newCtx*/) {
        addData(sender, 0);

        return ctx;
    }

    // ---------------------------------------------------------------------------------------------
    // MERKLE LOGIC

    function addData(address _addr, int96 _streamRate) public {
        SubscriptionData memory newData = SubscriptionData(_addr, _streamRate);
        subscribersDataList.push(newData);

        // Recalculate the Merkle root
        merkleRoot = calculateMerkleRoot();
    }

    function calculateMerkleRoot() private view returns (bytes32) {
        // Create an array to store the leaf nodes
        bytes32[] memory leaves = new bytes32[](subscribersDataList.length);

        // Generate the leaf nodes
        for (uint256 i = 0; i < subscribersDataList.length; i++) {
            leaves[i] = keccak256(
                abi.encodePacked(
                    subscribersDataList[i].addr,
                    subscribersDataList[i].streamRate
                )
            );
        }

        // Calculate the Merkle root from the leaf nodes
        bytes32 root = generateMerkleRoot(leaves);
        return root;
    }

    function generateMerkleRoot(
        bytes32[] memory leaves
    ) private pure returns (bytes32) {
        uint256 numLeaves = leaves.length;
        bytes32[] memory nodes = new bytes32[](numLeaves);

        // Copy leaf nodes to the nodes array
        for (uint256 i = 0; i < numLeaves; i++) {
            nodes[i] = leaves[i];
        }

        // Generate intermediate nodes
        for (uint256 level = 0; level < ceilLog2(numLeaves); level++) {
            uint256 levelSize = nodes.length;
            uint256 nextLevelSize = ceilDiv(levelSize, 2);
            bytes32[] memory temp = new bytes32[](nextLevelSize);

            for (uint256 i = 0; i < levelSize; i += 2) {
                bytes32 left = nodes[i];
                bytes32 right;

                if (i + 1 < levelSize) {
                    right = nodes[i + 1];
                } else {
                    right = nodes[i];
                }

                bytes32 parent = keccak256(abi.encodePacked(left, right));
                temp[i / 2] = parent;
            }

            nodes = temp;
        }

        return nodes[0];
    }

    function ceilLog2(uint256 x) private pure returns (uint256) {
        uint256 result = 0;
        uint256 val = x;

        while (val > 0) {
            val /= 2;
            result++;
        }

        return result;
    }

    function ceilDiv(uint256 a, uint256 b) private pure returns (uint256) {
        return (a + b - 1) / b;
    }
}
