# Mercury — Deployed Addresses

**Network:** HyperEVM mainnet (chain ID **999**).

> Addresses are published here and source-verified on the HyperEVM explorer at
> launch. Every entry will link to its verified contract, whose source matches
> this repository byte-for-byte (`solc 0.8.24`, via-ir, optimizer 200 runs).
> ABIs for every contract — including the source-closed engine — are in
> [`abi/`](./abi).

| Contract | Address | Explorer |
|----------|---------|----------|
| `MercuryToken` | `0x1145d266ad5A9411fd47eC4d4d48bC265682A1F6` | [hyperevmscan](https://hyperevmscan.io/address/0x1145d266ad5A9411fd47eC4d4d48bC265682A1F6) |
| `Staking` | `0xeb9cC382631cFFd597caD6494aC80a631253752a` | [hyperevmscan](https://hyperevmscan.io/address/0xeb9cC382631cFFd597caD6494aC80a631253752a) |
| `TreasuryV3` | `0x3a648289259b9F12B3678E79E6Fa85e7Ab982002` | [hyperevmscan](https://hyperevmscan.io/address/0x3a648289259b9F12B3678E79E6Fa85e7Ab982002) |
| `AffiliateRegistry` | `0xC4C1c75185C3F4B583F2da0BFf7A74ec474f12c9` | [hyperevmscan](https://hyperevmscan.io/address/0xC4C1c75185C3F4B583F2da0BFf7A74ec474f12c9) |
| `LpTimelock` | _published at launch_ | — |
| `DrandSource` | `0x54f1d102a8F87F56645813F9C420C44f33258Bd0` | [hyperevmscan](https://hyperevmscan.io/address/0x54f1d102a8F87F56645813F9C420C44f33258Bd0) |
| `DrandBeacon` | `0x48187B3Ccd6f2E873617357F218036D30C89442C` | [hyperevmscan](https://hyperevmscan.io/address/0x48187B3Ccd6f2E873617357F218036D30C89442C) |
| `GridMining` | `0xa406a36648E0ca782dD2fFdEb4E2Ac9893A1a436` | [hyperevmscan](https://hyperevmscan.io/address/0xa406a36648E0ca782dD2fFdEb4E2Ac9893A1a436) |
| `AutoMiner` | `0xd09943A0f2573040b5B73ad23daC3E9e566120e6` | [hyperevmscan](https://hyperevmscan.io/address/0xd09943A0f2573040b5B73ad23daC3E9e566120e6) |

## Liquidity lock

The initial-liquidity LP position is held by `LpTimelock` for **6 months** from
launch (beneficiary = the team multisig). The lock can only be extended, never
shortened; `unlockTime()` is readable on-chain and on the explorer.

## Ownership

Privileged roles (token minter, treasury/keeper config, freeze keys) are held
by the team multisig. Several configuration keys are **frozen** on-chain at
launch per the deployment runbook, making them permanently immutable.
