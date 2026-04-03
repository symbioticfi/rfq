# Integrate As a Curator

This guide is for curators that want to allocate vault liquidity to instant redemptions while keeping risk policy in their own hands.

Instant redemptions give the vault another allocation surface alongside Symbiotic Applications and passive-yield venues such as Morpho and Aave. The curator uses Curator UI to decide how much liquidity is available, who can use it, and what pricing safeguards apply.

## What the curator does

- enable instant redemptions for the assets the vault wants to support
- get the issuer-facing redemption account for each supported asset and whitelist it with the issuer
- onboard a market maker (optionally)
- set pricing safeguards, limits, and pause controls
- decide whether pricing is solver-operated or curator-signed

## 1. Prepare the redemption account

Before live flow starts for a `(vault, tokenToRedeem)` pair:

1. Open the vault in Curator UI.
2. Get the deterministic redemption account with `getAccount(vault, tokenToRedeem)`.
3. Whitelist that address with the asset issuer.

That is the key external setup step. During execution, the user's RWA is forwarded into that whitelisted account, so solvers do not need to custody the permissioned asset.

## 2. Onboard a market maker

The curator sets a market maker for the vault. That market maker can then use multiple execution addresses to call `swap()` directly, so the flow does not depend on a single onchain caller.

If you want to operate pricing yourself, run your own solver or market-maker stack. If you do not, publish signed discounts and let external solvers execute against them.

## 3. Set safeguards and capacity

Curator UI exposes the levers that define how the path behaves:

- `Max. Pricing` per redeemable asset
- vault or adapter limits for the instant-redemptions path
- deallocation sources used to source liquidity, for example Morpho or Aave
- pause controls for stopping new instant-redemption draws immediately

`Max. Pricing` is the pricing safeguard. For example, a 3% minimum discount means 97% max pricing.

Together, these settings define how much capital the path can use and how aggressively it can price.

## 4. Use signed discounts without becoming a solver

Curators do not need to run solver infrastructure to define pricing.

In the signed-discount model:

- the curator signs a discount for a chosen duration
- external solvers execute against that signed discount
- replacing an old discount only requires a new signature

The backend wraps the curator-signed discount in a short-lived Symbiotic cosign before forwarding it to solvers. That keeps old discounts from remaining executable for long after they are replaced. An onchain invalidation path acts as the trust-minimized backstop.

### Discount API surface

The RFQ backend now exposes three discount endpoints:

- `POST /discount`
  Publish or replace the one live reusable discount for a `(vault, tokenToRedeem)` pair. The payload contains `Discount(vault, tokenToRedeem, discount, signer, protocol, nonce, deadline)` plus the signer signature. The signer can be the curator, the vault market maker, or a delegated filler that is currently authorized onchain.
- `GET /discounts`
  List all live discount-backed pairs. The response includes top-level `protocol` and, for each live pair, `discountId`, `maxRate`, and `maxAssets`.
- `POST /discounts`
  Resolve a live row by `discountId` or by `(vault, tokenToRedeem)` and receive a fresh 90-second protocol cosign for execution. The response returns the stored `Discount`, the signer signature, `protocolDeadline`, and the protocol signature over `DiscountSwap`.

On the solver-facing `/quote` path, discount-backed inventory is normalized into the same inventory shape as directly permissioned liquidity:

- `discountId`
  Present for discount-backed rows so the filler can resolve fresh signatures through `POST /discounts` immediately before submission.
  Directly permissioned rows keep `discountId: null`.

## 5. Understand the redemption lifecycle

After a fill:

- the user receives liquid output immediately
- the RWA is forwarded into the whitelisted redemption account
- redeemed assets arrive there later
- anyone can call `convertRedemption(...)` when conversion back into vault collateral is needed
- once collateral becomes deallocatable, it is pulled back into the vault automatically

Principal is restored first. Curator and protocol fees accrue only from positive realized reward.

## 6. Optional: acquire inventory instead of redeeming everything

The curator or market maker can prefund collateral into the instant-redemptions path.

When that happens:

- prefunded balance is used before additional vault allocation
- the matching share of incoming RWA stays as claimable inventory
- unused prefunded balance can be withdrawn later

This is the right mode when you want own inventory, not only redemption-driven yield.
