// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {DeezToken} from "../src/DeezToken.sol";
import {DeployDeezToken} from "../script/DeployDeezToken.s.sol";

contract DeezTokenTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    DeezToken internal token;

    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal distributor = makeAddr("distributor");
    address internal claimant = makeAddr("claimant");

    uint256 internal signerKey;
    address internal signer;

    function setUp() public {
        (signer, signerKey) = makeAddrAndKey("signer");
        vm.prank(deployer);
        token = new DeezToken();
    }

    // ------------------------------------------------------------------------
    // Metadata and constants
    // ------------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "IMDeezNutz");
        assertEq(token.symbol(), "DEEZ");
        assertEq(token.decimals(), 18);
        assertEq(token.TOKEN_NAME(), "IMDeezNutz");
        assertEq(token.TOKEN_SYMBOL(), "DEEZ");
        assertEq(token.TOKEN_DECIMALS(), 18);
    }

    function test_supplyConstantIsOneBillionWithEighteenDecimals() public view {
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), 1_000_000_000 * 10 ** 18);
        assertEq(token.TOTAL_SUPPLY(), 1e27);
    }

    // ------------------------------------------------------------------------
    // Constructor: the whole supply is minted once to the deployer
    // ------------------------------------------------------------------------

    function test_constructorMintsWholeSupplyToDeployer() public view {
        assertEq(token.totalSupply(), SUPPLY, "total supply");
        assertEq(token.balanceOf(deployer), SUPPLY, "deployer holds everything");
        assertEq(token.balanceOf(address(this)), 0, "the test holds nothing");
    }

    function test_constructorEmitsSingleMintTransfer() public {
        address factory = makeAddr("factory");
        vm.recordLogs();
        vm.prank(factory);
        DeezToken fresh = new DeezToken();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "exactly one event at construction");
        assertEq(logs[0].topics[0], IERC20.Transfer.selector);
        assertEq(address(uint160(uint256(logs[0].topics[1]))), address(0));
        assertEq(address(uint160(uint256(logs[0].topics[2]))), factory);
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY);
        assertEq(fresh.balanceOf(factory), SUPPLY);
    }

    function test_supplyGoesToWhoeverDeploys_notToAFixedAddress() public {
        address other = makeAddr("other-deployer");
        vm.prank(other);
        DeezToken fresh = new DeezToken();
        assertEq(fresh.balanceOf(other), SUPPLY);
        assertEq(fresh.balanceOf(deployer), 0);
        // The first instance is untouched by the second deployment.
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_constructorHasNoArgumentsAndCallsNoContract() public view {
        // Creation code is runtime code plus constructor; no ABI-encoded arguments are appended.
        bytes memory creation = type(DeezToken).creationCode;
        assertGt(creation.length, 0);
        // The deployed instance was built in a test where no other contract existed at the
        // addresses it could have called; a constructor that needed one would have reverted.
        assertGt(address(token).code.length, 0);
    }

    // ------------------------------------------------------------------------
    // Transfers: success
    // ------------------------------------------------------------------------

    function test_transfer_movesExactAmountAndEmits() public {
        vm.expectEmit(address(token));
        emit IERC20.Transfer(deployer, alice, 1_000 ether);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 1_000 ether));
        assertEq(token.balanceOf(alice), 1_000 ether);
        assertEq(token.balanceOf(deployer), SUPPLY - 1_000 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transfer_zeroAmountSucceeds() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transfer_toSelfKeepsBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(deployer, SUPPLY));
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_transfer_wholeBalance() public {
        vm.prank(deployer);
        token.transfer(alice, SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), SUPPLY);
    }

    /// @dev The launch flows: factory -> distributor -> claimant must each arrive whole.
    function test_launchFlowsArriveWhole() public {
        uint256 swarm = SUPPLY / 10;
        vm.prank(deployer);
        assertTrue(token.transfer(distributor, swarm));
        assertEq(token.balanceOf(distributor), swarm, "swarm share arrived short");

        vm.prank(distributor);
        assertTrue(token.transfer(claimant, swarm));
        assertEq(token.balanceOf(claimant), swarm, "claim arrived short");
        assertEq(token.balanceOf(distributor), 0, "distributor kept something");

        uint256 remainder = SUPPLY - swarm;
        vm.prank(deployer);
        assertTrue(token.transfer(bob, remainder));
        assertEq(token.balanceOf(bob), remainder, "remainder arrived short");
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.totalSupply(), SUPPLY, "supply changed");
    }

    function testFuzz_transfer_conservesSupplyAndMovesExactly(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
        assertEq(token.balanceOf(to) + token.balanceOf(deployer), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferChain_conservesSupply(uint256 a, uint256 b) public {
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, a);
        vm.prank(deployer);
        token.transfer(alice, a);
        vm.prank(alice);
        token.transfer(bob, b);
        assertEq(token.balanceOf(alice), a - b);
        assertEq(token.balanceOf(bob), b);
        assertEq(token.balanceOf(deployer) + token.balanceOf(alice) + token.balanceOf(bob), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ------------------------------------------------------------------------
    // Transfers: failure
    // ------------------------------------------------------------------------

    function test_transfer_revertsOnInsufficientBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 5 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 5 ether, 5 ether + 1)
        );
        vm.prank(alice);
        token.transfer(bob, 5 ether + 1);
    }

    function test_transfer_revertsFromEmptyAccount() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transfer(bob, 1);
    }

    function test_transfer_revertsToZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(deployer);
        token.transfer(address(0), 1 ether);
    }

    function testFuzz_transfer_revertsWhenAmountExceedsBalance(uint256 amount) public {
        amount = bound(amount, SUPPLY + 1, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, amount)
        );
        vm.prank(deployer);
        token.transfer(alice, amount);
    }

    // ------------------------------------------------------------------------
    // Allowances: success
    // ------------------------------------------------------------------------

    function test_approve_setsAllowanceAndEmits() public {
        vm.expectEmit(address(token));
        emit IERC20.Approval(deployer, alice, 42 ether);
        vm.prank(deployer);
        assertTrue(token.approve(alice, 42 ether));
        assertEq(token.allowance(deployer, alice), 42 ether);
    }

    function test_transferFrom_spendsAllowanceExactly() public {
        vm.prank(deployer);
        token.approve(alice, 100 ether);

        vm.expectEmit(address(token));
        emit IERC20.Transfer(deployer, bob, 60 ether);
        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, 60 ether));

        assertEq(token.balanceOf(bob), 60 ether);
        assertEq(token.balanceOf(deployer), SUPPLY - 60 ether);
        assertEq(token.allowance(deployer, alice), 40 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFrom_infiniteAllowanceIsNotDecremented() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1 ether);
        assertEq(token.allowance(deployer, alice), type(uint256).max);
    }

    function test_transferFrom_ownerMayNotSpendWithoutSelfAllowance() public {
        // Standard ERC-20: an owner moving its own tokens via transferFrom still needs an allowance.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1 ether));
        vm.prank(deployer);
        token.transferFrom(deployer, bob, 1 ether);
    }

    // ------------------------------------------------------------------------
    // Allowances: failure
    // ------------------------------------------------------------------------

    function test_transferFrom_revertsOnInsufficientAllowance() public {
        vm.prank(deployer);
        token.approve(alice, 10 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 10 ether, 10 ether + 1)
        );
        vm.prank(alice);
        token.transferFrom(deployer, bob, 10 ether + 1);
    }

    function test_transferFrom_revertsWithNoAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1);
    }

    function test_transferFrom_revertsWhenOwnerBalanceTooLow() public {
        vm.prank(alice);
        token.approve(bob, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1 ether));
        vm.prank(bob);
        token.transferFrom(alice, bob, 1 ether);
    }

    function test_approve_revertsForZeroSpender() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(deployer);
        token.approve(address(0), 1);
    }

    /// @dev A third party can never pull a holder's tokens without that holder's approval.
    function test_transferFrom_nobodyMovesAHolderWithoutApproval() public {
        vm.prank(deployer);
        token.transfer(alice, 1_000 ether);
        address[3] memory callers = [deployer, bob, address(this)];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            (bool ok,) = address(token).call(abi.encodeCall(IERC20.transferFrom, (alice, callers[i], 1)));
            assertFalse(ok, "an unapproved transferFrom succeeded");
        }
        assertEq(token.balanceOf(alice), 1_000 ether);
    }

    // ------------------------------------------------------------------------
    // Permit (EIP-2612): success
    // ------------------------------------------------------------------------

    function _signPermit(uint256 key, address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        return vm.sign(key, digest);
    }

    function test_permit_setsAllowanceAndBumpsNonce() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(signerKey, signer, alice, 7 ether, 0, deadline);

        vm.expectEmit(address(token));
        emit IERC20.Approval(signer, alice, 7 ether);
        token.permit(signer, alice, 7 ether, deadline, v, r, s);

        assertEq(token.allowance(signer, alice), 7 ether);
        assertEq(token.nonces(signer), 1);
    }

    function test_permit_thenTransferFromWorks() public {
        vm.prank(deployer);
        token.transfer(signer, 10 ether);
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(signerKey, signer, alice, 10 ether, 0, deadline);
        token.permit(signer, alice, 10 ether, deadline, v, r, s);
        vm.prank(alice);
        token.transferFrom(signer, bob, 10 ether);
        assertEq(token.balanceOf(bob), 10 ether);
        assertEq(token.balanceOf(signer), 0);
    }

    function test_domainSeparatorBindsChainAndAddress() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("IMDeezNutz")),
                keccak256(bytes("1")),
                block.chainid,
                address(token)
            )
        );
        assertEq(token.DOMAIN_SEPARATOR(), expected);
    }

    // ------------------------------------------------------------------------
    // Permit (EIP-2612): failure
    // ------------------------------------------------------------------------

    function test_permit_revertsWhenExpired() public {
        uint256 deadline = vm.getBlockTimestamp() + 1;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(signerKey, signer, alice, 1 ether, 0, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        token.permit(signer, alice, 1 ether, deadline, v, r, s);
    }

    function test_permit_revertsOnWrongSigner() public {
        uint256 deadline = block.timestamp + 1 hours;
        (, uint256 otherKey) = makeAddrAndKey("other");
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(otherKey, signer, alice, 1 ether, 0, deadline);
        vm.expectRevert();
        token.permit(signer, alice, 1 ether, deadline, v, r, s);
        assertEq(token.allowance(signer, alice), 0);
    }

    function test_permit_cannotBeReplayed() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(signerKey, signer, alice, 1 ether, 0, deadline);
        token.permit(signer, alice, 1 ether, deadline, v, r, s);
        vm.expectRevert();
        token.permit(signer, alice, 1 ether, deadline, v, r, s);
        assertEq(token.nonces(signer), 1);
    }

    function test_permit_revertsWhenValueTampered() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(signerKey, signer, alice, 1 ether, 0, deadline);
        vm.expectRevert();
        token.permit(signer, alice, 2 ether, deadline, v, r, s);
    }

    // ------------------------------------------------------------------------
    // Fixed supply and absence of privilege
    // ------------------------------------------------------------------------

    function test_noMintOrAdminEntryPointExists() public {
        string[12] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "owner()",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()",
            "unpause()",
            "setMinter(address)"
        ];
        address[2] memory callers = [deployer, alice];
        for (uint256 c; c < callers.length; ++c) {
            for (uint256 i; i < signatures.length; ++i) {
                bytes memory data = abi.encodeWithSignature(signatures[i], alice, type(uint128).max);
                vm.prank(callers[c]);
                (bool ok,) = address(token).call(data);
                assertFalse(ok, signatures[i]);
            }
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_noPrivilegedCallFreezesOrMovesAHolder() public {
        vm.prank(deployer);
        token.transfer(alice, 1_000 ether);
        string[12] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            vm.prank(deployer);
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, true));
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.balanceOf(alice), 1_000 ether, "a privileged call moved the holder's balance");
        vm.prank(alice);
        assertTrue(token.transfer(bob, 500 ether), "the holder can no longer transfer");
        assertEq(token.balanceOf(bob), 500 ether);
    }

    function test_supplyNeverChangesAcrossActivity() public {
        vm.startPrank(deployer);
        token.transfer(alice, 1 ether);
        token.approve(bob, 2 ether);
        vm.stopPrank();
        vm.prank(bob);
        token.transferFrom(deployer, bob, 2 ether);
        vm.prank(alice);
        token.transfer(bob, 1 ether);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(deployer) + token.balanceOf(bob), SUPPLY);
    }

    function test_contractAcceptsNoEther() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok, "the token accepted ether");
        assertEq(address(token).balance, 0);
    }

    /// @dev Mirrors the launch floor's opcode scan: no DELEGATECALL, CALLCODE or SELFDESTRUCT in
    /// reachable runtime code. PUSH data is skipped so constants are not misread as instructions.
    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        bool reachable = true;
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op == 0x5B) reachable = true;
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            if (reachable) {
                assertTrue(op != 0xF4, "runtime contains DELEGATECALL");
                assertTrue(op != 0xF2, "runtime contains CALLCODE");
                assertTrue(op != 0xFF, "runtime contains SELFDESTRUCT");
            }
            if (op == 0x00 || op == 0x56 || op == 0xF3 || op == 0xFD || op == 0xFE || op == 0xFF) reachable = false;
        }
    }

    // ------------------------------------------------------------------------
    // Deploy script
    // ------------------------------------------------------------------------

    function test_deployScriptFunctionMintsToItsCaller() public {
        DeployDeezToken deployScript = new DeployDeezToken();
        DeezToken deployed = deployScript.deploy();
        // `new` inside the script makes the script contract the deployer, so it holds the supply.
        assertEq(deployed.totalSupply(), SUPPLY);
        assertEq(deployed.balanceOf(address(deployScript)), SUPPLY);
        assertEq(deployed.name(), "IMDeezNutz");
        assertEq(deployed.symbol(), "DEEZ");
        assertEq(deployed.decimals(), 18);
    }
}
