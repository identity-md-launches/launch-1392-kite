# Kite (KITE)

A fixed-supply ERC-20 token for a custom token launch on Ethereum mainnet.

| Property        | Value                                                   |
| --------------- | ------------------------------------------------------- |
| Contract        | `KiteToken` (`src/KiteToken.sol`)                       |
| Name            | Kite                                                    |
| Symbol          | KITE                                                    |
| Decimals        | 18                                                      |
| Total supply    | 1,000,000,000 KITE = `1000000000000000000000000000` minor units |
| Minted to       | `msg.sender` of the constructor (the launch factory), once |
| Constructor     | no arguments, calls no other contract                   |
| Admin functions | none                                                    |

## Behaviour

- **Fixed supply.** `TOTAL_SUPPLY` is a compile-time constant and `totalSupply()` returns it. There is no
  `mint`, no `burn`, no owner, no minter role, no proxy and no initializer. The supply can never grow or shrink.
- **Plain transfers.** `transfer` and `transferFrom` move exactly the amount requested. There is no fee,
  reflection, tax, cooldown, max-wallet, pause or blocklist, so every launch flow (factory to distributor,
  distributor to claimants, factory to pool, trader to and from the pool) delivers whole amounts. Nothing
  needs an exemption, so the constructor takes none of the launch addresses.
- **Standard allowances.** `approve` overwrites (it does not add). `transferFrom` decrements the allowance
  unless it is `type(uint256).max`, which is treated as unlimited. Zero-address senders, receivers and
  spenders are rejected.
- **Reverts, not false.** Failing transfers revert with typed errors (`InsufficientBalance`,
  `InsufficientAllowance`, `InvalidReceiver`, `InvalidSender`, `InvalidSpender`); successful ones return
  `true`. The contract has no `receive` or `fallback`, so it rejects ETH and unknown selectors.
- **No DELEGATECALL, CALLCODE or SELFDESTRUCT** in the runtime, and no external library calls, so the
  built bytecode deploys as-is with nothing to link.

## Deployment parameters

The launch factory deploys the compiled creation code of `KiteToken` with **no constructor arguments**.
The manifest step records:

- `token.contract`: `KiteToken`
- `token.name`: `Kite`, `token.symbol`: `KITE`, `token.decimals`: `18`
- `token.totalSupply`: `1000000000000000000000000000`
- `token.constructorArgs`: `[]`

Chain, pool and economics are the launch's and are not read by the token: Ethereum (chain id 1), paired
with native ETH, pool fee 12500 (1.25%), tick spacing 60, 88% of supply to the pool at a 10 ETH opening
market cap, 10% to the swarm's MerkleDistributor, and the remaining 2% forwarded to
`0xbdd848d77af9e2a9c8def8fbfa6fd3a36c7dfde7`. The factory performs every one of those transfers from its
own balance after the constructor has minted the whole supply to it.

Build settings (`foundry.toml`): solc `0.8.26`, optimizer on (200 runs), `evm_version = "cancun"`,
`bytecode_hash = "none"` and `cbor_metadata = false` so the bytecode is reproducible byte for byte.

## Assumptions

- The requester wanted a plain token: the brief asks for name, symbol and supply only, so no tax, burn,
  vesting, governance or ownership was added. Adding any later means a new contract; this one cannot be
  upgraded.
- Whoever calls the constructor receives the whole supply. At launch that is the factory, which then pays
  it out. If the contract is deployed by hand, the deploying account holds everything.
- No wallet address, key or external contract is needed, so nothing is left as a placeholder or an
  owner-settable value.

## Operational responsibilities

- **Nobody administers the token.** After deployment there is nothing to configure, pause, upgrade or
  transfer ownership of. There is no "After launch" setup.
- **Holders are responsible for their own keys and approvals.** Unlimited approvals (`type(uint256).max`)
  are honoured until the holder resets them with `approve(spender, 0)`.
- **Distribution is the factory's job.** The token does not know about the distributor, pool or
  requester; it only moves balances on request.
- **Verification** of the source on a block explorer after launch (for example with
  `forge verify-contract`) is the deployer's open item; this task does not deploy or broadcast.

## Layout

```
foundry.toml          compiler pins and build settings
remappings.txt        forge-std/ -> lib/forge-std/src/
src/KiteToken.sol     the token
test/KiteToken.t.sol  unit and fuzz tests
lib/forge-std/        vendored forge-std 1.17.0 (plain files, no submodule)
```

## Running the checks

```
forge build
forge test
forge fmt --check
```

Tests read no environment variables and do not depend on the calling address, so they run in any order
and in parallel. Tests passing is not a security audit; the contract is small and dependency-free, but an
independent review before release is still the launch's call.
