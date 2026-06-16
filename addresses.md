# Mercury — Deployed Addresses

**Network:** HyperEVM mainnet (chain ID **999**).

> Addresses are published here and source-verified on the HyperEVM explorer at
> launch. Every entry will link to its verified contract, whose source matches
> this repository byte-for-byte (`solc 0.8.24`, via-ir, optimizer 200 runs).
> ABIs for every contract — including the source-closed engine — are in
> [`abi/`](./abi).

| Contract | Address | Explorer |
|----------|---------|----------|
| `MercuryToken` | _published at launch_ | — |
| `Staking` | _published at launch_ | — |
| `TreasuryV3` | _published at launch_ | — |
| `AffiliateRegistry` | _published at launch_ | — |
| `LpTimelock` | _published at launch_ | — |
| `DrandSource` | _published at launch_ | — |
| `DrandBeacon` | _published at launch_ | — |
| `GridMining` | _published at launch_ | — |
| `AutoMiner` | _published at launch_ | — |

## Liquidity lock

The initial-liquidity LP position is held by `LpTimelock` for **6 months** from
launch (beneficiary = the team multisig). The lock can only be extended, never
shortened; `unlockTime()` is readable on-chain and on the explorer.

## Ownership

Privileged roles (token minter, treasury/keeper config, freeze keys) are held
by the team multisig. Several configuration keys are **frozen** on-chain at
launch per the deployment runbook, making them permanently immutable.
