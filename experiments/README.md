# Experiments

One directory per study. Each holds the script that produced it and the results it produced, so a
number in a discussion can always be traced back to the run that made it.

```text
experiments/
  common.jl                     shared result writing
  001-<slug>/
    run-config.jl               every input, shared by the scripts below
    run.jl                      simulate -> CSV. No plotting, no Makie.
    figures.jl                  CSV -> PNG. No solving.
    explore.jl                  the same study in the interactive dashboard
    data/                       CSVs, written by run.jl, committed
    figures/                    PNGs, written by figures.jl, committed
```

**Simulating and plotting are separate steps, and that is the important part.** A year at a
15-minute control step is 35 040 solves per candidate — half an hour for a study like 001 — while
redrawing every figure from the CSVs takes about a minute. Keeping them apart means an axis label
can be fixed without paying for the solver again, and it makes the numbers behind each figure a
committed artifact rather than something trapped inside a plotting call.

`run.jl` therefore never loads Makie and runs on the package environment alone. `figures.jl` needs a
Makie backend and reads only `data/`, so it works without an ENTSO-E token. Data and figures sit in
separate directories so it is obvious which files cost half an hour of solver time and which can be
regenerated in a minute.

Conventions:

- **Results are committed.** They are small, and re-running a study costs minutes of solver time —
  a reviewer should not have to spend it to see what happened.
- **Every input is in `run.jl`.** Tariff constants, array sizes, candidate list, run options. If a
  number matters to the answer it is visible at the top of the file, not buried in a default.
- **Measured data is cached**, so a re-run does not re-download and does not silently drift when
  ERA5 is reanalysed. See `set_cache`.
- `run.jl` needs `ENV["ENTSOE_API_TOKEN"]`; the other two do not.

```bash
# once, to set up the plotting environment
julia --project=examples -e 'using Pkg; Pkg.instantiate()'

julia --project=.        -t auto experiments/001-tibber-2025-strategies/run.jl      # ~30 min
julia --project=examples         experiments/001-tibber-2025-strategies/figures.jl  # ~1 min
julia --project=examples -t auto experiments/001-tibber-2025-strategies/explore.jl  # dashboard
```
