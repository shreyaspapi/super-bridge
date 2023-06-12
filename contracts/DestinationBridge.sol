// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.17;

import {IXReceiver} from "@connext/interfaces/core/IXReceiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISuperfluid, ISuperToken} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

contract DestinationBridge is IXReceiver {
    struct SubscriptionData {
        address addr;
        int96 streamRate;
    }

    SubscriptionData[] public subscribersDataList;
    
    bytes32 public merkleRoot;
    mapping(bytes32 => bool) private tree;

    // The token to be paid on this domain
    IERC20 public immutable acceptedToken;
    ISuperfluid public immutable acceptedSuperToken;

    constructor(bytes32 _merkleRoot, address _token, ISuperfluid _acceptedSuperToken) {
        merkleRoot = _merkleRoot;
        acceptedToken = IERC20(_token);
        acceptedSuperToken = _acceptedSuperToken;
    }

    /** @notice The receiver function as required by the IXReceiver interface.
    * @dev The Connext bridge contract will call this function.
    */
    function xReceive(
        bytes32 _transferId,
        uint256 _amount,
        address _asset,
        address _originSender,
        uint32 _origin,
        bytes memory _callData
    ) external override returns (bytes memory) {
        // Check for the right token
        require(_asset == address(acceptedToken), "Wrong asset received");

        // Unpack the _callData
        bytes32 newMerkleRoot = abi.decode(_callData, (bytes32));

        // Update the merkleRoot
        merkleRoot = newMerkleRoot;

        return "";
    }

    function addSubscribersDataList(SubscriptionData[] memory _subscribersDataList) external {
        // append the list to the existing list
        for (uint256 i = 0; i < _subscribersDataList.length; i++) {
            subscribersDataList.push(_subscribersDataList[i]);
        }
        // Recalculate the Merkle root
        require(calculateMerkleRoot() == merkleRoot, "Incorrect list");

        // TODO: Add code here for IDA and distribute
    }

    function calculateMerkleRoot() private returns (bytes32) {
        // Create an array to store the leaf nodes
        bytes32[] memory leaves = new bytes32[](subscribersDataList.length);

        // Generate the leaf nodes
        for (uint256 i = 0; i < subscribersDataList.length; i++) {
            bytes32 leaf = keccak256(
                abi.encodePacked(
                    subscribersDataList[i].addr,
                    subscribersDataList[i].streamRate
                )
            );
            leaves[i] = leaf;
            tree[leaf] = true;
        }

        // Calculate the Merkle root from the leaf nodes
        bytes32 root = generateMerkleRoot(leaves);
        return root;
    }

    function generateMerkleRoot(bytes32[] memory leaves) private pure returns (bytes32) {
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
