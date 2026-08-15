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

Two design points worth not undoing:

- **`flow_series` reads `consumption_columns` / `production_columns`** — the same declarations
  `balance_residual` uses. A new asset therefore appears in the dispatch plot with no change here,
  and the picture cannot disagree with the accounting. A legend suffix is taken from the *resolved
  frame column*, not the asset index, so only a genuine duplicate gets one.
- **`state_panels` is per-asset on purpose.** Limits are not derivable from the contract: a
  battery's are constant fractions of capacity, a car's are deadlines at instants, a house's move
  every interval. An asset without a method is simply absent from the plot rather than wrong in it.

`dashboard` is the interactive one: it **reuses `dispatch_plot!` and `state_plot!` and redraws on
change** rather than being rebuilt around observables, so the interactive view and the static
figures share one drawing path and cannot drift. Its toggles filter the dispatch stack only — the
state panels always show every asset, because collapsing rows in a Makie `GridLayout` is fragile and
the stack is what actually becomes unreadable. Simulations are cached per (scenario, candidate).

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
