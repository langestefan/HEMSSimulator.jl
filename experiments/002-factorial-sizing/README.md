# 002 — How big a battery, across arrays and households

Experiment 001 asked what battery to buy for *one* home. This one asks how that answer moves when
the home changes: a bigger array, a longer commute, a slower charger, a smaller connection, a
lossier battery.

## Design

Two things vary inside every scenario, because they are the decision:

| | values |
|---|---|
| PV | 0, 3, 6, 9, 12 kWp |
| Battery | 0, 2.5, 5, 7.5, 10, 12.5, 15, 20, 25, 30 kWh (all two-hour) |

Everything else varies *across* eight named scenarios, each a one-at-a-time deviation from a base
case (south-facing, 10 kWh/workday of driving, a 12 kW charger, 3×25 A, 95% one-way battery):

| scenario | what moves |
|---|---|
| `base` | — |
| `east-west` | array split across two roof faces at 90° and 270° |
| `low-mileage` | 5 kWh/workday |
| `high-mileage` | 20 kWh/workday |
| `slow-charger` | EV charger 4 kW instead of 12 kW |
| `small-connection` | 1×40 A (9.2 kW) instead of 3×25 A (17.25 kW) |
| `lossy` | battery 90% one-way, EV charging 85% |
| `efficient` | battery 97.5% one-way, EV charging 95% |

8 × 5 × 10 = **400 annual simulations** at a 15-minute control step, 35 040 solves each.

A full factorial over the same factors would be 4320 runs and most of a day. One-at-a-time buys the
*sensitivity* of the sizing answer to each factor — which is what the factorial was wanted for — at a
fifteenth of the cost. What it does not buy is **interactions**: this design cannot see whether a
slow charger matters more on a small connection. Where a scenario moves the optimum a long way, that
pair deserves a grid of its own.

## Tariff

Tibber 2025, no net metering, flat capacity tariff — the calibration in `../tibber.jl`, shared with
experiment 001 so the two studies price a kWh identically.

Savings and NPV are always measured against **the same home with the same array and no battery**, so
the cost of the panels cancels out. This study says what a battery is worth *given* an array, not
whether the array was worth buying.

## Running

```bash
julia --project=. -t auto experiments/002-factorial-sizing/run.jl   # ~1 h on 32 threads
```

Simulation only — no plots, Makie never loaded. Watch it with:

```bash
tail -f experiments/002-factorial-sizing/data/solved.txt
```

`solved.txt` is appended to as each configuration finishes, one line per configuration with its
name, how long it took, and its headline numbers. It is an append log across runs, so the history
survives a re-run.

Results are cached (`simulate(...; cache = true)`), keyed by a digest of the system, the inputs and
the options. A crashed run resumes for the price of reading CSVs rather than re-solving. That costs
disk: 400 years of 15-minute flows is a couple of gigabytes under `simulation_cache_dir()`.

## Output

`data/results.csv`, one row per configuration:

- **configuration** — `scenario`, `pv_kwp`, `battery_kwh`, and every factor that defines the scenario
- **energy** — annual import, export, base load, EV charge, battery throughput, curtailment, peaks
- **attribution** — `solar_to_*_share`: what became of the solar, as fractions of what the array
  *could* have produced (the five sum to 1, curtailment included, because a home that throws a third
  of its panels away is not using its solar well). `*_from_*_share`: where each sink's energy came
  from, per sink summing to 1.
- **economics** — annual bill, savings against the no-battery home, NPV, IRR, payback, effective
  lifetime (calendar or cycle-limited, whichever binds first), cycles per year

**Every share is a fraction in [0, 1], never a percentage.** `self_consumption` and
`self_sufficiency` are fractions, and one table with two conventions in it is a trap.

`data/best-by-scenario.csv` is the NPV-maximising battery for each (scenario, array) pair.

## Reading the numbers

Adjacent battery sizes are not reliably distinguishable. The dispatch LP is degenerate and the
receding horizon amplifies it — see the tie-break notes in `CLAUDE.md` — leaving roughly €0.4/year of
solver-dependent noise in the annual bill, which is comparable to the NPV gap between neighbouring
candidates. The *shape* of the curve is trustworthy; a €6 difference between 7.5 and 10 kWh is not.
