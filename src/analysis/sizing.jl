"""
    sweep(system, inputs, contract, candidates; investment, options = RunOptions()) -> DataFrame

Simulate the home once per candidate battery and tabulate the business case for each.

This is the headline entry point of the package. Sizing is done by simulating rather than by making
capacity a decision variable, so every candidate is evaluated under the real billing rules —
including annual netting, which no dispatch objective can represent. `investment` is a function from
a [`Battery`](@ref) to an [`Investment`](@ref), since capex depends on the size being tested.

The no-battery baseline is simulated once and every candidate is measured against it.

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
)
    baseline_system = with_assets(system, AbstractAsset[])
    baseline_result = simulate(baseline_system, inputs; options)
    baseline_bill = settle(baseline_result, contract)

    rows = Vector{NamedTuple}(undef, length(candidates))
    for (index, candidate) in enumerate(candidates)
        case_system = with_assets(system, [candidate])
        result = simulate(case_system, inputs; options)
        bill = settle(result, contract)
        metrics = kpis(baseline_bill, bill, investment(candidate); result)
        rows[index] = merge(
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
    return DataFrame(rows)
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
)
    inputs = prepare(system, weather, load_kw, contract; options)
    return sweep(system, inputs, contract, candidates; investment, options)
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
