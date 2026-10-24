// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title IMDeezNutz (DEEZ)
/// @notice A fixed-supply ERC-20. The whole supply of 1,000,000,000 DEEZ (18 decimals) is minted
/// once, in the constructor, to the deployer. There is no owner, no minter, no pause, no
/// blacklist and no fee: after deployment nobody holds any privilege over the token, and the
/// supply can never grow.
/// @dev Behaviour is OpenZeppelin v5 `ERC20` plus `ERC20Permit` (EIP-2612 gasless approvals).
/// The constructor takes no arguments and calls no other contract, so it deploys on an empty chain
/// and from a factory: `msg.sender` at construction receives the supply. The contract name is the
/// Solidity identifier the launch records; the token's own name and symbol are the constants below.
contract DeezToken is ERC20, ERC20Permit {
    /// @notice The token name returned by `name()`.
    string public constant TOKEN_NAME = "IMDeezNutz";

    /// @notice The token symbol returned by `symbol()`.
    string public constant TOKEN_SYMBOL = "DEEZ";

    /// @notice The number of decimals returned by `decimals()`.
    uint8 public constant TOKEN_DECIMALS = 18;

    /// @notice The whole supply in minor units: one billion tokens with 18 decimals.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** TOKEN_DECIMALS;

    /// @notice Mints the entire fixed supply to the deployer (`msg.sender`).
    /// @dev Emits a single `Transfer(address(0), msg.sender, TOTAL_SUPPLY)`.
    constructor() ERC20(TOKEN_NAME, TOKEN_SYMBOL) ERC20Permit(TOKEN_NAME) {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
