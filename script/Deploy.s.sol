// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";

import {KingToken} from "../src/KingToken.sol";
import {KingHook} from "../src/KingHook.sol";
import {HookFlags} from "../src/HookFlags.sol";

/// @title Deploy
/// @notice Reference deployment of the KING launch: token, hook at a mined address, pool.
/// @dev The launch factory performs the real deployment from `launch.json`; this script documents
/// the same steps for a rehearsal. `run()` reads the PoolManager from the environment and hands it
/// to `deploy()`, which tests call directly with their own PoolManager.
contract Deploy is Script {
    /// @notice sqrtPriceX96 for 1e8 KING per ETH: 1e9 KING at 1e-8 ETH each is a 10 ETH market cap.
    uint160 public constant INITIAL_SQRT_PRICE = 792281625142643375935439503360000;
    uint24 public constant LP_FEE = 3000;
    int24 public constant TICK_SPACING = 60;

    struct Deployment {
        KingToken token;
        KingHook hook;
        bytes32 salt;
        PoolKey key;
    }

    /// @dev Deploys with the broadcasting account (CREATE2 through forge's deterministic deployer).
    function run() external returns (Deployment memory d) {
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        address create2Deployer = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        vm.startBroadcast();
        d = deploy(poolManager, create2Deployer);
        vm.stopBroadcast();
    }

    /// @notice Deploys the token and the hook, then initializes the pool at the launch price.
    /// @param poolManager The chain's Uniswap v4 PoolManager.
    /// @param create2Deployer The address that will execute CREATE2 for the hook (the caller when
    /// deploying from a contract, forge's deterministic deployer when broadcasting).
    function deploy(IPoolManager poolManager, address create2Deployer) public returns (Deployment memory d) {
        d.token = new KingToken();
        bytes memory creationCode =
            abi.encodePacked(type(KingHook).creationCode, abi.encode(poolManager, address(d.token)));
        (address predicted, bytes32 salt) =
            HookFlags.mine(create2Deployer, HookFlags.KING_HOOK_FLAGS, creationCode, 1_000_000);
        d.salt = salt;
        d.hook = new KingHook{salt: salt}(poolManager, address(d.token));
        require(address(d.hook) == predicted, "Deploy: hook address mismatch");

        d.key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(d.token)),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(d.hook))
        });
        poolManager.initialize(d.key, INITIAL_SQRT_PRICE);
    }
}
