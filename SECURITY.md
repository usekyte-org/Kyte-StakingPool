# Security policy

Kyte holds user collateral in immutable, non-upgradeable contracts on Robinhood Chain. We take reports seriously and
respond quickly.

## Reporting a vulnerability

Email **contact@kyte.sh** with a description, the affected contract or component, and steps to reproduce. You will
get an acknowledgement within 48 hours and a status update within 7 days.

Please do not open a public issue for a security problem, and do not disclose publicly until we have confirmed a fix
or agreed on a timeline. We will credit you in the fix unless you prefer otherwise.

## Scope

- Contracts in [usekyte-org/kyte-contract-v2](https://github.com/usekyte-org/kyte-contract-v2) and
  [usekyte-org/Kyte-StakingPool](https://github.com/usekyte-org/Kyte-StakingPool) at the addresses in `CONTRACTS.md`
- The web app and indexer in [usekyte-org/Kyte-Market](https://github.com/usekyte-org/Kyte-Market) and at kyte.sh

Out of scope: issues in third-party protocols (Uniswap v4, Robinhood Chain, wallet providers) unless Kyte's integration
makes them exploitable, social engineering, and denial of service against public RPCs.

## What helps most

Loss or lock of user collateral, a way to exercise or expire a position that should not be possible, fee split or
buyback manipulation, staking reward accounting errors, and anything that lets a non-timelock address change protocol
settings.
