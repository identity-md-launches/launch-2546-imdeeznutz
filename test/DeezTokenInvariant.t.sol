// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeezToken} from "src/DeezToken.sol";
import {DeezTokenHandler} from "test/handlers/DeezTokenHandler.sol";

/// @notice Conservation, authorization and permit nonces across random call sequences.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract DeezTokenInvariantTest is Test {
    uint256 internal constant SUPPLY = 1e27;
    DeezTokenHandler internal handler;
    DeezToken internal token;

    function setUp() public {
        handler = new DeezTokenHandler();
        token = handler.token();
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.donateToToken.selector;
        selectors[4] = handler.permit.selector;
        selectors[5] = handler.permitThenReplay.selector;
        selectors[6] = handler.rejectWrongSigner.selector;
        selectors[7] = handler.rejectOverdraw.selector;
        selectors[8] = handler.rejectOverspend.selector;
        selectors[9] = handler.rejectDelegatedOverdraw.selector;
        selectors[10] = handler.rejectZeroReceiver.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev The closed recipient set is the four actors plus the passive token address.
    /// Fixed supply comes from the brief; exact movements and authorization come from
    /// the ERC-20 interface, and one nonce per valid permit from EIP-2612.
    function invariant_supplyBalancesAllowancesAndNoncesMatchAuthorizedActions() public view {
        _assertModel();
    }

    /// @dev Every active holder must remain able to move its entire balance after
    /// an arbitrary sequence, even after failed calls, self-transfers and revocations.
    function afterInvariant() public {
        uint256 liquidSupply = SUPPLY - handler.expectedBalance(address(token));
        for (uint256 i = 1; i < handler.ACTOR_COUNT(); ++i) {
            handler.transfer(i, 0, 2); // amount seed 2 selects the entire balance
        }
        assertEq(token.balanceOf(handler.actors(0)), liquidSupply, "holder liveness or transfer fee");
        _assertModel();
    }

    /// @notice Deterministically exercise every handler, including nonzero moves.
    /// This catches a broken target list or a model that only survives empty actions.
    function test_handlerExercisesEveryAction() public {
        _assertModel();
        handler.transfer(0, 1, 1);
        _assertModel();
        handler.approve(1, 2, 2); // infinite
        _assertModel();
        handler.transferFrom(1, 2, 3, 1);
        _assertModel();
        handler.permit(2, 3, 3);
        _assertModel();
        handler.transferFrom(2, 3, 2, 1); // self transfer still consumes approval
        _assertModel();
        handler.permitThenReplay(3, 0, 0); // signed revocation
        _assertModel();
        handler.rejectWrongSigner(0, 1, 1);
        _assertModel();
        handler.rejectOverdraw(1, 2, type(uint256).max);
        _assertModel();
        handler.rejectOverspend(2, 3, 0, 0);
        _assertModel();
        handler.rejectDelegatedOverdraw(3, 0, 1, false);
        _assertModel();
        handler.rejectDelegatedOverdraw(3, 0, 1, true);
        _assertModel();
        handler.rejectZeroReceiver(0, 1, 1);
        _assertModel();
        handler.donateToToken(0, 1);
        _assertModel();
        assertEq(handler.nonzeroTransfers(), 3);
        assertEq(handler.successfulPermits(), 2);
        assertEq(handler.expectedReverts(), 7);
        afterInvariant();
    }

    function _assertModel() internal view {
        uint256 sum = token.balanceOf(address(token));
        assertEq(sum, handler.expectedBalance(address(token)), "passive recipient balance");
        for (uint256 i; i < handler.ACTOR_COUNT(); ++i) {
            address actor = handler.actors(i);
            uint256 balance = token.balanceOf(actor);
            assertEq(balance, handler.expectedBalance(actor), "unauthorized or incorrect balance change");
            sum += balance;
            assertEq(token.nonces(actor), handler.expectedNonce(actor), "nonce changed without a valid permit");
            for (uint256 j; j < handler.ACTOR_COUNT(); ++j) {
                address spender = handler.actors(j);
                assertEq(
                    token.allowance(actor, spender), handler.expectedAllowance(actor, spender), "authorization mismatch"
                );
            }
            assertEq(token.allowance(actor, address(0)), 0, "zero spender approval");
        }
        assertEq(sum, SUPPLY, "tokens created, destroyed or leaked outside recipient set");
        assertEq(token.totalSupply(), SUPPLY, "fixed supply changed");
        assertEq(token.balanceOf(address(0)), 0, "zero address holds tokens");
        assertEq(token.balanceOf(address(handler)), 0, "handler received unauthorized tokens");
        assertEq(token.nonces(address(0)), 0, "zero owner consumed a nonce");
    }
}
