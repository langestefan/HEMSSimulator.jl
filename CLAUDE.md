# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A home energy management system simulator for Dutch households, built on JuMP. It dispatches a
home's controllable assets — battery, EV, heat pump, hot water tank — at 15-minute resolution over a
year, and bills the result under Dutch rules. The headline application is what battery size is worth
buying, under a given tariff and regulatory scenario.

The package was called `BatteryBusinessCase` until the asset set outgrew the name; the UUID is
unchanged.

Scaffolded from [BestieTemplate.jl](https://github.com/JuliaBesties/BestieTemplate.jl) (copier
answers in `.copier-answers.yml`). Minimum Julia is 1.12.

## Architecture

Five layers, each testable alone. Data flows one way:

```text
weather + prices + load
   → prepare      → SimulationInputs   exogenous series, computed once for the whole horizon
   → simulate     → SimulationResult   receding horizon: solve 48 h, keep 24 h, carry state
   → settle       → Bill               annual netting, energy tax, transport, VAT
   → kpis / sweep → business case
```

Two separations carry the whole design, and breaking either will cause trouble:

**Dispatch and settlement are separate.** The JuMP objective sees only a simple per-interval price
(`dispatch_prices`). The bill is computed afterwards from the flows (`settle`). This is not
stylistic: annual netting (*salderen*) couples all 35 040 intervals of the year, so a
receding-horizon objective structurally cannot represent it. The settlement engine is authoritative
for reported economics; the dispatch price is only a control signal. It also means the four headline
scenarios — netting on/off × fixed/time-varying transport tariff — are four `Contract` values with
no branching in the engine.

**Sizing is a sweep of simulations, not a decision variable.** `sweep` runs a full simulation and
settlement per candidate battery so every candidate is judged under the real billing rules.

### `src/` layout

Include order in `src/HEMSSimulator.jl` is significant; each directory depends only on the
ones above it.

| Directory | Holds |
|---|---|
| `core/` | `TimeGrid` (the 15-min grid everything aligns to), `resample` (`StepHold`/`LinearInterp`), the `AbstractAsset` contract, `RunOptions`, `DispatchContext`, `show` methods |
| `solar/` | `Site`/`Weather`, Erbs decomposition, transposition models (`Isotropic`/`HayDavies`/`Perez`), clear-sky reference, `PVArray` and production, `upsample_irradiance` |
| `building/` | The house as an RC thermal network: `BuildingSpec`, continuous-to-discrete state space |
| `assets/` | Controllable assets: `battery.jl`, `ev.jl`, `heatpump.jl`, `dhw.jl` |
| `market/` | `Contract` and grid tariffs, `NL_TARIFFS_2025`, the four `scenarios`, the settlement engine, NPV/IRR/payback |
| `model/` | `HomeSystem`/`SimulationInputs`, the JuMP window model, `SimulationResult`, the rolling-horizon driver |
| `analysis/` | The sizing sweep and the idealised sizing LP |
| `io/` | Response cache, Open-Meteo and ENTSO-E loaders, CSV schema, synthetic generators |
| `plots.jl` | Plotting: colours, window arithmetic, per-asset state descriptions — **stubs only**, see below |

### Adding an asset

Assets are anything the optimizer *decides about*. PV and the base load are not assets — they are
exogenous data in `SimulationInputs`. To add one, implement the contract documented on
`AbstractAsset` (`src/core/types.jl`): `initial_state`, `add_variables!`, `add_constraints!`,
`power_terms`, `cost_terms`, `carry_state`, `result_columns`, plus `consumption_columns` and
`production_columns`. `dispatch.jl` collects `power_terms` into the single meter balance and
`cost_terms` into the objective, so nothing else needs to change.
`src/assets/battery.jl` is the reference implementation; `src/assets/ev.jl` shows an asset whose
schedule spans the whole horizon and is sliced per window via `ctx.offset`.

**Do not skip `consumption_columns`/`production_columns`.** `balance_residual`, `self_consumption`
and `self_sufficiency` rebuild the balance from the *result frame*, not the model. An asset that
does not declare them is invisible to them, and the residual silently shows the asset's full power
as an accounting error — which is exactly how the EV's first draft looked.

### Things that will bite you

- **The LP is massively degenerate, and the receding horizon amplifies it.** Step-holding an hourly
  price onto quarter-hours makes **19 753 of 2025's 35 040 adjacent intervals exactly equal**, so more
  than half the year offers the optimizer a free choice of when to charge. Every solver finds an
  optimum — HiGHS with and without presolve and Clp agreed to 5e-15 — but they picked *different
  vertices*, differing by 11 kW (a whole EV charger) in individual intervals. That is invisible to the
  controller and visible to the bill, because `settle` reads the flows and not the objective: the same
  year came out EUR 226.58 / 227.02 / 227.53 depending on the solver, a 0.4% spread that is **wider
  than the NPV gap between adjacent battery sizes**.

  It compounds, too. A different tie in one window carries a different state into the next, so the
  trajectories diverge rather than staying a perturbation apart — which is why whole-run totals move
  far more than any per-window difference would suggest.

  `RunOptions.tie_break` (default 1e-6 EUR/kWh **per interval of delay**) prices a tiny preference for
  acting earlier and makes each window's optimum unique. **It does not buy solver independence, and
  do not claim that it does**: per window from an identical starting state the solvers now agree
  exactly (0.0000 kW across 60 sampled windows), but over a full year HiGHS with and without presolve
  still land EUR 0.42 apart, against EUR 0.51 before. Uniqueness to 1e-9 is not identity, and 35 040
  feedback steps amplify the remainder. There is also a second class of tie it does not touch: the
  term prefers acting *earlier* but says nothing about *which source* serves a sink, so discharging
  the battery against importing at equal marginal cost is still a free choice.

  What it does buy is reproducibility for a fixed solver configuration, at no measurable cost — the
  dispatch cost of a single window is unchanged to 1e-6.
  Note the *per interval*: an earlier version spread the same total across the window, which put the
  step between neighbours below HiGHS's 1e-7 dual tolerance, and the term was silently ignored. The
  bound is two-sided and both ends are measured — above 1e-7 to be seen at all, below the smallest
  real price difference between neighbours (1.21e-5 EUR/kWh in this data) to not override economics.
- **The LP is degenerate under negative prices.** It avoids charging and discharging at once only
  because wasting energy costs money; negative day-ahead prices (common in NL) make it profitable.
  `RunOptions.check_degeneracy` warns, `RunOptions.exclusive` adds the binaries that fix it. Under
  full netting buy and sell prices are equal, which is why `RunOptions.price_epsilon` exists.
- **Terminal value matters — but only when the step is a large fraction of the window.** Without
  valuing end-of-window storage the 48/24 receding horizon empties the battery every day; measured
  on a June week, a 10 kWh battery's savings collapse from 622 to 424. In MPC geometry (24 h window,
  15-minute step) the opposite holds: the window end is never implemented, so the credit only makes
  the optimizer hoard, and leaving it on costs about 10% of the savings. Set
  `terminal_value = false` whenever the step is small relative to the window.
- **A 15-minute step buys nothing over an hourly one, and costs 4x.** Same June week, same battery:
  411.5 / 622.3 EUR of savings at both steps, to four significant figures.
- **Self-consumption is attributed per interval** (`min(PV, on-site demand)`). Total export is not a
  proxy for un-consumed PV once a battery can export grid-charged energy.
- **Synthetic weather cloudiness is bimodal on purpose.** A constant clearness index puts Erbs
  permanently in its high-diffuse regime, giving an 85%-diffuse sky where array tilt barely matters.
- **Open-Meteo stamps radiation at the *end* of its hour** (mean over the preceding hour) while
  stamping temperature instantaneously, so radiation timestamps are shifted back by
  `OPENMETEO_RADIATION_LAG` before resampling. This is verified empirically by a test that compares
  the irradiance-weighted centre of a recorded day against the clear-sky centre — not assumed.
  Open-Meteo also defaults wind to km/h; the loader asks for m/s.
- **Every physical limit an exogenous input can push past needs a slack.** The tank's draw is not
  optional data: an empty tank cannot deliver hot water, so a hard energy floor turns a heavy draw
  into `INFEASIBLE`. `WaterTank` therefore has two slacks with different prices — `shortfall`
  (delivered below the minimum temperature) and `unserved` (not delivered at all). Same lesson as
  the comfort band.
- **The COP models clamp to `cop_min = 1.5` by default.** Fine for a heat pump, silently wrong for
  a resistive element — `LinearCOP(reference = 1.0, slope = 0.0)` gives a COP of 1.5, not 1.0.
- **A battery's lifetime can be set by cycling rather than by the calendar.**
  `Investment.rated_cycles` (default `Inf`, so this is opt-in) turns `lifetime_years` into a calendar
  *cap*: `effective_lifetime` takes whichever of the two runs out first, and `kpis` reports which one
  did. It matters in a sizing sweep because the small candidates store the same daily surplus as the
  large ones and so cycle far more times *per kWh installed* — a fixed horizon flatters exactly the
  candidates that would need replacing first. On the 2025 study the observed range is 334 cycles/year
  at 2.5 kWh down to 229 at 15 kWh, so a rating below about 5000 cycles starts to bind on the small
  end. At the 6000 of a typical LFP warranty, none of them bind.
- **`degradation_cost` never reaches the bill.** It is in the dispatch objective, so it shapes how
  hard the optimizer cycles storage, but `settle` knows nothing about it and `sweep`'s savings do
  not pay for it. Wear belongs in `Investment` (`lifetime_years`, `capacity_fade`); charging it in
  both places would double-count. The visible consequence is that `size_lp`, whose objective *does*
  include it, under-sizes against `sweep` unless its template has it at zero — 3.14 kWh versus 5.12
  on the same month.
- **The comfort band is soft, and asymmetric.** Falling below it is discomfort and costs
  `comfort_penalty`; rising above it costs `overheat_penalty`, an order of magnitude less, because a
  house coasting down to a night setback is above the band and nobody minds. At parity the optimizer
  would rather be cold at 06:00 than pre-heat at 05:00, which is the wrong trade. A hard band would
  also turn an undersized heat pump into `INFEASIBLE` instead of a number of degree-hours.
- **Terminal value is for storage, not for a car.** `Battery` needs it or the receding horizon
  empties it every window. `ElectricVehicle` does not — its departure targets already anchor the
  trajectory — and crediting its stored charge made it profitable to fill 60 kWh whenever the price
  dipped below the window median, inflating a synthetic week's charging by 26 kWh. It is therefore
  applied only when V2G is enabled.
- **Netting and transport are billed differently, and it matters.** *Salderen* absorbs the commodity
  price and the energy tax; the transport tariff is charged on physical flow and is never netted
  (`settle`). So a time-of-use transport tariff rewards a battery in *both* netting regimes — the
  four scenarios are two independent levers, not two versions of one. On the synthetic fortnight the
  effects are about +20% (time-of-use transport) and +65% (ending netting) on annual savings.
- **Tariff defaults are dated.** `NL_TARIFFS_2025` holds them; `energy_tax` and `tax_credit` change
  every Belastingplan, and `capacity_tariff`/`standing_charge` are representative rather than
  published figures. Never quote a business case without overriding them.
- **Resampling is chosen per quantity, never uniformly.** Prices are step-held (a quarter-hour in an
  hourly-settled period cleared at that hour's price); temperature and wind are interpolated at
  interval midpoints; irradiance goes through the clearness index and conserves each source
  interval's energy exactly. DNI is always re-derived from GHI and DHI, never interpolated.

## Performance

Measured on a full synthetic year (35 040 intervals, 366 windows of 48 h):

| System | Total | In HiGHS | Building the model |
|---|--:|--:|--:|
| PV + battery | 4.3 s | 1.7 s (40%) | 2.6 s |
| PV + battery + EV + heat pump + DHW | 20.9 s | 14.0 s (67%) | 6.9 s |

**Where the time actually goes, measured per window on the 2025 study (24 h window, 15-min step,
PV + battery + EV, 864 variables):** `build_window` 0.95 ms, the driver's own bookkeeping 0.14 ms,
`optimize!` 6.15 ms — of which HiGHS's `solve_time` is only 3.3 ms. The missing ~2.9 ms was the MOI
caching layer being **copied** into the solver at `optimize!`. Neither building nor solving: copying.

`RunOptions.direct` (default `true`) removes it with JuMP's `direct_model`. Building gets slower —
every variable goes straight to the solver instead of into a cheap cache — but `optimize!` nearly
halves. Measured over a full year: 268 → 227 s with the EV, 182 → 150 s without, and HiGHS's own time
unchanged, which is the tell that the saving is all copy. A test compares every numeric column of a
four-day run between direct and cached mode; skipping a layer whose only job is to hold a copy must
not move a number.

The cost is that a direct model has **no bridges**. HiGHS takes everything this package builds, so
this is free here; a solver that needs a constraint reformulated wants `direct = false`.

**`MOI.Parameter` is not the way to reuse a model here**, despite the plan below. HiGHS does not
support parameters natively (`MOI.supports_constraint(..., MOI.Parameter{Float64})` is `false`), so
they exist only through a bridge — and a direct model has none, rejecting them with
`UnsupportedConstraint`. Using them means going back to the cached `Model` and handing back the 15%
direct mode just won. The API that does work in direct mode is in-place modification:
`set_objective_coefficient`, `set_normalized_rhs`, `set_upper_bound`.

The prize for reuse is real and larger than the build: re-solving one model after moving only the
objective costs **0.66 ms against 2.31 ms cold — 3.5x** — because HiGHS keeps its basis. What stops
it is that the model's *structure* changes between windows: the EV's connection mask and departure
targets, the heat pump's moving comfort band, and a final window shorter than the rest. Every asset
would need an `update!` beside `add_constraints!`, holding constraint references and re-pointing
every window-dependent number, and would have to be re-expressible with a fixed constraint set. That
is a change to the `AbstractAsset` contract, which is the thing kept deliberately small.

The original plan assumed model *construction* dominated and that reusing one model across windows
via `MOI.Parameter` would be the first lever. That was true of the thin slice and is not true now:
once the house has a realistic set of assets, two thirds of the time is inside the solver, so model
reuse would attack a third of the cost for a large, invasive change to the asset contract. It has
not been done, deliberately.

What was done is threading the sweep, which attacks all of it: `sweep(...; threaded = true)`, the
default when `Threads.nthreads() > 1`. Eight candidates over a year went from 30.7 s to 7.5 s, a
4.1x speedup — bounded by the candidate count, not the core count, and with the baseline simulation
still serial. Start Julia with `-t auto` or it does nothing. A test asserts the threaded and serial
tables are identical.

**Threading is strongly sublinear, and a lightly loaded measurement will not tell you that.** On the
32-core machine this is developed on, one annual configuration (PV + battery + EV, 15-minute step)
takes **228 s when 5 run concurrently and 498 s when 32 do**. Thirty-two threads therefore deliver
2.7x the throughput of five, not 6.4x: the solve is bound by memory bandwidth, not by cores, and
loading every core more than doubles each individual solve. Experiment 001's sweep — 5 candidates —
measured 90% per-worker efficiency, and extrapolating that to 32 workers under-predicted a 400-run
study by a factor of two and a half. Size a study from a *saturated* measurement, never from a
sweep narrower than the core count.

The other lever is **not solving the same configuration twice**, which a study does more than it
looks. `sweep` returns a table and discards every `SimulationResult` it computed, so `run.jl` then
re-solves two of them — its no-battery baseline *is* the sweep's baseline, and its reference battery
*is* one of the candidates — and `explore.jl` re-solves all twelve, because what reaches disk is
aggregate tables and three-day slices, never a full year of flows. Sixteen year-solves for twelve
distinct cases, then twelve more.

`simulate(...; cache = true)` fixes all of it: results are stored under `simulation_cache_dir()`,
keyed by a SHA-256 of `(system, inputs, options)` — exactly what `simulate` reads, which is why the
contract is absent from the key. Points worth not undoing:

- **The digest walks structs by reflection, not through `show`.** The `show` methods here are
  readable summaries, and a summary that omits a field would let a changed input hit a stale entry.
  Anything `_digest!` cannot reduce throws rather than falling back to `hash`, which is not stable
  across sessions.
- **It is off by default.** A cache that is on without being asked for is one that eventually answers
  a question it was not asked; the experiment scripts opt in, the test suite does not.
- **Frames are CSV, not Arrow.** Julia writes shortest-round-trippable floats, so a year round-trips
  bit-exact — a test asserts it, because a cache that loses the last bits silently changes every bill
  computed from it. Arrow would be smaller and faster and is not worth a dependency at this size.
- Writes go to a temp file and are renamed, so a reader never sees half a frame and two threads
  racing on one key leave one intact entry.

## Strategies

`RunOptions.strategy` selects what the controller optimizes. It is two weights, not a branch — see
`objective_weights` — so adding one means a method rather than an `if` in the model builder.
`EconomicStrategy` is (0, 1) and reproduces the objective exactly as it was before strategies
existed; `GreenStrategy` is (1, ε).

Green needs no rule against grid-charging: charging from the grid *is* an import, and a round trip
loses energy, so an import-minimising optimizer never does it. Two measured consequences on the 2025
study: Green cycles the battery *less* than Economic, not more (the worry was that ε scales
`degradation_cost` away — it does, but Green only ever moves bounded PV surplus while Economic also
arbitrages); and Green is immune to the negative-price degeneracy, because dumping energy can only
raise the imports it is minimising.

## Experiments

`experiments/<nnn>-<slug>/` holds one study each, and **simulation and plotting are separate
steps**: `run.jl` writes CSVs and never loads Makie, `figures.jl` reads them back. A year at a
15-minute step is 35 040 solves per candidate — half an hour for a sweep — against a minute to
redraw every figure. `flow_table` and `state_table` exist to make that split possible.

## Data sources

`ENTSOE.jl` is unregistered, so it is a hard dependency resolved through a `[sources]` **url** entry
pinned to the `code-review-fixes` branch of `langestefan/EntsoE.jl` — a URL rather than a local path
so a fresh clone and CI resolve without a sibling checkout. Drop the entry once the package is
registered; to work against a local checkout meanwhile, `Pkg.develop(path = ...)`.

**HTTP is pinned to 1.** Not by preference — ENTSOE.jl's cassette-driven tests depend on
BrokenRecord 0.1, which caps HTTP at 1.11.0 and is unmaintained, so pinning that package to HTTP 2
makes its own test environment unsatisfiable. Dropping BrokenRecord resolves and passes under HTTP
2.6.4 but skips roughly 320 tests — Queries falls 207 → 44 and Smoke 154 → 0, precisely the tests
that replay real HTTP traffic. Keeping one HTTP version across both packages is the cheaper trade
for now. The way out is a test-only `OpenAPI.Clients.do_request(::Val{:playback}, …)` method in
ENTSOE.jl: `httplib` is a `Val`-dispatched seam, so cassettes can be replayed with no HTTP patching
at all. Note that `HTTP.get`'s `readtimeout` is renamed `request_timeout` in HTTP 2.

Loaders are split into a fetch half and a pure-data half (`openmeteo_parse` / `resample_weather`,
`entsoe_xml` / `parse_entsoe_prices`) so the alignment logic is tested against committed fixtures in
`test/fixtures/` with no network. Live tests carry the `:network` tag and `test/runtests.jl` filters
them out; run them with

```bash
julia --project=test -e 'using TestItemRunner; TestItemRunner.run_tests("."; filter = ti -> :network in ti.tags)'
```

The ENTSO-E ones additionally need `ENV["ENTSOE_API_TOKEN"]`.

## Environment layout

The root `Project.toml` declares a **Julia workspace**:

```toml
[workspace]
projects = ["test"]
```

`test/` is a separate environment sharing the root `Manifest.toml`, and declares
`[sources] HEMSSimulator = {path = ".."}`. Consequences:

- Never `Pkg.develop` the package into `test`; the path source already handles it.
- Test-only dependencies go in `test/Project.toml`, not the root.
- `Manifest.toml` is gitignored, so a fresh clone needs `Pkg.instantiate()` once.

## Commands

Tests (TestItemRunner, see below). Test files mirror the `src/` directories; shared
`@testsnippet`/`@testmodule` fixtures live in `test/fixtures.jl`:

```bash
julia --project=. -e 'using Pkg; Pkg.test()'          # full suite, as CI runs it
julia --project=test test/runtests.jl                  # same, without Pkg.test sandboxing
```

Run a subset — `@run_package_tests` cannot be used from `julia -e` (it resolves the search root from
the calling file's path, and with `-e` that becomes the *parent* directory, which sweeps in sibling
Julia projects). Call `run_tests` with the package root explicitly instead:

```bash
julia --project=test -e 'using TestItemRunner; TestItemRunner.run_tests("."; filter = ti -> occursin("Basic", ti.name), verbose = true)'
julia --project=test -e 'using TestItemRunner; TestItemRunner.run_tests("."; filter = ti -> :fast in ti.tags, verbose = true)'
```

Lint/format — `pre-commit` drives everything (JuliaFormatter, markdownlint, yamlfmt/yamllint,
CFF validation, whitespace fixers). The git hook is not installed in this clone, so run it manually:

```bash
pre-commit run -a          # what the Lint workflow runs (with SKIP=no-commit-to-branch)
lychee --no-progress --config .lychee.toml .    # link check; note the leading dot in the filename
```

The walkthrough is a runnable script rather than a built site (see below):

```bash
julia --project=. examples/tutorial.jl
```

## Testing conventions

`test/runtests.jl` only calls `@run_package_tests`; it never `include`s test files. Tests are
discovered by scanning the repo for macros, at any directory depth, so **a new test file is picked
up simply by existing** — name it `test/<area>/test-*.jl` and fill it with:

- `@testitem "name" tags=[...] setup=[...] begin ... end` — one isolated test module; the package is
  auto-`using`ed inside, so refer to `HEMSSimulator.foo` directly.
- `@testsnippet Name begin ... end` — code spliced into any testitem listing it in `setup=[...]`
  (bindings land in the testitem's scope).
- `@testmodule Name begin ... end` — a real module, referenced as `Name.helper(...)`.

Existing tags: `:unit`, `:fast`, `:integration`, `:slow`, `:validation`, `:network`. Keep using these for the
`filter` invocations above to stay useful.

The two `:validation` suites are worth knowing about:

- `test/solar/test-pvlib-reference.jl` pins 72 absolute values from pvlib-python 0.15.2 across all
  three transposition models. Every other transposition test checks an invariant, which a mistyped
  Perez coefficient would still satisfy. Regenerate with the script in the file's header comment.
- `test-quality.jl` runs `JET.report_package` and asserts that no report is *located* in this
  package's source. It returns about 100 reports in total, all of them inside DataFrames, CSV and
  JuMP; asserting "no reports at all" would be a test of our dependencies' release notes.

`test/analysis/test-sizing.jl` holds the one test that runs a full simulated year (35 136 intervals
— 2024 is a leap year). It is the milestone-1 acceptance criterion: the NPV optimum must be interior
to the candidate grid, and a home with PV and no storage must self-consume about 30% of what it
generates. A fortnight annualised can produce almost any optimum; a year cannot.

## Plotting

The plotting functions are **documented stubs** in `src/plots.jl`; their methods live in
`ext/HEMSSimulatorMakieExt.jl` and appear when Makie is loaded (`using GLMakie`). Makie is a
`[weakdeps]` entry, never a dependency: its precompile is about three minutes against seconds for
everything else combined, and nobody should pay that to run a simulation.

The split is deliberate about *what* goes where. The extension is only drawing. Everything that can
be plain Julia lives in the package: `ASSET_COLOURS`, `interval_range` / `plot_blocks` /
`block_mean`, and `state_panels`. So the logic most likely to be wrong loads without a plotting
stack.

**There are two palettes, and which one you get is the theme.** `ASSET_COLOURS` is Okabe–Ito and
colour-blind safe; `VRM_COLOURS` copies Victron's portal, whose signature pair is red against green —
exactly what red–green colour blindness collapses. Dark uses VRM, light uses Okabe–Ito, and
`plot_theme(:dark | :light)` is the only way to pick. Do not "unify" them: the split is what lets the
familiar look exist without becoming the only option. Anything that resolves a colour must take a
colour table (`flow_series`, `state_panels`, `dispatch_plot!`, `price_plot!` all do) rather than
reaching for `ASSET_COLOURS` directly, or it will draw the wrong palette the moment the theme changes.

Five design points worth not undoing:

- **`ASSET_COLOURS` is the Okabe–Ito palette, and the assignment within it is not free.** The set is
  chosen so every pair survives protanopia, deuteranopia and tritanopia; picking a "nicer" hex for one
  entry breaks that property for the whole table. The assignment matters too: `pv` and `import` always
  stack against each other on the source side, so they take the furthest-apart pair (yellow against
  vermillion). The intuitive "PV orange, import red" fails — Okabe–Ito's orange and vermillion are
  neighbours and merge under deuteranopia. Orange went to `dhw`, a sink that never touches either.
- **Time axes are drawn in hours since the window opened but ticked on the clock.** `time_ticks`
  aligns to midnight rather than to the window's start, so the same hour of the day sits at the same
  place in every figure and a day boundary is always a labelled tick. The 12-hour default is honoured
  only while it yields 2–12 ticks; a 3-hour dashboard window would otherwise carry no label at all and
  a 28-day one fifty-six, so outside that range it falls back to the step nearest six ticks.
- **`flow_series` reads `consumption_columns` / `production_columns`** — the same declarations
  `balance_residual` uses. A new asset therefore appears in the dispatch plot with no change here,
  and the picture cannot disagree with the accounting. A legend suffix is taken from the *resolved
  frame column*, not the asset index, so only a genuine duplicate gets one.
- **`state_panels` is per-asset on purpose.** Limits are not derivable from the contract: a
  battery's are constant fractions of capacity, a car's are deadlines at instants, a house's move
  every interval. An asset without a method is simply absent from the plot rather than wrong in it.
- **The theme switch recolours, it does not rebuild.** `_apply_theme!` sets chrome attributes on the
  existing blocks and `refresh` redraws the plots from `palette[]`, so switching costs a redraw
  rather than a figure. The one thing it *does* rebuild is the legends, because a legend entry bakes
  in its swatch colour and the swatch is precisely what changed. If you add a legend, rebuild it
  there — and derive its colours from `palette[].colours`, not from a `flow_series` captured at
  build time, which is a bug this already had once.

`dashboard` is the interactive one: it **reuses `dispatch_plot!` and `state_plot!` and redraws on
change** rather than being rebuilt around observables, so the interactive view and the static
figures share one drawing path and cannot drift. Two sets of toggles: *series* filter the dispatch
stack, *rows* collapse whole panels.

**Collapsing a row needs three things, not one.** `rowsize!(left, row, Fixed(0))` zeroes the row but
leaves the plot drawing into a zero-height strip, which renders as a stray line across the figure —
so the block's `scene` (the plotted content) and its `blockscene` (ticks, labels, spines) are both
hidden as well. Row *gaps* are then recomputed from scratch rather than toggled per section, because
two neighbouring sections share a gap and would otherwise fight over it. And `refresh` puts the date
labels on the lowest *visible* axis: keying them to the lowest axis outright loses the time axis
entirely the moment someone collapses the bottom panel. An earlier note here called this fragile and
said the state panels must always show; that was wrong, and the three points above are why.

**Every combination is simulated before the window opens, threaded, not on first selection.** This
looks like the wasteful choice and is not: a menu callback runs on the thread that draws, so a solve
started from a click freezes GLMakie for its whole duration. At a year per combination that is
minutes of an unresponsive window, and the desktop offers to force-quit it — the user sees a crash,
not a wait. `precompute = false` restores the lazy behaviour for horizons short enough not to matter.

The backend matters for the dashboard and not for the figures: **GLMakie** opens a window and
handles events, and needs a GPU and a display. CairoMakie still renders every static plot, so a
headless box loses only the dashboard.

Calling a plot function without a backend gives a `MethodError` plus a registered error hint naming
GLMakie — see `_register_plot_hint`, wired from `__init__`.

**There are no plotting tests, by choice**, to keep CI fast. `examples/plots.jl` renders all seven
figures and is the smoke test: run it after touching either file and look at the output. The pure
helpers in `src/plots.jl` could be tested at no CI cost whenever that seems worth doing.

## Documentation

There is **no Documenter site**. It was removed: the deploy never worked without a `DOCUMENTER_KEY`,
and the reference page was a single `@autodocs` dump nobody read. The API is documented in
docstrings, reachable with `?` in the REPL, and everything narrative lives in one of two places:

- `examples/plots.jl` — every figure the package can draw. Needs a Makie backend; see Plotting.
- `examples/dashboard.jl` — the interactive dashboard. Needs GLMakie and a display.
- `examples/tutorial.jl` — a runnable walkthrough of the whole package, from a `HomeSystem` through
  the four scenarios, the sizing sweep and LP bound, to the EV, heat pump and hot water tank. Prose
  is comments; every number it prints is computed when you run it. Keep it running — it is the only
  thing that exercises the public API end to end outside the test suite.
- this file — the design decisions and the traps, which are for whoever is changing the code rather
  than for whoever is using it.

Do not reintroduce `docs/` without a reason; the removal was deliberate.

## Style

JuliaFormatter with `indent = 4`, `margin = 92`, LF endings (`.JuliaFormatter.toml`). Note the
`file-contents-sorter` pre-commit hook rewrites `.JuliaFormatter.toml` into sorted unique lines, so
keep that file as flat `key = value` lines.

## Release flow

Version bump in `Project.toml` + `CHANGELOG.md` section rename on a `release-x.y.z` branch, then
comment `@JuliaRegistrator register` on the merged commit; TagBot creates the tag.
