// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {DeezToken} from "src/DeezToken.sol";

/// @notice Edge cases and atomicity properties that complement DeezToken.t.sol.
/// forge-config: default.fuzz.runs = 1000
contract DeezTokenPropertiesTest is Test {
    uint256 internal constant SUPPLY = 1e27;
    DeezToken internal token;
    address internal holder = makeAddr("property-holder");
    address internal spender = makeAddr("property-spender");
    address internal recipient = makeAddr("property-recipient");

    function setUp() public {
        vm.prank(holder);
        token = new DeezToken();
    }

    function test_zeroTransfersFromEmptyAccountEmitAndNeedNoAllowance() public {
        vm.expectEmit(address(token));
        emit IERC20.Transfer(recipient, holder, 0);
        vm.prank(recipient);
        assertTrue(token.transfer(holder, 0));

        vm.expectEmit(address(token));
        emit IERC20.Transfer(recipient, holder, 0);
        vm.prank(spender);
        assertTrue(token.transferFrom(recipient, holder, 0));

        assertEq(token.balanceOf(holder), SUPPLY);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.allowance(recipient, spender), 0);
        assertEq(token.nonces(recipient), 0);
    }

    function test_zeroValuesDoNotMakeZeroReceiverOrSpenderValid() public {
        vm.startPrank(holder);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 0);
        vm.stopPrank();

        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(holder, address(0), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(holder), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFromZeroOwnerCannotMintEvenZeroTokens() public {
        // The allowance validation rejects the zero owner before the transfer runs.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(address(0), recipient, 0);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(recipient), 0);
    }

    function test_transferFromOneWeiAndFullRemainingSupply() public {
        _approve(SUPPLY);
        vm.startPrank(spender);
        assertTrue(token.transferFrom(holder, recipient, 1));
        assertEq(token.balanceOf(recipient), 1);
        assertEq(token.allowance(holder, spender), SUPPLY - 1);
        assertTrue(token.transferFrom(holder, recipient, SUPPLY - 1));
        vm.stopPrank();
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(recipient), SUPPLY);
        assertEq(token.allowance(holder, spender), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(holder, recipient, 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_revokeInfiniteAllowancePreventsFurtherSpending() public {
        _approve(type(uint256).max);
        vm.prank(spender);
        assertTrue(token.transferFrom(holder, recipient, 1));
        _approve(0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(holder, recipient, 1);
        assertEq(token.balanceOf(holder), SUPPLY - 1);
        assertEq(token.balanceOf(recipient), 1);
        assertEq(token.allowance(holder, spender), 0);
    }

    function test_maximumFiniteAllowanceIsDecremented() public {
        _approve(type(uint256).max - 1);
        vm.prank(spender);
        assertTrue(token.transferFrom(holder, recipient, 1));
        assertEq(token.allowance(holder, spender), type(uint256).max - 2);
        assertEq(token.balanceOf(recipient), 1);
    }

    function test_maximumTransferFromFailsWithoutSpendingInfiniteAllowance() public {
        _approve(type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, SUPPLY, type(uint256).max)
        );
        vm.prank(spender);
        token.transferFrom(holder, recipient, type(uint256).max);
        _assertUnmoved(type(uint256).max);
    }

    function test_selfTransferStillRequiresEnoughBalance() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, SUPPLY, SUPPLY + 1)
        );
        vm.prank(holder);
        token.transfer(holder, SUPPLY + 1);
        assertEq(token.balanceOf(holder), SUPPLY);
    }

    function testFuzz_selfTransferFromConsumesOnlyItsAllowance(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        _approve(amount);
        vm.expectEmit(address(token));
        emit IERC20.Transfer(holder, holder, amount);
        vm.prank(spender);
        assertTrue(token.transferFrom(holder, holder, amount));
        assertEq(token.balanceOf(holder), SUPPLY);
        assertEq(token.allowance(holder, spender), 0);
        assertEq(token.balanceOf(spender), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferFromZeroReceiverRollsBackAllowance(uint256 amount, uint256 approved) public {
        amount = bound(amount, 0, SUPPLY);
        approved = bound(approved, amount, type(uint256).max);
        _approve(approved);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(holder, address(0), amount);
        _assertUnmoved(approved);
        assertEq(token.balanceOf(address(0)), 0);
    }

    function testFuzz_transferFromOverBalanceRollsBackFiniteAllowance(uint256 amount) public {
        amount = bound(amount, SUPPLY + 1, type(uint256).max - 1);
        _approve(amount);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, SUPPLY, amount));
        vm.prank(spender);
        token.transferFrom(holder, recipient, amount);
        _assertUnmoved(amount);
    }

    function testFuzz_transferFromOverAllowanceIsAtomic(uint256 approved, uint256 amount) public {
        approved = bound(approved, 0, SUPPLY - 1);
        amount = bound(amount, approved + 1, SUPPLY);
        _approve(approved);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, approved, amount)
        );
        vm.prank(spender);
        token.transferFrom(holder, recipient, amount);
        _assertUnmoved(approved);
    }

    function testFuzz_approveOverwritesAndIsIsolated(uint256 first, uint256 replacement) public {
        _approve(first);
        vm.prank(recipient);
        assertTrue(token.approve(spender, first));
        vm.prank(holder);
        assertTrue(token.approve(recipient, first));

        _approve(replacement);
        _approve(replacement);
        assertEq(token.allowance(holder, spender), replacement);
        assertEq(token.allowance(holder, recipient), first);
        assertEq(token.allowance(recipient, spender), first);
        assertEq(token.balanceOf(holder), SUPPLY);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.nonces(holder), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_splitDelegatedSpendingCannotExceedAuthorization(uint256 budget, uint256 firstSpend) public {
        budget = bound(budget, 1, SUPPLY - 1);
        firstSpend = bound(firstSpend, 0, budget);
        _approve(budget);
        vm.startPrank(spender);
        assertTrue(token.transferFrom(holder, recipient, firstSpend));
        assertTrue(token.transferFrom(holder, spender, budget - firstSpend));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(holder, recipient, 1);
        vm.stopPrank();
        assertEq(token.balanceOf(holder), SUPPLY - budget);
        assertEq(token.balanceOf(recipient), firstSpend);
        assertEq(token.balanceOf(spender), budget - firstSpend);
        assertEq(token.allowance(holder, spender), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferRoundTripRestoresBothBalances(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(holder);
        assertTrue(token.transfer(recipient, amount));
        vm.prank(recipient);
        assertTrue(token.transfer(holder, amount));
        _assertUnmoved(0);
    }

    function _approve(uint256 amount) internal {
        vm.prank(holder);
        assertTrue(token.approve(spender, amount));
    }

    function _assertUnmoved(uint256 expectedAllowance) internal view {
        assertEq(token.balanceOf(holder), SUPPLY);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.balanceOf(spender), 0);
        assertEq(token.allowance(holder, spender), expectedAllowance);
        assertEq(token.nonces(holder), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
