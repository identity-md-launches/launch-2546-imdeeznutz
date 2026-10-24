# DEEZ adversarial tests

The original `DeezToken.t.sol` remains intact. The added tests use only the real
`DeezToken` and the already vendored dependencies. They require no RPC, environment
variables, filesystem cheatcodes, FFI, or external services.

| File | Additional coverage |
| --- | --- |
| `DeezTokenProperties.t.sol` | Zero and one-unit transfers, whole-supply delegated transfers, self-transfers, finite versus infinite approval, revocation, isolated approvals, split spending, round trips, and rollback after failed delegated transfers. |
| `DeezTokenPermit.t.sol` | Independently constructed EIP-712 signatures, deadline equality and expiry, nonce sequencing, replay after revocation, cross-token and cross-chain replay, changed signed fields, zero spender/owner, malformed signatures, and high-S malleability. Failed permits must preserve existing approval and leave the nonce reusable. |
| `DeezTokenInvariant.t.sol` | Random call sequences, exact accounting and authorization checks after every action, and full-balance transfer liveness after every sequence. |
| `handlers/DeezTokenHandler.sol` | Four actors performing transfers, approvals, delegated spending, permits, replay attempts, invalid signatures, overdraws, overspending, zero-recipient attempts, and transfers to the token itself. |

The invariant model tracks balances, every actor-to-actor allowance, and permit
nonces from authorized inputs. It never synchronizes its expected state from the
token after a call. The sum of the four actor balances and the token's own balance
must equal exactly `1e27`, as must `totalSupply()`. The token address is a passive
recipient and is never impersonated to recover its tokens. Unexpected handler
reverts fail the campaign; expected failures assert the relevant custom error.
A deterministic test exercises every handler and verifies nonzero transfers,
successful permits, rejected actions, and the model after each action.

Inline settings specify 1,000 cases for each new stateless fuzz property and 256
invariant sequences of 64 actions. Amount generation explicitly includes zero,
one minor unit, full balances, and infinite approvals. Known arithmetic boundaries
also have deterministic tests. No implementation or project configuration changes
are needed.

Run from the repository root:

```sh
forge build --offline
forge test --offline --fuzz-seed 0x71c3e5122e587ffb411b192e64f1596df39c31172a7ab8bec66f1b943e190279
forge fmt --check
```

These tests cover the token's public behavior. They do not recreate the external
factory, distributor or Uniswap deployment infrastructure from the protected
launch harness. The accounting and handler design was informed by the supplied
Pashov fizz and Trail of Bits property-based testing references; the test code is
written for this token and Foundry.

## Validation results

- Offline build and all 70 tests pass with the verifier's seed, including 16,384
  invariant handler calls with no unexpected reverts. The same suite passes with
  seed `0xc0ffee`; `--fuzz-runs 2000` raises the original suite's runs, while the new
  fuzz tests retain their explicit inline setting of 1,000.
- A clean source export containing the tracked files plus these five additions
  compiles 46 files, passes all 70 tests with the verifier's seed, and passes
  `forge fmt --check`. It contains no build cache or pinned task inputs.
- The required Slither gate is **not green**: the high-only invocation exits 255
  with `incorrect-exp` at the unchanged OpenZeppelin `Math.sol:205`, where an
  intentional XOR seeds the modular inverse. The medium-inclusive invocation
  also lists nine `divide-before-multiply` diagnostics in that library. This is
  reported separately as an acceptance blocker, not a demonstrated token defect.
  The protected library was not edited and no detector was suppressed.
- Git staging is unavailable because the repository index is read-only. The clean
  export was therefore made from the tracked source files plus the new tests,
  rather than claimed to be a staged or committed checkout.
