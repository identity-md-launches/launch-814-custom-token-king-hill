// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

import {Deploy} from "../script/Deploy.s.sol";
import {HookFlags} from "../src/HookFlags.sol";

contract DeployTest is Test {
    using StateLibrary for IPoolManager;

    function test_deployFunctionProducesALaunchReadyPool() public {
        PoolManager manager = new PoolManager(address(this));
        Deploy script = new Deploy();
        // The script contract executes CREATE2 itself, so it is the deployer the salt is mined for.
        Deploy.Deployment memory d = script.deploy(IPoolManager(address(manager)), address(script));

        assertEq(d.token.totalSupply(), 1e27);
        assertEq(d.token.balanceOf(address(script)), 1e27, "the deployer holds the supply, as the factory will");
        assertEq(HookFlags.flagsOf(address(d.hook)), HookFlags.KING_HOOK_FLAGS);
        assertEq(address(d.hook.poolManager()), address(manager));
        assertEq(address(d.hook.token()), address(d.token));
        assertTrue(d.hook.initialized());
        assertEq(d.hook.launchTime(), block.timestamp);
        assertEq(Currency.unwrap(d.key.currency0), address(0));
        assertEq(Currency.unwrap(d.key.currency1), address(d.token));
        assertEq(d.key.fee, 3000);
        assertEq(d.key.tickSpacing, 60);

        (uint160 sqrtPriceX96, int24 tick,,) = IPoolManager(address(manager)).getSlot0(d.key.toId());
        assertEq(sqrtPriceX96, 792281625142643375935439503360000);
        assertEq(tick, 184216, "1e8 KING per ETH: a 10 ETH market cap for 1e9 KING");
    }
}
