# Architecture

## Offering lifecycle
```
Issuer approved (Timelock, 48h)
        │
        ▼
factory.createX(params) ──► Offering clone + Escrow clone (compliance ON by default)
        │
        ▼  startTime
 Active ── buy() / commit() ─► investor approves OFFERING; offering pulls USDG → escrow.recordDeposit()
        │   (BatchAuction: commit window [+anti-snipe] → reveal window)
        ▼  end / sold out / reveal end
 finalize() (anyone / keeper)
        ├── soft cap missed / no demand ──► Failed ──► settle(): full refund (minus non-reveal penalty)
        └── success ──► Succeeded (deliveryDeadline = now + deliveryWindow)
                 │   settle(): early refund of excess deposit
                 ├── issuer deliver(): pulls exact tokensToDeliver, releases USDG (minus fee) ──► Delivered
                 │        settle(): tokens (or vesting schedule) + remaining refund
                 ├── deadline passes ──► markDeliveryFailed() (anyone) ──► Failed ──► full refunds
                 └── guardian cancel() ──► Failed ──► full refunds
 sweep(): once every participant settled, rounding dust → issuer
```

## Money flow invariants (tested)
- `usd.balanceOf(escrow) == escrow.heldPayment()` at all times.
- Before any release, refund or penalty, the escrow balance equals the funds raised.
- `releasedToIssuer == 0` unless the stage is `Delivered`.
- Delivered escrows hold enough sale tokens for every unclaimed allocation.
- Batch auction: Σ fills ≤ supply; cost ≤ ceil(fill × bidPrice); clearing matches a brute-force reference.

## Batch auction clearing
Bids sit on a price grid `price(tick) = minPrice + tick × tickSize`, with `tick < numTicks ≤ 400`. Reveals aggregate `demandAtTick`, `guaranteedAtTick` and `bidsAtTick`. `finalize()` walks ticks from the top:
- Find the first tick `c` where cumulative demand ≥ supply. Clearing price = `price(c)`.
  - Bids above `c` fill fully.
  - At `c`, the remaining supply `R` is filled first by guaranteed slots (`G`), then pro-rata over the non-guaranteed demand `M − G`. If `R < G`, guarantees themselves are pro-rated.
- If no tick reaches supply: undersubscribed. Every bid fills at the lowest revealed tick.
- Issuer proceeds = `floor((above + R − k) × P / unit)`, where `k` = number of marginal bids (each rounds down by < 1 unit), so the escrow is always solvent.

## Roles
- **Timelock** (`DEFAULT_ADMIN_ROLE` everywhere): approve issuers, fees, payment tokens, implementations, attestors, unpause, `setProjectToken`.
- **Guardian:** pause money-in, suspend issuers, freeze investors, cancel undelivered offerings.
- **Attestor:** write compliance attestations.
- **Anyone / keeper:** finalize, mark delivery failed, settle for an investor, sweep, distribute fees.
