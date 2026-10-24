// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {DeezToken} from "src/DeezToken.sol";

/// @notice Four holders exercise the real token. Expected state is derived only from
/// authorized inputs, never copied from the token's getters after an operation.
contract DeezTokenHandler is Test {
    uint256 public constant ACTOR_COUNT = 4;
    uint256 internal constant SUPPLY = 1e27;
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    DeezToken public immutable token;
    address[4] public actors;
    uint256[4] internal actorKeys;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;
    mapping(address => uint256) public expectedNonce;

    uint256 public nonzeroTransfers;
    uint256 public successfulPermits;
    uint256 public expectedReverts;

    constructor() {
        for (uint256 i; i < ACTOR_COUNT; ++i) {
            (actors[i], actorKeys[i]) = makeAddrAndKey(string.concat("stateful-holder-", vm.toString(i)));
            expectedBalance[actors[i]] = SUPPLY / ACTOR_COUNT;
        }
        vm.prank(actors[0]);
        token = new DeezToken();
        for (uint256 i = 1; i < ACTOR_COUNT; ++i) {
            vm.prank(actors[0]);
            assertTrue(token.transfer(actors[i], SUPPLY / ACTOR_COUNT));
        }
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 amount = _amount(amountSeed, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        _move(from, to, amount);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 valueSeed) external {
        _approve(_actor(ownerSeed), _actor(spenderSeed), _approval(valueSeed));
    }

    /// @dev Use existing allowance: do not silently reapprove a revoked allowance.
    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 authorized = expectedAllowance[owner][spender];
        uint256 balance = expectedBalance[owner];
        uint256 amount = _amount(amountSeed, authorized < balance ? authorized : balance);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        if (authorized != type(uint256).max) expectedAllowance[owner][spender] = authorized - amount;
        _move(owner, to, amount);
    }

    /// @dev Tokens held by the token contract remain part of supply accounting.
    /// It is a passive recipient, never impersonated as a caller by this harness.
    function donateToToken(uint256 ownerSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        uint256 amount = _amount(amountSeed, expectedBalance[owner]);
        vm.prank(owner);
        assertTrue(token.transfer(address(token), amount));
        _move(owner, address(token), amount);
    }

    function permit(uint256 ownerSeed, uint256 spenderSeed, uint256 valueSeed) external {
        uint256 ownerIndex = ownerSeed % ACTOR_COUNT;
        address owner = actors[ownerIndex];
        address spender = _actor(spenderSeed);
        uint256 value = _approval(valueSeed);
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(actorKeys[ownerIndex], _digest(owner, spender, value, expectedNonce[owner]));
        token.permit(owner, spender, value, type(uint256).max, v, r, s);
        expectedAllowance[owner][spender] = value;
        ++expectedNonce[owner];
        ++successfulPermits;
    }

    function permitThenReplay(uint256 ownerSeed, uint256 spenderSeed, uint256 valueSeed) external {
        uint256 ownerIndex = ownerSeed % ACTOR_COUNT;
        address owner = actors[ownerIndex];
        address spender = _actor(spenderSeed);
        uint256 value = _approval(valueSeed);
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(actorKeys[ownerIndex], _digest(owner, spender, value, expectedNonce[owner]));
        token.permit(owner, spender, value, type(uint256).max, v, r, s);
        expectedAllowance[owner][spender] = value;
        ++expectedNonce[owner];
        ++successfulPermits;
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        token.permit(owner, spender, value, type(uint256).max, v, r, s);
        ++expectedReverts;
    }

    function rejectWrongSigner(uint256 ownerSeed, uint256 spenderSeed, uint256 value) external {
        uint256 ownerIndex = ownerSeed % ACTOR_COUNT;
        uint256 wrongIndex = (ownerIndex + 1) % ACTOR_COUNT;
        address owner = actors[ownerIndex];
        address spender = _actor(spenderSeed);
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(actorKeys[wrongIndex], _digest(owner, spender, value, expectedNonce[owner]));
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, actors[wrongIndex], owner));
        token.permit(owner, spender, value, type(uint256).max, v, r, s);
        ++expectedReverts;
    }

    function rejectOverdraw(uint256 ownerSeed, uint256 toSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 balance = expectedBalance[owner];
        uint256 amount = bound(amountSeed, balance + 1, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount));
        vm.prank(owner);
        token.transfer(to, amount);
        ++expectedReverts;
    }

    function rejectOverspend(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 allowanceSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 allowance = bound(allowanceSeed, 0, SUPPLY);
        _approve(owner, spender, allowance);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowance, allowance + 1)
        );
        vm.prank(spender);
        token.transferFrom(owner, to, allowance + 1);
        ++expectedReverts;
    }

    function rejectDelegatedOverdraw(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, bool infinite) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 balance = expectedBalance[owner];
        uint256 amount = balance + 1;
        _approve(owner, spender, infinite ? type(uint256).max : amount);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount));
        vm.prank(spender);
        token.transferFrom(owner, to, amount);
        ++expectedReverts;
    }

    function rejectZeroReceiver(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 amount = _amount(amountSeed, expectedBalance[owner]);
        _approve(owner, spender, amount);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(owner, address(0), amount);
        ++expectedReverts;
    }

    function _approve(address owner, address spender, uint256 value) internal {
        vm.prank(owner);
        assertTrue(token.approve(spender, value));
        expectedAllowance[owner][spender] = value;
    }

    function _move(address from, address to, uint256 amount) internal {
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
        if (amount > 0 && from != to) ++nonzeroTransfers;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % ACTOR_COUNT];
    }

    /// @dev Deliberately exercise zero, one minor unit and the full available balance.
    function _amount(uint256 seed, uint256 cap) internal pure returns (uint256) {
        uint256 edge = seed % 4;
        if (edge == 0) return 0;
        if (edge == 1) return cap == 0 ? 0 : 1;
        if (edge == 2) return cap;
        return bound(seed, 0, cap);
    }

    function _approval(uint256 seed) internal pure returns (uint256) {
        uint256 edge = seed % 5;
        if (edge == 0) return 0;
        if (edge == 1) return 1;
        if (edge == 2) return type(uint256).max;
        if (edge == 3) return SUPPLY;
        return seed;
    }

    function _digest(address owner, address spender, uint256 value, uint256 nonce) internal view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("IMDeezNutz")),
                keccak256(bytes("1")),
                block.chainid,
                address(token)
            )
        );
        bytes32 body = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, type(uint256).max));
        return keccak256(abi.encodePacked("\x19\x01", domain, body));
    }
}
