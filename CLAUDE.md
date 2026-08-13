# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A home energy management system simulator for Dutch households, built on JuMP. It dispatches a
home's assets at 15-minute resolution over a year and answers one question: what battery size is
worth buying, under a given tariff and regulatory scenario.

Scaffolded from [BestieTemplate.jl](https://github.com/JuliaBesties/BestieTemplate.jl) (copier
answers in `.copier-answers.yml`). Minimum Julia is 1.12.

## Architecture

Five layers, each testable alone. Data flows one way:

```
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

Include order in `src/BatteryBusinessCase.jl` is significant; each directory depends only on the
ones above it.

| Directory | Holds |
|---|---|
| `core/` | `TimeGrid` (the 15-min grid everything aligns to), the `AbstractAsset` contract, `RunOptions`, `DispatchContext`, `show` methods |
| `solar/` | `Site`/`Weather`, Erbs decomposition, transposition models (`Isotropic`/`HayDavies`/`Perez`), `PVArray` and production |
| `assets/` | Controllable assets. `battery.jl` today; EV, heat pump and DHW land here |
| `market/` | `Contract` and grid tariffs, the settlement engine, NPV/IRR/payback |
| `model/` | `HomeSystem`/`SimulationInputs`, the JuMP window model, `SimulationResult`, the rolling-horizon driver |
| `analysis/` | The sizing sweep |
| `io/` | Synthetic generators today; CSV and KNMI loaders land here |

### Adding an asset

Assets are anything the optimizer *decides about*. PV and the base load are not assets — they are
exogenous data in `SimulationInputs`. To add one, implement the contract documented on
`AbstractAsset` (`src/core/types.jl`): `initial_state`, `add_variables!`, `add_constraints!`,
`power_terms`, `cost_terms`, `carry_state`, `result_columns`. `dispatch.jl` collects `power_terms`
into the single meter balance and `cost_terms` into the objective, so nothing else needs to change.
`src/assets/battery.jl` is the reference implementation.

### Things that will bite you

- **The LP is degenerate under negative prices.** It avoids charging and discharging at once only
  because wasting energy costs money; negative day-ahead prices (common in NL) make it profitable.
  `RunOptions.check_degeneracy` warns, `RunOptions.exclusive` adds the binaries that fix it. Under
  full netting buy and sell prices are equal, which is why `RunOptions.price_epsilon` exists.
- **Terminal value matters.** Without valuing end-of-window storage the receding horizon empties the
  battery every 24 h. Handled by the 48/24 window overlap plus `RunOptions.terminal_value`.
- **Self-consumption is attributed per interval** (`min(PV, on-site demand)`). Total export is not a
  proxy for un-consumed PV once a battery can export grid-charged energy.
- **Synthetic weather cloudiness is bimodal on purpose.** A constant clearness index puts Erbs
  permanently in its high-diffuse regime, giving an 85%-diffuse sky where array tilt barely matters.

## Environment layout

The root `Project.toml` declares a **Julia workspace**:

```toml
[workspace]
projects = ["test", "docs"]
```

`test/` and `docs/` are separate environments that share the root `Manifest.toml`, and each declares
`[sources] BatteryBusinessCase = {path = ".."}`. Consequences:

- Never `Pkg.develop` the package into `test`/`docs`; the path source already handles it.
- Test-only or docs-only dependencies go in `test/Project.toml` / `docs/Project.toml`, not the root.
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

Docs — serve with live reload:

```bash
julia --project=docs -e 'using LiveServer; servedocs()'
julia --project=docs docs/make.jl               # one-shot build into docs/build/
```

## Testing conventions

`test/runtests.jl` only calls `@run_package_tests`; it never `include`s test files. Tests are
discovered by scanning the repo for macros, at any directory depth, so **a new test file is picked
up simply by existing** — name it `test/<area>/test-*.jl` and fill it with:

- `@testitem "name" tags=[...] setup=[...] begin ... end` — one isolated test module; the package is
  auto-`using`ed inside, so refer to `BatteryBusinessCase.foo` directly.
- `@testsnippet Name begin ... end` — code spliced into any testitem listing it in `setup=[...]`
  (bindings land in the testitem's scope).
- `@testmodule Name begin ... end` — a real module, referenced as `Name.helper(...)`.

Existing tags: `:unit`, `:fast`, `:integration`, `:slow`, `:validation`. Keep using these for the
`filter` invocations above to stay useful.

## Documentation conventions

`docs/make.jl` builds the page list by **recursively walking `docs/src/`** — every `.md` file is
included automatically, so no page list needs editing when adding one. But every *subdirectory* (and
any page wanting a custom title) must have an entry in the `titles` dict in `docs/make.jl`, otherwise
the build logs `@error "Bad usage: ... does not have a title set"`. Numeric filename prefixes control
ordering (`90-contributing.md`, `91-developer.md`, `95-reference.md`); `index.md` is always first.
Public API docstrings surface automatically through `@autodocs` in `docs/src/95-reference.md`.

## Style

JuliaFormatter with `indent = 4`, `margin = 92`, LF endings (`.JuliaFormatter.toml`). Note the
`file-contents-sorter` pre-commit hook rewrites `.JuliaFormatter.toml` into sorted unique lines, so
keep that file as flat `key = value` lines.

## Release flow

Version bump in `Project.toml` + `CHANGELOG.md` section rename on a `release-x.y.z` branch, then
comment `@JuliaRegistrator register` on the merged commit; TagBot creates the tag. Full checklist in
`docs/src/91-developer.md`.
