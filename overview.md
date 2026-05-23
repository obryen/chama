# Chama Architecture Review (Pre-Implementation)

**Date:** 2026-05-10
**Reviewer:** Architecture review session, working from Draft 1 of design doc
**Status:** Pre-code — review of the design, not the implementation

## Summary

The design doc is unusually mature for a pre-code spec. The mechanism is well-grounded in ROSCA prior art (Roscapolis / Kuri Finance), the worked example reconciles to zero, the invariants are stated precisely enough to encode in Foundry, and the threat model anticipates the standard adversarial behaviours. The biggest risks are not in the design — they are in the gaps the design defers to Bryan: the 7 open questions in §13 plus the absence of a concrete cycle-length, group-size cap, and audit budget.

Three categories of findings below: critical (block scaffolding), moderate (resolve before mainnet), and minor (post-v1).

## 🔴 Critical (Block Scaffolding)

### 1. Open questions in §13 are scaffold-blockers, not nice-to-haves

Of the 7 open questions, four are load-bearing for the contract surface:

- **Cycle length** decides immutable storage (`cycleLengthSeconds`) and the deadline arithmetic of every cycle window.
- **Group size cap** decides whether `members` is a fixed-size array vs. dynamic, and how aggressively to optimise the per-cycle distribution loop.
- **Pauser composition** decides whether `ChamaPauser.sol` is a 1-of-1 (de facto: Bryan), 2-of-3 multisig, or something else. This is also the v1 social-trust signal.
- **Audit budget** decides the size of the contract surface that's affordable to audit. A $30k budget realistically covers ~200–300 LOC of well-fuzzed Solidity. A $80k budget reaches ~600 LOC. This caps how much can ship in v1.

**Recommendation:** Get answers from Bryan before writing the first Solidity file. The design doc explicitly says "next step after sign-off on this doc" — sign-off is gated on these answers.

### 2. The (N − 1) × contributionAmount collateral bond is the load-bearing economic assumption — it deserves a worked stress test

§8 argues correctly that the bond covers the worst-case default ("won cycle 1, walked"). But it doesn't model what happens when the first cycle's winner defaults during cycle 1's commit window. The current text implies their collateral covers the missed contribution; but that collateral was sized to cover N−1 future contributions, not the cycle's pot shortfall plus the discount pool reduction.

**Recommendation:** Encode the collateral logic as a pure-Solidity simulator (not a contract — a foundry test harness) and run scenarios: default at cycle 1, cycle 2, cycle k; default by current-cycle winner vs. by an unpaid member; cascade defaults (two members default same cycle). Confirm INV-7 and INV-1 both hold in every case before committing to the bond formula.

### 3. INV-1 (Conservation) and INV-7 (Collateral sufficiency) are described as load-bearing, but their relationship is asymmetric

The doc correctly flags these as the two that "if they hold, most other failures cascade into them." But INV-7 holds only **after** `start()`, and INV-1 must hold from deployment forward. There's a window — between deployment and `start()` — where collateral is being collected but the rotation hasn't begun. INV-1 needs to be proven to hold in that window too, and the test harness should not skip it just because INV-7 isn't yet active.

**Recommendation:** Make INV-1 a continuous invariant from contract creation to selfdestruct (or to immutable closure). INV-7 is a state-conditional invariant. Document this distinction in the test harness.

## 🟡 Moderate (Resolve Before Mainnet)

### 4. `tick()` tip economics need bounding

§5 and §10 propose a small USDC tip from the discount pool to the address that calls `tick()` after a deadline. The tip is "fixed, capped" but the cap isn't specified. Two failure modes:

- Tip too low → no one calls `tick()` (gas > tip on Base). Cycle stalls.
- Tip too high → griefer races every cycle, draining discount pool from members.

**Recommendation:** Set tip = `min(0.10 USDC, 5% of discount pool)`. Validate against current Base gas costs (typically <$0.01/tx on L2, so 0.10 USDC is a 10x margin). Make the constant settable via a constructor arg, not a governance-changeable parameter.

### 5. Sealed-bid commit-reveal has a "no-reveal" griefing variant the doc partially addresses

§6.1 says a bidder who fails to reveal forfeits their commit deposit. Good. But this still lets a malicious bidder commit a very low (high-discount) bid, never reveal, and force the next-highest revealed bid to win — even though, at reveal time, the cycle's true winning bid would have been the un-revealed one. The malicious bidder loses their deposit but successfully manipulates which member receives the cycle k payout.

This is not a fund-loss attack but a **fairness attack**. It matters when members don't trust each other.

**Recommendation:** Either (a) make the commit deposit large enough that the manipulation is unprofitable in expectation (commit deposit ≥ expected delta in payout vs. fair winner), or (b) accept this and document it as a known limitation of first-price sealed-bid auctions, slated for Vickrey replacement in v0.4.

### 6. Pauser multisig's 30-day auto-lapse window interacts oddly with cycle length

If cycle length is 30 days (monthly chama, the cultural default), and the pauser pauses on day 1 of a cycle, the auto-lapse window expires exactly when the cycle would have completed. That's fine for a single pause, but if the pauser pauses every cycle on day 1, they can extend each cycle by ~30 days indefinitely without ever holding funds — they're just delaying everyone's payouts.

**Recommendation:** Either (a) make the auto-lapse window `min(30 days, 1 cycle length)`, or (b) cap total cumulative pause time per chama lifetime (e.g., "no more than 90 days paused across all pause events"). Lean toward (b) since (a) breaks if cycles are weekly.

### 7. `emergencyExit()` proration formula is hand-waved

§7's diagram says `emergencyExit` "prorates the treasury back to current contributors based on contributions less payouts received." This is a one-sentence sketch of a function that needs to be airtight — it's the failsafe of the failsafe.

Edge cases the design needs to specify:

- A defaulted member with already-slashed collateral: do they receive any prorated treasury?
- A member who received their full payout already: do they owe back any portion?
- Discount-pool credits: are they treated as "payouts received"?

**Recommendation:** Write `emergencyExit` math out as a separate spec doc before implementation. This function will be the most-audited piece of the contract because it's the one that runs when everything else has failed.

### 8. `ChamaFactory` registry strategy isn't specified

§11.1 says the factory "records all deployed chamas (useful for the frontend and for analytics)." But the on-chain registry pattern matters for v0.5 (open discovery) — if v1 only emits events without an indexed mapping, v0.5 has to backfill from logs. If v1 stores an array, gas cost grows linearly with all-time chama count.

**Recommendation:** Use indexed events (cheap, off-chain queryable via Ponder) for v1's needs. Defer on-chain mapping until v0.5, when there's a reason to read it from another contract.

## 🟢 Minor / Future

### 9. Storage packing of `MemberInfo` deserves a Foundry gas snapshot

§11.3 hints that `MemberInfo` should pack into a single slot. Worth confirming with `forge inspect` after the first draft and before audit. Saves ~20k gas per state-changing call.

### 10. `IStrategy` is empty in v1 but its shape constrains v0.2

The interface stub for `IStrategy` should at least sketch the v0.2 surface (`deposit`, `withdraw`, `reportYield`) so that v0.2 doesn't have to re-architect `Chama.sol` to plumb in a strategy.

### 11. No on-chain version metadata

`Chama.sol` should expose a `VERSION` constant (e.g., `"1.0.0"`). When v0.2 ships, frontends and indexers need to discriminate cleanly without reading bytecode.

### 12. `tick()` permissionless caller MEV exposure

If `tick()` becomes profitable to call (because of the tip), MEV searchers will arbitrage it. Probably fine — the tip is small and the work is real. But worth noting in the threat model so it's not a surprise.

## Strategic Observations (Beyond Engineering)

### A. The audit is the schedule

A 2–6 week audit at $30–80k is the long pole. Everything else can move in parallel; the audit is the gate. Decision needed early: **lock the auditor and put a deposit down even before the contracts are written**, because Trail of Bits / OZ / Spearbit have multi-month lead times.

### B. Pauser multisig is a social-trust artefact

V1 with a 1-of-1 pauser (Bryan only) is functionally a centralised system. The cultural-fidelity argument (chamas are trust-first) somewhat covers this, but on-chain visibility is unforgiving. **Find one trusted co-signer for v1**; the social signal of "two unrelated people can pause" is much stronger than "Bryan can pause."

### C. The ROSCA literature is rich — read it before audit

The doc cites Roscapolis / Kuri Finance. Before audit prep, read at least:

- Calomiris & Rajaraman (1998) on ROSCA defaults
- Besley/Coate/Loury (1993) on the economics of rotating credit
- Any post-mortem of past on-chain ROSCA exploits (there's at least one public hack post)

An auditor will ask if the design considered these.

### D. The "Kenyan-mobile UX" claim is doing a lot of work

The design correctly identifies AA/Pimlico as critical for KE mobile. But "WhatsApp-led onboarding" is hand-waved. The actual UX is: WhatsApp link → browser → wallet creation → social login → chama deep link → join. Every step has a drop-off. Worth wireframing this end-to-end before declaring v1's UX requirements done.

## Recommended Priority Order

1. **Close the 7 open questions** (Bryan, this week) — un-blocks scaffolding
2. **Lock auditor and put deposit down** (this month) — long lead time
3. **Find pauser co-signer** (this month) — social trust + actual safety
4. **Foundry scaffold + INV-1..INV-9 invariant tests first** — TDD on invariants
5. **Run collateral stress simulator** (Critical #2) — confirm bond formula
6. **Implement `Chama.sol`** until invariants pass
7. **Implement `SealedBidAuction.sol`** — separately testable
8. **Implement `ChamaPauser.sol`** with tuned auto-lapse window (Moderate #6)
9. **Wire frontend with Pimlico AA** in parallel with audit
10. **Audit → fixes → testnet end-to-end → phased mainnet**

## Related Pages

- Tech Stack
- Architecture Diagram
- Tech Debt / Open Questions
- Roadmap
