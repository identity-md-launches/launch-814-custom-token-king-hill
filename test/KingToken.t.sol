// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {KingToken} from "../src/KingToken.sol";

contract KingTokenTest is Test {
    KingToken token;

    function setUp() public {
        token = new KingToken();
    }

    function test_metadata() public view {
        assertEq(token.name(), "KING");
        assertEq(token.symbol(), "KING");
        assertEq(token.decimals(), 18);
    }

    function test_mintsTheWholeSupplyToTheDeployer() public view {
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
    }

    function test_transferMovesExactlyWhatItWasAsked() public {
        address to = makeAddr("to");
        uint256 before = token.balanceOf(address(this));
        assertTrue(token.transfer(to, 1_234 ether));
        assertEq(token.balanceOf(to), 1_234 ether);
        assertEq(token.balanceOf(address(this)), before - 1_234 ether);
        assertEq(token.totalSupply(), 10 ** 27);
    }

    function test_transferFromRespectsAllowance() public {
        address spender = makeAddr("spender");
        token.approve(spender, 5 ether);
        vm.prank(spender);
        vm.expectRevert();
        token.transferFrom(address(this), spender, 6 ether);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), spender, 5 ether));
        assertEq(token.balanceOf(spender), 5 ether);
    }

    function test_noAdminOrMintSurface() public {
        string[12] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "burn(address,uint256)",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()",
            "unpause()",
            "setMinter(address)"
        ];
        uint256 supply = token.totalSupply();
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], address(0xBEEF), type(uint128).max);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), supply, signatures[i]);
        }
    }

    function test_runtimeCodeHasNoDelegatecallOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4 && op != 0xF2 && op != 0xFF, "forbidden opcode");
        }
    }
}
