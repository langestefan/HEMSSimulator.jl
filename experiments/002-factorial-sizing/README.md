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

Everything else varies *across* named scenarios, all measured against one base case: south-facing,
10 kWh/workday of driving, a 12 kW charger, 3×25 A, 95% one-way battery, 92% EV charging.

A full factorial over these factors would be 4320 runs and, at the throughput this machine reaches
with every core loaded, about 27 hours. So scenarios are **sampled in waves**, each chosen in the
light of what the previous one found.

**Wave 1 — one factor at a time.** This is what buys the *sensitivity* of the sizing answer to each
factor, which is what the factorial was wanted for, at a fifteenth of the cost.

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

**Wave 2 — the interactions wave 1 structurally cannot see**, plus the commute level it skipped.
One-at-a-time answers "how much does this factor matter on its own"; it cannot answer "does a slow
charger matter *more* when the connection is small", which is what a household with both is asking.

| scenario | why |
|---|---|
| `mid-mileage` | completes the ladder: 5, 10, 15, 20 kWh/workday |
| `slow-charger+small-connection` | both limits on charging power at once |
| `high-mileage+slow-charger` | 20 kWh/day through 4 kW is 5 h that must fit the plugged-in window whatever the price does |
| `high-mileage+small-connection` | the largest load through the smallest connection |
| `east-west+small-connection` | wave 1 shows the export cap binding at 12 kWp south — is a different roof layout a cheaper answer than a battery? |
| `lossy+high-mileage` | the efficiency penalty where throughput is largest |

Waves are cumulative and the whole list is always run. That costs nothing: every simulation is
cached by content, so a wave already solved comes back from disk and only the new one goes to the
solver. **Adding a wave is an append to `WAVE_n` in `run-config.jl` and nothing else.**

14 scenarios × 5 × 10 = **700 annual simulations** at a 15-minute control step, 35 040 solves each.

## Tariff

Tibber 2025, no net metering, flat capacity tariff — the calibration in `../tibber.jl`, shared with
experiment 001 so the two studies price a kWh identically.

Savings and NPV are always measured against **the same home with the same array and no battery**, so
the cost of the panels cancels out. This study says what a battery is worth *given* an array, not
whether the array was worth buying.

## Running

```bash
julia --project=. -t auto experiments/002-factorial-sizing/run.jl   # ~4 h on 32 threads, cold
```

Simulation only — no plots, Makie never loaded. Watch it with:

```bash
tail -f experiments/002-factorial-sizing/data/solved.txt
```

`solved.txt` is appended to as each configuration finishes, one line per configuration with its
name, how long it took, and its headline numbers. It is an append log across runs, so the history
survives a re-run.

Results are cached (`simulate(...; cache = true)`), keyed by a digest of the system, the inputs and
the options. A crashed run resumes for the price of reading CSVs rather than re-solving, and so does
a re-run that only adds a wave. That costs disk: 700 years of 15-minute flows is a few gigabytes
under `simulation_cache_dir()`.

**Throughput is not linear in threads.** Measured on this machine: 228 s per configuration with 5
running concurrently, 498 s with 32. Thirty-two threads buy 2.7× the throughput of five, not 6.4× —
the solve is bound by memory bandwidth, not by cores. Estimates extrapolated from a lightly loaded
run will be roughly half of what a fully loaded one delivers.

## Output

`data/results.csv`, one row per configuration:

- **configuration** — `scenario`, `pv_kwp`, `battery_kwh`, and every factor that defines the scenario
- **energy** — annual import, export, base load, EV charge, battery throughput, curtailment, peaks
- **attribution** — `solar_to_*_share`: what became of the solar, as fractions of what the array
  *could* have produced (the five sum to 1, curtailment included, because a home that throws a third
  of its panels away is not using its solar well). `*_from_*_share`: where each sink's energy came
  from, per sink summing to 1.
- **self-sufficiency, two ways** — `demand_from_{solar,grid,battery}_share` is over *final demand*,
  the base load plus the car, which is what the household actually consumes. Read this one.
  `self_sufficiency` is the package's definition and covers the base load alone: it does not move
  with the commute at all, so at a given array every scenario here reports the same number. Both are
  in the table because the package's is what `kpis` returns and dropping it would be confusing;
  neither is wrong, they answer different questions.
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
