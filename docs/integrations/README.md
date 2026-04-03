# RFQ Integration Guides

Symbiotic RFQ powers instant redemption for supported permissioned RWAs. Vault liquidity can already be allocated to Symbiotic Applications such as Cap and Nexus Mutual while also being deployed into passive-yield venues such as Morpho Vaults V2 or Aave V3. Instant redemptions add one more allocation surface: the vault fronts liquid collateral immediately, the user exits now, and the vault keeps the issuer redemption wait.

## Choose your path


| You are building...             | You own...                                                                             | Start here                                                              |
| ------------------------------- | -------------------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| A wallet or app for RWA holders | Wallet UX, approval flow, quote request, signature collection, order tracking          | [Integrate instant redemptions into your app](./integrate-to-redeem.md) |
| A solver or market maker        | Pricing, quote service, execution worker, onchain fill path                            | [Integrate as a solver](./integrate-to-solve.md)                        |
| A curator managing vault risk   | Vault setup, counterparties, limits, discount policy, signed discounts, pause controls | [Integrate as a curator](./integrate-to-curate.md)                      |


## How it works

1. The app (Symbiotic Swap frontend or your app) asks the Symbiotic backend for a quote.
2. The backend fans that request out to eligible solvers.
3. The user signs a Permit2 witness payload for the quoted bounds.
4. The backend reruns a hard RFQ, selects the winner, and binds the winning filler into the order.
5. The solver fills through `Reactor`.
6. `Reactor` pulls the user's RWA, routes it through the Instant Redemption Adapter, and enforces the signed outputs.
7. The adapter forwards the RWA into the deterministic `RedemptionAccount`, while the user receives liquid output immediately.

## Shared mental model

- Vault liquidity can support Symbiotic Applications, passive yield venues, and instant redemptions in parallel.
- Users pay a discount for speed. They exit now instead of waiting for issuer settlement.
- Curators decide how much vault balance is exposed, which counterparties may use it, and what pricing safeguards apply.
- Curators do not have to become solvers. They can also publish signed discounts that external solvers use for execution.
- Solvers compete to price and execute that orderflow.
- Solvers do not need to custody the permissioned RWA token in their own execution wallet.

