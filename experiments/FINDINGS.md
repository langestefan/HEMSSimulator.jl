# Findings

What the studies in this directory have established, with the numbers and the caveats. One entry per
finding, newest section last. **Every number here is reproducible from committed data** — the
experiment and table it came from are named so a disputed figure can be checked rather than argued
about.

Read this alongside `CLAUDE.md`, which holds design decisions and traps. This file holds *results*.

House rules for entries:

- Give the configuration, not just the number. "€94/year" means nothing without "6 kWp, 10 kWh,
  24 h horizon, 2025 Dutch prices, no net metering".
- Say what would change it. A finding with no stated sensitivity is an anecdote.
- **Record corrections in place.** Two figures below were wrong when first produced and are marked
  as such. A findings file that quietly overwrites its mistakes teaches nobody anything.

---

## 1. Sizing: what a battery is worth (experiment 002)

1 900 annual simulations, 38 scenarios × 5 array sizes × 10 battery sizes, 2025 Dutch day-ahead
prices on the Tibber calibration, no net metering unless a scenario says otherwise.

**The sizing rule is roughly one kWh of battery per kWp of array, plus a fixed 3 kWh.** Fitted across
all scenarios at €400/kWh and 0% discount: `kWh = 3.2 + 0.99 × kWp`, residual spread 1.8 kWh. The
slope steepens as batteries get cheaper — at €200/kWh it is `6.6 + 1.87 × kWp` — and flattens sharply
with the discount rate, to `2.9 + 0.53 × kWp` at 4%. Source: `investment.jl`, sizing-rule table.

**Regulation dwarfs everything about the house.** Effect on the best case's NPV against the base
scenario, averaged over array sizes:

| factor | Δ NPV |
|---|--:|
| net metering restored | +2 785 |
| flat tariff *and* net metering | −3 324 |
| flat tariff (no dynamic prices) | −2 306 |
| V2G enabled | −1 397 |
| time-of-use transport | +762 |
| household size ±1 500 kWh | ±~620 |
| round-trip efficiency 90% vs 97.5% | ~900 across the range |
| roof orientation (east-west vs south) | −564 |
| commute length, connection size | ±~50 |

Two of these are worth stating outright. **A flat tariff destroys more value than the end of netting
creates** — dynamic pricing is what the battery is monetising. And **V2G costs €1 397** because the
car competes with the home battery for the same surplus, so the battery earns less.

**Commute length is nearly irrelevant to sizing.** Doubling the car's mileage moves annual imports by
2 442 kWh and the battery's NPV by €2. Mileage moves your bill, not your battery decision.

**With no solar, a battery loses money at today's prices** — NPV −€371 for 5 kWh — but the gap is not
large. Break-even is €326/kWh installed against roughly €400 today. Source: `breakeven.csv`.

**Adjacent battery sizes are often not distinguishable.** Median gap to the runner-up is €55, and 14
of 70 (scenario, array) pairs have their top two within €25. The curve's *shape* is reliable; the
peak's exact location at 9 kWp is not. `summary.jl` lists the affected pairs.

**The candidate grid stops at 30 kWh, and below ~€250/kWh the optimum runs into it.** Those cells
read "at least 30", not "30". Deliberate: see the README.

---

## 2. Foresight: what knowing the future is worth (experiment 003)

360 annual simulations, 6 forecast qualities × 4 planning horizons × 3 arrays × 5 batteries. The
controller optimises each window against a *belief*; asset setpoints are implemented as commands and
the meter absorbs the error.

**Horizon dominates accuracy by roughly an order of magnitude.** At 6 kWp with a 10 kWh battery, all
with perfect foresight:

| lookahead | annual bill |
|---|--:|
| 1 h | **infeasible** |
| 2 h | €618 |
| 3 h | €460 |
| 6 h | €267 |
| 24 h | €115 |
| 48 h | €44 |

A 1 h horizon is not merely poor — the controller cannot see the EV's departure deadline in time to
charge for it, so the problem has no solution. There is a hard floor on how myopic a controller with
a car in the house can be.

**Price knowledge is worth ~8× weather and load knowledge.** At the 24 h horizon, against perfect
foresight: prices unknown (±30%) costs **€94/year**; weather and load wrong at realistic magnitudes
costs **€12/year**. Splitting the latter: solar alone €3.50, load alone €9.60.

> **Correction.** The weather-and-load figure was first reported as €3.10 and was wrong by about 4×.
> `NoisyForecast` ramped its error in over 12 hours, which gave the controller a 2.8% view of one
> hour ahead — nothing about a single household's 15-minute load is that predictable, and near-term
> accuracy is exactly what protects the evening discharge decision. The default is now a 1.5 h ramp.
> Measured directly: at the same saturation error, moving from a 12 h ramp to 0.5 h raised the annual
> cost from €3.06 to €13.05 and made the battery sell 34 kWh/year more than it should.

> **Scope correction.** The headline "a forecast is worth only tens of euros" was measuring the wrong
> quantity. It is the value of *accuracy*, given a controller that already has a 24 h horizon, exact
> day-ahead prices, and a perfectly known EV schedule. The value of *foresight itself* — horizon plus
> price knowledge — is in the hundreds.

**Sizing does not depend on foresight at all.** 10 kWh is optimal at 6 kWp in every forecast ×
horizon cell, from omniscient to poor. You do not need a forecast to size a battery, only to operate
one.

**Why solar forecasting is cheap here, mechanically.** With no net metering, import costs €0.2407 and
export earns €0.1073 on average, and export never exceeds import in any of the 35 040 intervals. So
"absorb surplus, release to load, never grid-charge" is optimal whatever tomorrow holds — a *policy*,
not a plan. Forecasting only earns money where the controller must commit before knowing: reserving
for the night, and timing arbitrage. **This explanation is under test and should not be quoted until
the entry below is filled in.**

---

## 3. The car is worth more than the forecast (and nearly as much as the battery)

6 kWp, 2025, no net metering, 24 h horizon. The same car — 60 kWh, 12 kW charger, 2 863 kWh/year —
treated two ways: scheduled by the EMS, or charging flat out on plug-in with the EMS able to see the
profile but not move it.

| | no battery | with 10 kWh battery | battery saves |
|---|--:|--:|--:|
| EMS schedules the car | €634 | €115 | €519 |
| car charges dumb | €995 | €379 | €616 |

**Scheduling the car is worth €361/year without a battery and €264/year with one.** That is roughly
70% of what the whole 10 kWh battery earns (€519), and about 30× the value of weather-and-load
forecast accuracy (€12). It is the largest single controllable figure in these studies.

**The battery partly substitutes for a smart charger.** It saves €616 against a dumb charger versus
€519 against a scheduled one — €97 more, because there is more mistiming to clean up. The two
investments are partly redundant, and the charger is the cheaper of the two.

**Anticipating the car is worth almost nothing; controlling it is worth everything.** Adding a third
arm — the EMS blind to the charging until the meter sees it (`HiddenLoad`) — separates the two:

| EMS | no battery | with 10 kWh battery |
|---|--:|--:|
| sees the charging profile coming | €995 | €379 |
| blind to the car until it draws | €995 | €385 |

**€6/year for anticipation against €361 for control.** The mechanism is that the battery is already
full of solar by evening, so when the car starts drawing the battery discharges into it as a
*reaction*; no plan is required. Anticipation would only pay if the charge had to be held back from
something else, or bought cheaply in advance — and with import at €0.24 against export at €0.11, grid
pre-charging almost never pays while solar charging happens regardless. The no-battery row is the
sanity check: identical either way, because with no storage there is nothing to plan with.

This is also what settles the "underestimate the night by 5 kWh" question. The predicted loss needs
the controller to be unable to cover the surprise; it can, because the storage it would have reserved
is already charged. What costs money is the car charging at the wrong *time*, and only control fixes
that.

**The split holds without sun and in winter.** The €6 rested on one well-lit configuration and on a
mechanism — "the battery is already full of solar by evening" — that must fail when there is no sun.
Tested across four cases:

| case | control | anticipation |
|---|--:|--:|
| full year, 6 kWp | €263 | €6 |
| full year, 0 kWp | €239 | €20 |
| December, 6 kWp | €212 | €10 |
| December, 0 kWp | €224 | €8 |

Anticipation triples without solar, so the mechanism is real — but it is *minor*. The dominant reason
is simpler: **a car plugged in at 19:30 has twelve hours before it leaves, and the cheapest hours of
the day sit inside that window.** Reserving charge in advance and discovering the car and buying at
03:00 cost nearly the same, because the deadline is loose. December with no solar — the darkest,
flattest case — gives anticipation its *lowest* value of all, €8.

**Control is stable at €212-263 across every case**, with sun and without, midsummer and midwinter.
That is the robust finding: integrate the charger, do not bother predicting the car.

(December rows annualise a single month, so their *levels* read pessimistically; only the gaps
between arms are meaningful.)

**Arrival time trades the two capabilities against each other.** Holding departure fixed at 07:30 UTC
and moving only the return:

| car returns (local summer) | control | anticipation |
|---|--:|--:|
| 17:30 | €184 | €7 |
| 19:30 | €263 | €6 |
| 21:30 | €206 | €9 |
| 23:30 | €146 | €27 |

Anticipation quadruples for a car arriving at 23:30 — it plugs in *after* the battery has spent
itself on the evening peak, so a controller that knew would have reserved charge. That is a real
effect and earlier tests missed it by only trying convenient arrival times.

Control moves the opposite way, and for a clean reason: a dumb charger firing at 19:30 dumps 12 kW
into the evening peak, the worst possible moment; the same charger firing at 23:30 is already in
cheap hours and costs much less to leave alone. **Control still wins at every arrival time, by 5x at
worst** — but the two are substitutes, not independent goods.

> **Method note.** An earlier attempt to test this with a 5 kWh absolute night underestimate was
> void: believed load is clamped at zero and the night contains 1.04 kWh, so 1, 2.5, 5 and 10 kWh
> errors all collapsed to the same 1 kWh error and returned the same €8.90. A percentage or an
> absolute offset on the *base load* cannot express a car-sized event. `HiddenLoad` can.

---

## 4. A longer horizon helps the car, not the battery

6 kWp, perfect foresight, bill in EUR by battery size and planning horizon:

| window | 0 kWh | 5 kWh | 10 kWh | 15 kWh | 20 kWh | best | battery saves |
|---|--:|--:|--:|--:|--:|:--:|--:|
| 24 h | 634 | 306 | 115 | −18 | −104 | 10 kWh | 519 |
| 36 h | 606 | 278 | 84 | −49 | −137 | 10 kWh | 522 |
| 48 h | 540 | 224 | 44 | −80 | −166 | 10 kWh | 496 |
| 72 h | 520 | 204 | 24 | −96 | −179 | 10 kWh | 496 |

**The NPV-optimal battery is 10 kWh at every horizon**, so experiment 002's sizing answer is not an
artefact of the 24 h window it happened to use.

> **Correction.** It was claimed earlier that a 48 h window beats 24 h by €71/year and that
> experiment 002 therefore *understates* the battery. The first half is right about the bill and the
> second half is wrong. The battery's saving is flat at €496-522 across all four horizons: the bill
> falls by €114 from 24 h to 72 h, but the **no-battery arm falls by the same €114**. Every NPV in
> 002 is a difference between those arms, so the horizon cancels and the published NPVs stand.

The extra lookahead accrues almost entirely to scheduling **the car** — consistent with everything in
section 3. Returns diminish (24→36 h buys €28, 36→48 buys €66, 48→72 buys €20), and the gain shown
is an upper bound: prices are held perfect across the whole window here, while a 72 h plan reaches
almost entirely past what the day-ahead auction publishes.

---

## 5. Known gaps — things the model currently hands the controller for free

These are not caveats on the findings above; they are reasons some of those findings may be
optimistic, listed so they are not forgotten.

**The EV schedule is known exactly.** `connected`, `trip_kwh` and `target_kwh` are properties of the
asset, not of the forecast, so in every run to date the controller knows precisely when the car plugs
in, when it leaves, and how many kWh it needs. For a 60 kWh car on a 12 kW charger this is probably a
larger gift than the weather. **It is also the only place a night misjudgement of the size that would
actually cost money can come from**: this model's base load between midnight and six is 1.04 kWh, so
a 50% night error is half a kilowatt-hour and cannot cost anything, while a car is a 5-15 kWh
question. Quantifying this is the current open task.

**Prices are known across the whole window.** Defensible but only partly: the Dutch day-ahead auction
clears around midday for the following day, so at 08:00 the controller knows 16 hours ahead and at
11:00 only 13. A 24 h plan therefore reaches past the published horizon for much of the day, and a
48 h plan almost always does. The €44 bill at a 48 h horizon is optimistic in a way the €115 at 24 h
is not.

**The EV drives on UTC, and it costs 2.3%.** *(Measured, and left in place deliberately.)*
`ev_schedule` reads `departure_hour` and `return_hour` off UTC timestamps, so the nominal
07:30-17:30 commute is really 08:30-18:30 local in winter and 09:30-19:30 in summer. The package can
now do it properly — `ev_schedule(...; clock = :dutch)`, backed by `dutch_hours` — but the default
stays `:utc` because changing it invalidates every cached simulation in every study already run.

Measured at 10 kWh: the corrected schedule lowers the annual bill by €5.70 at 0 kWp, €11.90 at 6 kWp
and €12.50 at 12 kWp — **a consistent −2.3% of the battery's saving, in the direction that flatters
the battery.** Every figure in this file is therefore mildly pessimistic.

It is not re-run because the effect is uniform in sign and nearly uniform in magnitude, so every
candidate moves together: the sizing rule, the factor ranking, the EV control figures and the
forecast decomposition are all unchanged in ordering. Switch the experiments to `:dutch` at the next
occasion that re-solves anyway — a new wave, a new price year, or numbers going to publication.

*Note on the threshold that decided this:* the rule first proposed was "re-run if the shift exceeds
the solver noise floor", which it does by 30x. That was the wrong test. The right one is whether a
conclusion moves, and none does.

**The old note, for the record.** `ev_schedule` reads `departure_hour` and
`return_hour` off UTC timestamps, so the default 07:30-17:30 is really 08:30-18:30 local in winter
and 09:30-19:30 in summer — a schedule that drifts an hour with the season and is later than a
typical Dutch commute. The same trap was handled correctly for the time-of-use transport tariff
(`dutch_peak` resolves DST) and never applied to the car. It matters most for the evening peak
overlap, and therefore for exactly the reserve-for-tonight decision the forecast work is about.

**Forecast errors decorrelate over 6 hours.** A genuinely bad forecast day — the front arrives late,
the whole afternoon is overcast — biases a full day in one direction.

**One weather year, one price year.** 2025: spot averaged 8.7 ct/kWh with 2 325 negative
quarter-hours. A year with wider spreads moves every arbitrage number here.

**Perfect solver foresight is not the same as a perfect controller.** The LP is degenerate and the
receding horizon amplifies it; roughly €0.4/year of the annual bill is solver-dependent noise. See
`CLAUDE.md`.
