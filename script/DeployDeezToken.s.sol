// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {DeezToken} from "../src/DeezToken.sol";

/// @title Deploy script for IMDeezNutz (DEEZ)
/// @notice The token has no constructor arguments, so there is nothing to configure: whoever
/// broadcasts `run()` receives the whole supply. On the IMD launch the factory deploys the
/// token from its bytecode instead and receives the supply itself; this script exists for
/// local and test-network deployments and is not used by that launch.
/// @dev `deploy()` is the function tests call directly. `run()` only wraps it in a broadcast and
/// reads nothing from the environment.
contract DeployDeezToken is Script {
    /// @notice Broadcasts the deployment with the signer `forge script` is given.
    function run() external returns (DeezToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }

    /// @notice Deploys a fresh token. The caller of this function's `new` receives the supply.
    function deploy() public returns (DeezToken token) {
        token = new DeezToken();
    }
}
