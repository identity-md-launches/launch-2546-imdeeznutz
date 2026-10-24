# IMDeezNutz (DEEZ)

A fixed-supply ERC-20 token for the IdentityMD custom-token launch on Ethereum mainnet.

| Parameter        | Value                                                      |
| ---------------- | ---------------------------------------------------------- |
| Solidity contract | `DeezToken` (`src/DeezToken.sol`)                         |
| Token name       | `IMDeezNutz`                                               |
| Token symbol     | `DEEZ`                                                     |
| Decimals         | 18                                                         |
| Total supply     | 1,000,000,000 DEEZ = `1000000000000000000000000000` minor units (1e27) |
| Minted to        | `msg.sender` of the constructor, once, in the constructor  |
| Constructor args | none                                                       |
| Owner / admin    | none                                                       |
| Compiler         | solc 0.8.26, optimizer on (200 runs), `bytecode_hash = "none"` |

## What the token does

`DeezToken` is OpenZeppelin v5.1.0 `ERC20` plus `ERC20Permit` (EIP-2612), nothing else.

- The constructor mints the whole supply of 1e27 minor units to `msg.sender` and emits one
  `Transfer(address(0), msg.sender, 1e27)`. It takes no arguments and calls no other contract,
  so it deploys on an empty chain and from a factory.
- There is no `mint`, no owner, no minter role, no pause, no blacklist, no fee, no burn hook
  and no upgrade path. The supply can never grow, and no address holds any privilege after
  deployment. The only way a balance moves is `transfer`, or `transferFrom` backed by an
  allowance the holder granted through `approve` or `permit`.
- `transfer` and `transferFrom` move exactly the amount requested. Nothing is taxed or
  reflected, so every launch flow (factory to distributor, distributor to claimant, factory
  to pool, pool to trader, requester remainder) arrives whole.
- `permit` lets a holder sign an EIP-712 approval off chain that anyone can submit. The
  domain is `name = "IMDeezNutz"`, `version = "1"`, bound to the chain id and the token's
  address. Signatures carry a nonce and a deadline and cannot be replayed.
- The contract has no `receive` or `fallback`, so it refuses ether.
- The runtime contains no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`.

## Deployment parameters

The token has nothing to configure. The whole configuration is the four constants in
`src/DeezToken.sol`:

| Constant         | Value                              | Why                                   |
| ---------------- | ---------------------------------- | ------------------------------------- |
| `TOKEN_NAME`     | `"IMDeezNutz"`                     | Requested name                        |
| `TOKEN_SYMBOL`   | `"DEEZ"`                           | Requested symbol                      |
| `TOKEN_DECIMALS` | `18`                               | Requested decimals                    |
| `TOTAL_SUPPLY`   | `1_000_000_000 * 10 ** 18`         | Requested supply, in minor units      |

The brief left no number open, so no value here was chosen by the builder.

### The IMD launch (Ethereum, chain id 1)

The launch is performed by IMD's deployer through `ProjectFactory.launchCustom`, not by this
repository. The factory deploys `DeezToken` from the bytecode built here with no constructor
arguments, so the factory is `msg.sender` and receives the whole supply. From there the factory:

- sends 10% of the supply to the launch's MerkleDistributor for the swarm;
- seeds 80% (`economics.poolBps = 8000`) single-sided into a Uniswap v4 pool paired with IMD
  (`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`) at fee 12500 (1.25%), tick spacing 60, with
  the opening price derived from `economics.initialMarketCapWei = 5500 IMD`;
- forwards the remaining 10% to `economics.remainderTo`,
  `0x612a9bb008e16ef2d24f41dae9fc661831d93367`.

The manifest step writes `launch.json` after this work is accepted. For it, the token's
`totalSupply` is `1000000000000000000000000000`, `decimals` is `18`, `constructorArgs` is empty,
and `token.contract` is `DeezToken`. There are no application contracts.

### Deploying elsewhere (local, test network)

`script/DeployDeezToken.s.sol` deploys the token with whatever signer `forge script` is given.
That signer receives the whole supply. The script reads no environment variables; its
`deploy()` function is what the tests call.

```sh
forge script script/DeployDeezToken.s.sol:DeployDeezToken --rpc-url <url> --broadcast --private-key <key>
```

This repository does not hold keys and does not broadcast anything on its own.

## After launch

Nothing. There is no owner-settable value, no setter and no admin function, so there is no
post-deployment configuration step and no key to keep safe on the token's behalf.

## Operational responsibilities and trust assumptions

- **Nobody controls the token.** Whoever deploys it holds the supply at that moment and nothing
  more. After the factory distributes the supply, no party, including the deployer, IMD or the
  requester, can mint, freeze, seize, pause or tax. This is by design and cannot be changed
  without deploying a new token.
- **Distribution is the factory's.** The token trusts nothing about the factory, pool manager
  or distributor; it exempts nobody and needs no exemptions because it taxes nothing. How the
  supply is split is the launch policy's responsibility, recorded in `launch.json`.
- **Holders are responsible for their approvals.** `approve` and `permit` grant a spender the
  right to move tokens up to the allowance. A `permit` signature is as good as an on-chain
  approval until its deadline. Holders should sign permits only for contracts they trust and
  with bounded values and short deadlines.
- **Lost tokens are lost.** Tokens sent to an address nobody controls cannot be recovered.
  Transfers to the zero address revert, but transfers to any other address go through.
- **Source verification** on Etherscan after the launch is the deployer's step
  (`forge verify-contract` with solc 0.8.26, optimizer on, 200 runs, no metadata hash).
- **Tests are not an audit.** Everything here is OpenZeppelin's audited code assembled with no
  custom logic beyond the constructor, but a contract that holds other people's value should
  still get an independent adversarial review before anyone relies on it.

## Repository layout

```
foundry.toml                    solc 0.8.26, bytecode_hash = "none", remappings, no ffi, no fs access
src/DeezToken.sol               the token
script/DeployDeezToken.s.sol    optional deploy script (not used by the IMD launch)
test/DeezToken.t.sol            39 tests: success, failure and fuzz
lib/forge-std/                  forge-std v1.9.7, vendored as plain files (MIT / Apache-2.0)
lib/openzeppelin-contracts/     OpenZeppelin Contracts v5.1.0 `contracts/` tree, vendored as plain files (MIT), mocks removed
```

Dependencies are committed as ordinary files, not git submodules, so the project builds offline.

## Checks

```sh
forge build
forge test
forge fmt --check
```

The fuzz tests were run with the verifier's seed:

```sh
FOUNDRY_FUZZ_SEED=0x71c3e5122e587ffb411b192e64f1596df39c31172a7ab8bec66f1b943e190279 forge test
```

### What the tests cover

- **Metadata and constants:** name, symbol, decimals, the supply constant equals 1e27.
- **Constructor:** the whole supply goes to `msg.sender`, exactly one `Transfer` event is
  emitted, a different deployer receives the supply of its own instance, no arguments.
- **Transfers:** exact movement with events, zero amount, self-transfer, whole balance, the
  launch flows (factory to distributor to claimant, remainder) arrive whole; fuzzed conservation
  of supply over one and two hops.
- **Transfer failures:** insufficient balance, empty account, zero-address receiver, fuzzed
  amounts above the balance, each with the exact custom error.
- **Allowances:** approve with event, transferFrom spends exactly, infinite allowance is not
  decremented, the owner itself needs an allowance to use transferFrom.
- **Allowance failures:** insufficient allowance, no allowance, owner balance too low,
  zero-address spender, nobody moves a holder without approval.
- **Permit:** sets allowance and bumps the nonce, then transferFrom works, domain separator
  binds chain and address; fails when expired, signed by the wrong key, replayed or tampered.
- **Fixed supply and no privilege:** every common mint/admin/pause/blacklist/freeze/seize
  selector reverts from both the deployer and a stranger, the supply never changes, holders
  keep their balance and can still transfer, the contract refuses ether, and an opcode scan
  of the runtime finds no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`.
- **Deploy script:** `deploy()` produces a token with the right metadata and the supply at
  its caller.

Slither was not available on the build machine and was not run. The code was written around
its rejected detectors: no `selfdestruct`, no `delegatecall`, no initializer or upgrade path,
no inline shifts, no `abi.encodePacked` of consecutive dynamic values, and `transferFrom` only
moves tokens with the owner's allowance.
