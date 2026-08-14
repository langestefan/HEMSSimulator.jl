"""
    sweep(system, inputs, contract, candidates; investment, options = RunOptions()) -> DataFrame

Simulate the home once per candidate battery and tabulate the business case for each.

This is the headline entry point of the package. Sizing is done by simulating rather than by making
capacity a decision variable, so every candidate is evaluated under the real billing rules —
including annual netting, which no dispatch objective can represent. `investment` is a function from
a [`Battery`](@ref) to an [`Investment`](@ref), since capex depends on the size being tested.

Candidates are independent, so they are simulated on all available threads by default. Start Julia
with `-t auto` for that to mean anything; with one thread `threaded` costs nothing and does nothing.
See the note below on where the time actually goes.

The baseline is `system` exactly as configured, simulated once; each candidate is that same home
with the candidate **added** to its assets. So a home that already has an EV keeps it in both arms
and the reported saving is what the battery adds on top, not what the battery and the car do
together. Pass a system with no assets for the plain no-battery baseline.

Returns one row per candidate with the candidate's size, its bill, and its KPIs. An optimum sitting
at the edge of `candidates` means the grid was too narrow — widen it and rerun.

# Examples

```julia
candidates = [Battery(kwh, kwh / 2) for kwh in 0:2.5:20]
table = sweep(system, inputs, contract, candidates;
              investment = b -> Investment(capex = 400 + 450 * b.capacity_kwh))
```
"""
function sweep(
    system::HomeSystem,
    inputs::SimulationInputs,
    contract::Contract,
    candidates::AbstractVector{<:AbstractAsset};
    investment,
    options::RunOptions = RunOptions(),
    threaded::Bool = Threads.nthreads() > 1,
)
    baseline_result = simulate(system, inputs; options)
    baseline_bill = settle(baseline_result, contract)

    rows = Vector{NamedTuple}(undef, length(candidates))
    evaluate(index) =
        rows[index] = _sweep_row(
            system,
            inputs,
            contract,
            candidates[index],
            baseline_bill,
            investment,
            options,
        )
    if threaded
        # Each candidate builds its own JuMP model and its own solver instance; `inputs` and the
        # assets are immutable and only read. Results are written by index, so the table is
        # identical however many threads ran it.
        Threads.@threads for index in eachindex(candidates)
            evaluate(index)
        end
    else
        for index in eachindex(candidates)
            evaluate(index)
        end
    end
    return DataFrame(rows)
end

function _sweep_row(system, inputs, contract, candidate, baseline_bill, investment, options)
    case_system = with_assets(system, vcat(system.assets, [candidate]))
    result = simulate(case_system, inputs; options)
    bill = settle(result, contract)
    metrics = kpis(baseline_bill, bill, investment(candidate); result)
    return merge(
        (;
            capacity_kwh = candidate isa Battery ? candidate.capacity_kwh : NaN,
            power_kw = candidate isa Battery ? candidate.discharge_power_kw : NaN,
            capex = investment(candidate).capex,
            annual_bill = annualise(bill),
            imported_kwh = bill.imported_kwh,
            exported_kwh = bill.exported_kwh,
            netted_kwh = bill.netted_kwh,
        ),
        metrics,
    )
end

"""
    sweep(system, weather, load_kw, contract, candidates; investment, options = RunOptions())

Convenience form that calls [`prepare`](@ref) once and reuses the exogenous series for every
candidate.
"""
function sweep(
    system::HomeSystem,
    weather::Weather,
    load_kw::AbstractVector,
    contract::Contract,
    candidates::AbstractVector{<:AbstractAsset};
    investment,
    options::RunOptions = RunOptions(),
    threaded::Bool = Threads.nthreads() > 1,
)
    inputs = prepare(system, weather, load_kw, contract; options)
    return sweep(system, inputs, contract, candidates; investment, options, threaded)
end

"""
    best(table::DataFrame; by = :npv) -> DataFrameRow

The best row of a [`sweep`](@ref) table by the given KPI, and a warning when it sits at the edge of
the candidate range — an optimum on the boundary usually means the grid did not bracket it.
"""
function best(table::DataFrame; by::Symbol = :npv)
    index = argmax(table[!, by])
    if index == 1 || index == nrow(table)
        @warn "optimum is at the edge of the candidate range; widen the sweep" by index rows =
            nrow(table)
    end
    return table[index, :]
end

"""
    sweep(system, weather, load_kw, contracts::NamedTuple, candidates; investment, options)

Run a [`sweep`](@ref) under each of several regulatory scenarios and stack the results, with a
`scenario` column naming each block. `contracts` is what [`scenarios`](@ref) returns.

This is the headline table of the package: what a battery is worth is not one number but four, and
they differ by more than the measurement noise of any single assumption.

```julia
table = sweep(home, weather, load, scenarios(grid; commodity, feed_in), candidates;
              investment = b -> Investment(capex = 1000 + 450 * b.capacity_kwh))
best_by_scenario(table)
```

Each scenario is simulated independently, because the contract changes the dispatch price signal and
therefore the flows — not just the bill computed from them.
"""
function sweep(
    system::HomeSystem,
    weather::Weather,
    load_kw::AbstractVector,
    contracts::NamedTuple,
    candidates::AbstractVector{<:AbstractAsset};
    investment,
    options::RunOptions = RunOptions(),
    threaded::Bool = Threads.nthreads() > 1,
)
    isempty(contracts) && throw(ArgumentError("no scenarios given"))
    frames = DataFrame[]
    for name in keys(contracts)
        table = sweep(
            system,
            weather,
            load_kw,
            contracts[name],
            candidates;
            investment,
            options,
            threaded,
        )
        push!(frames, insertcols!(table, 1, :scenario => fill(name, nrow(table))))
    end
    return reduce(vcat, frames)
end

"""
    best_by_scenario(table::DataFrame; by = :npv) -> DataFrame

One row per scenario of a scenario [`sweep`](@ref) table: the candidate that maximises `by` within
that scenario. Warns per scenario when the winner sits at the edge of the candidate range.

Use this rather than [`best`](@ref) on a stacked table — `best` would return the single globally
best row, which is almost always the most permissive scenario and says nothing about the others.
"""
function best_by_scenario(table::DataFrame; by::Symbol = :npv)
    hasproperty(table, :scenario) || throw(
        ArgumentError(
            "table has no `scenario` column; it did not come from a scenario sweep",
        ),
    )
    picks = Int[]
    for scenario in unique(table.scenario)
        rows = findall(==(scenario), table.scenario)
        index = argmax(table[rows, by])
        if index == 1 || index == length(rows)
            @warn "optimum is at the edge of the candidate range; widen the sweep" scenario by index rows =
                length(rows)
        end
        push!(picks, rows[index])
    end
    return table[picks, :]
end
