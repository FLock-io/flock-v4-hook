// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {BaseTest} from "../utils/BaseTest.sol";
import {RobinhoodV4} from "../../src/libraries/RobinhoodV4.sol";
import {RebalanceCoreScript} from "../../script/06_RebalanceCore.s.sol";

interface IERC721Min {
    function ownerOf(uint256 tokenId) external view returns (address);
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

/// @notice Fork check: the current NFT owner can move the three LP positions to another Safe, and script 06 then
///         builds a batch the new owner can execute.
/// @dev forge test --match-contract TransferPositionsFork --fork-url robinhood
contract TransferPositionsFork is BaseTest {
    address constant HOOK = 0x33e924fb8663871bAb61D6844e79CDea159C60c0;
    address constant FROM = RobinhoodV4.FLOCK_SAFE;
    address constant TO = 0xD0d40326aA8eb62B28441B0b73B8cD92DF475ea3;
    uint256[3] tokenIds = [uint256(1700129), 1701667, 1701445];

    modifier onlyFork() {
        if (block.chainid != RobinhoodV4.CHAIN_ID || HOOK.code.length == 0) return;
        _;
    }

    function setUp() public {
        if (block.chainid != RobinhoodV4.CHAIN_ID || HOOK.code.length == 0) return;
        deployArtifactsAndLabel();
        vm.setEnv("HOOK_ADDRESS", vm.toString(HOOK));
        vm.setEnv("CORE_TOKEN_ID", vm.toString(tokenIds[2]));
    }

    function test_transferThenRebalanceFromNewOwner() public onlyFork {
        IERC721Min pm = IERC721Min(address(positionManager));
        for (uint256 i = 0; i < 3; i++) {
            assertEq(pm.ownerOf(tokenIds[i]), FROM);
            vm.prank(FROM);
            pm.safeTransferFrom(FROM, TO, tokenIds[i]); // TO is a Safe: its fallback handler accepts ERC721
            assertEq(pm.ownerOf(tokenIds[i]), TO);
        }
        RebalanceCoreScript s = new RebalanceCoreScript();
        (RebalanceCoreScript.Plan memory p, RebalanceCoreScript.Tx[] memory txs) = s.build();
        assertEq(p.owner, TO, "plan follows the new owner");
        uint256 farId = positionManager.nextTokenId();
        for (uint256 i = 0; i < txs.length; i++) {
            vm.prank(TO);
            (bool ok,) = txs[i].to.call(txs[i].data);
            require(ok, txs[i].name);
        }
        assertEq(pm.ownerOf(farId), TO, "far band minted to the new owner");
        assertGt(positionManager.getPositionLiquidity(farId), 0);
    }
}
