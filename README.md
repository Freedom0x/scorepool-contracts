# Credit Pool contracts

Solidity contracts for Credit Pool (creditpool.fun): an ERC-20 wrapper for Credits (`SCORE`), a
`SCORE`/ETH Uniswap v4 pool with protocol-owned liquidity and a `POOL` farm, and the `POOL` token,
whose trading tax is burned or added to protocol-owned liquidity. Built with Foundry.

This repository contains the contracts deployed on Ethereum mainnet. The verified source of each
contract is also on Etherscan; the addresses are listed at creditpool.fun/how.html.

## Layout

- `src/` - the contracts.
  - `Builder.sol` - turns collected fees into protocol-owned liquidity.
  - `Burner.sol` - turns collected fees into burned `POOL`.
  - `CreditRouter.sol` - the Credits purchase router.
  - `HookBase.sol` - shared base for both hooks.
  - `MigratorBase.sol` - abstract claim-accounting base contract.
  - `PoolLaunch.sol` - the `POOL`/ETH pool launch.
  - `PoolOps.sol` - pool operations.
  - `PoolTaxHook.sol` - the v4 hook for the `POOL`/ETH pool: its tax is the trading fee, part burned in POOL inside the swap.
  - `PoolToken.sol` - the `POOL` token.
  - `ScoreGuard.sol` - the guardian/owner control surface.
  - `ScoreHook.sol` - the v4 hook for the `SCORE`/ETH pool (dynamic fee; the hook's tax is the trading fee).
  - `ScoreLens.sol` - read-only views.
  - `ScoreLiquidity.sol` - the bootstrap, the `SCORE`/ETH pool's protocol-owned liquidity, LP units, and the `POOL` farm.
  - `ScoreMath.sol` - shared math.
  - `ScoreToken.sol` - wraps Credits/Statements into the `SCORE` ERC-20, unwrappable back into the underlying.
  - `VenueGate.sol` - transfer venue containment for both tokens.

## Dependencies

Dependencies are git submodules under `lib/` (pinned; see `foundry.lock`). After cloning:

```shell
git submodule update --init --recursive
```

## Build

```shell
forge build
```

Solidity 0.8.26, optimizer 200 runs, via-IR, EVM `cancun`.

## Security

The contracts have been through a multi-pass internal security review. A review is not a guarantee of security; use at your own risk. See `LICENSE`.
