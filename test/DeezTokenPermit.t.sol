// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {DeezToken} from "src/DeezToken.sol";

/// @notice Sign the specified EIP-712 domain independently of DOMAIN_SEPARATOR().
/// forge-config: default.fuzz.runs = 1000
contract DeezTokenPermitTest is Test {
    uint256 internal constant SUPPLY = 1e27;
    uint256 internal constant INITIAL_ALLOWANCE = 17;
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    struct Signature {
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    DeezToken internal token;
    address internal holder;
    uint256 internal holderKey;
    address internal spender = makeAddr("permit-spender");
    address internal other = makeAddr("permit-other");
    address internal relayer = makeAddr("permit-relayer");

    function setUp() public {
        (holder, holderKey) = makeAddrAndKey("permit-holder");
        vm.prank(holder);
        token = new DeezToken();
        vm.prank(holder);
        token.approve(spender, INITIAL_ALLOWANCE);
    }

    function testFuzz_permitWorksThroughRelayerAtExactDeadline(uint256 value, uint256 lifetime) public {
        uint256 deadline = vm.getBlockTimestamp() + bound(lifetime, 0, 365 days);
        Signature memory sig = _sign(spender, value, 0, deadline);
        vm.warp(deadline);
        vm.expectEmit(address(token));
        emit IERC20.Approval(holder, spender, value);
        vm.prank(relayer);
        _submit(token, spender, value, deadline, sig);
        _assertState(1, value);
        assertEq(token.nonces(relayer), 0);
        assertEq(token.allowance(holder, relayer), 0);
    }

    function test_infinitePermitCanBeSpentRepeatedlyAndRevoked() public {
        Signature memory sig = _sign(spender, type(uint256).max, 0, type(uint256).max);
        _submit(token, spender, type(uint256).max, type(uint256).max, sig);
        vm.startPrank(spender);
        assertTrue(token.transferFrom(holder, other, 1));
        assertTrue(token.transferFrom(holder, other, 2));
        vm.stopPrank();
        assertEq(token.allowance(holder, spender), type(uint256).max);
        assertEq(token.nonces(holder), 1);

        sig = _sign(spender, 0, 1, type(uint256).max);
        _submit(token, spender, 0, type(uint256).max, sig);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(holder, other, 1);
        assertEq(token.balanceOf(holder), SUPPLY - 3);
        assertEq(token.balanceOf(other), 3);
        assertEq(token.allowance(holder, spender), 0);
        assertEq(token.nonces(holder), 2);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_replayedPermitCannotRestoreRevokedAllowance() public {
        Signature memory first = _sign(spender, 100, 0, type(uint256).max);
        _submit(token, spender, 100, type(uint256).max, first);
        Signature memory revoke = _sign(spender, 0, 1, type(uint256).max);
        _submit(token, spender, 0, type(uint256).max, revoke);
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        _submit(token, spender, 100, type(uint256).max, first);
        _assertState(2, 0);
    }

    function test_futureNonceFailsUntilPreviousNonceIsUsed() public {
        Signature memory future = _sign(spender, 99, 1, type(uint256).max);
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        _submit(token, spender, 99, type(uint256).max, future);
        _assertState(0, INITIAL_ALLOWANCE);

        Signature memory first = _sign(spender, 1, 0, type(uint256).max);
        _submit(token, spender, 1, type(uint256).max, first);
        _submit(token, spender, 99, type(uint256).max, future);
        _assertState(2, 99);
    }

    function test_expiredPermitLeavesExistingApprovalAndNonceIntact() public {
        uint256 deadline = vm.getBlockTimestamp() + 1;
        Signature memory sig = _sign(spender, 123, 0, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        _submit(token, spender, 123, deadline, sig);
        _assertState(0, INITIAL_ALLOWANCE);

        // Failure must leave nonce zero available for a different, unexpired signature.
        sig = _sign(spender, 123, 0, type(uint256).max);
        _submit(token, spender, 123, type(uint256).max, sig);
        _assertState(1, 123);
    }

    function test_zeroSpenderRevertsAfterRecoveryAndRollsBackNonce() public {
        Signature memory sig = _sign(address(0), 1, 0, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        _submit(token, address(0), 1, type(uint256).max, sig);
        _assertState(0, INITIAL_ALLOWANCE);
        assertEq(token.allowance(holder, address(0)), 0);
        sig = _sign(spender, 1, 0, type(uint256).max);
        _submit(token, spender, 1, type(uint256).max, sig);
        _assertState(1, 1);
    }

    function test_wrongSignerDoesNotConsumeNonceOrOverwriteApproval() public {
        (address wrongSigner, uint256 wrongKey) = makeAddrAndKey("wrong-permit-signer");
        Signature memory sig;
        (sig.v, sig.r, sig.s) =
            vm.sign(wrongKey, _digest(address(token), block.chainid, spender, 10, 0, type(uint256).max));
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, wrongSigner, holder));
        _submit(token, spender, 10, type(uint256).max, sig);
        _assertState(0, INITIAL_ALLOWANCE);
        assertEq(token.nonces(wrongSigner), 0);
    }

    function testFuzz_signedFieldsCannotBeChanged(uint8 field, uint256 value) public {
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        Signature memory sig = _sign(spender, value, 0, deadline);
        uint256 choice = bound(field, 0, 3);
        address submittedOwner = choice == 0 ? other : holder;
        address submittedSpender = choice == 1 ? other : spender;
        uint256 submittedValue = choice == 2 ? value ^ 1 : value;
        uint256 submittedDeadline = choice == 3 ? deadline + 1 : deadline;

        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        token.permit(submittedOwner, submittedSpender, submittedValue, submittedDeadline, sig.v, sig.r, sig.s);
        _assertState(0, INITIAL_ALLOWANCE);
        assertEq(token.nonces(other), 0);
        assertEq(token.allowance(holder, other), 0);
        assertEq(token.allowance(other, spender), 0);
        _submit(token, spender, value, deadline, sig);
        _assertState(1, value);
    }

    function test_signatureCannotBeReplayedOnAnotherToken() public {
        vm.prank(holder);
        DeezToken second = new DeezToken();
        Signature memory sig = _sign(spender, 50, 0, type(uint256).max);
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        _submit(second, spender, 50, type(uint256).max, sig);
        assertEq(second.nonces(holder), 0);
        assertEq(second.allowance(holder, spender), 0);
        assertEq(second.balanceOf(holder), SUPPLY);
        _assertState(0, INITIAL_ALLOWANCE);
        _submit(token, spender, 50, type(uint256).max, sig);
        _assertState(1, 50);
    }

    function test_chainChangeInvalidatesOldDomainAndAcceptsNewDomain() public {
        (,,, uint256 originalChain,,,) = token.eip712Domain();
        Signature memory oldSig = _sign(spender, 50, 0, type(uint256).max);
        bytes32 oldDomain = token.DOMAIN_SEPARATOR();
        uint256 newChain = originalChain ^ 1;
        vm.chainId(newChain);
        assertEq(token.DOMAIN_SEPARATOR(), _domain(address(token), newChain));
        assertNotEq(token.DOMAIN_SEPARATOR(), oldDomain);
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        _submit(token, spender, 50, type(uint256).max, oldSig);
        _assertState(0, INITIAL_ALLOWANCE);

        Signature memory newSig;
        (newSig.v, newSig.r, newSig.s) =
            vm.sign(holderKey, _digest(address(token), newChain, spender, 50, 0, type(uint256).max));
        _submit(token, spender, 50, type(uint256).max, newSig);
        _assertState(1, 50);
        vm.chainId(originalChain);
        assertEq(token.DOMAIN_SEPARATOR(), oldDomain);
    }

    function test_zeroSignatureAndZeroOwnerCannotCreateApproval() public {
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        token.permit(address(0), spender, 1, type(uint256).max, 27, bytes32(0), bytes32(0));
        assertEq(token.nonces(address(0)), 0);
        assertEq(token.allowance(address(0), spender), 0);

        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        token.permit(holder, spender, 1, type(uint256).max, 27, bytes32(0), bytes32(0));
        _assertState(0, INITIAL_ALLOWANCE);
    }

    function test_invalidRecoveryIdDoesNotConsumeNonce() public {
        Signature memory sig = _sign(spender, 1, 0, type(uint256).max);
        uint8 validV = sig.v;
        sig.v = 0;
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        _submit(token, spender, 1, type(uint256).max, sig);
        _assertState(0, INITIAL_ALLOWANCE);
        sig.v = validV;
        _submit(token, spender, 1, type(uint256).max, sig);
        _assertState(1, 1);
    }

    function test_malleableHighSSignatureRejectedButOriginalStillWorks() public {
        Signature memory sig = _sign(spender, 1, 0, type(uint256).max);
        bytes32 highS = bytes32(SECP256K1_ORDER - uint256(sig.s));
        uint8 flippedV = sig.v == 27 ? 28 : 27;
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, highS));
        token.permit(holder, spender, 1, type(uint256).max, flippedV, sig.r, highS);
        _assertState(0, INITIAL_ALLOWANCE);
        _submit(token, spender, 1, type(uint256).max, sig);
        _assertState(1, 1);
    }

    function test_eip712DomainReportsExpectedFields() public view {
        (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        ) = token.eip712Domain();
        assertEq(fields, bytes1(0x0f));
        assertEq(name, "IMDeezNutz");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(token));
        assertEq(salt, bytes32(0));
        assertEq(extensions.length, 0);
    }

    function _assertState(uint256 nonce, uint256 allowance) internal view {
        assertEq(token.nonces(holder), nonce);
        assertEq(token.allowance(holder, spender), allowance);
        assertEq(token.balanceOf(holder), SUPPLY);
        assertEq(token.balanceOf(spender), 0);
        assertEq(token.balanceOf(other), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function _submit(DeezToken target, address to, uint256 value, uint256 deadline, Signature memory sig) internal {
        target.permit(holder, to, value, deadline, sig.v, sig.r, sig.s);
    }

    function _sign(address to, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (Signature memory sig)
    {
        (sig.v, sig.r, sig.s) = vm.sign(holderKey, _digest(address(token), block.chainid, to, value, nonce, deadline));
    }

    function _digest(address target, uint256 chainId, address to, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 body = keccak256(abi.encode(PERMIT_TYPEHASH, holder, to, value, nonce, deadline));
        return keccak256(abi.encodePacked("\x19\x01", _domain(target, chainId), body));
    }

    function _domain(address target, uint256 chainId) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("IMDeezNutz")),
                keccak256(bytes("1")),
                chainId,
                target
            )
        );
    }
}
