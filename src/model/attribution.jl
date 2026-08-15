"""
    energy_flows(result::SimulationResult) -> DataFrame

Where every kWh came from and where it went, as a tidy `source, sink, kwh` table over the whole
horizon.

Sources are PV actually used, grid import, and whatever the assets discharge. Sinks are the base
load, grid export, and whatever the assets consume. Both come from the assets' own
[`consumption_columns`](@ref) and [`production_columns`](@ref) — the same declarations
[`balance_residual`](@ref) and [`flow_series`](@ref) read — so a new asset appears here with no
change to this file, and the attribution cannot disagree with the meter balance.

# How a kWh is attributed

**Proportionally, per interval.** Electricity carries no label: when a house is drawing 3 kW of solar
and 1 kW of grid while charging a car at 2 kW and running 2 kW of load, there is no physical fact
about which electrons went where. So each sink is charged with the same mix as the interval's supply
— here the car is 75% solar, 25% grid, and so is the load.

This is the *immediate* mix, which is what a meter can see. Solar that charged a battery in the
afternoon and left it in the evening counts as `PV → battery` and then `battery → load`, not as
`PV → load`. That is a choice: it keeps every number attributable to a measurable flow, at the cost
of not tracing an electron's whole journey. [`solar_use`](@ref) and [`source_mix`](@ref) read this
table the two ways people usually want it.

Curtailed PV is deliberately **absent**: it was never produced, so it is not energy that went
anywhere. [`solar_use`](@ref) reports it against PV *available* instead.
"""
function energy_flows(result::SimulationResult)
    frame = result.frame
    dt = hours(result.grid)
    n = result.grid.n

    sources = Pair{String,Vector{Float64}}[
        "PV"=>collect(Float64, frame.pv_available_kw .- frame.curtail_kw),
        "grid"=>collect(Float64, frame.import_kw),
    ]
    sinks = Pair{String,Vector{Float64}}[
        "base load"=>collect(Float64, frame.load_kw),
        "export"=>collect(Float64, frame.export_kw),
    ]
    for (asset, mapping) in zip(result.system.assets, result.asset_columns)
        for (declared, into) in
            ((production_columns(asset), sources), (consumption_columns(asset), sinks))
            for name in declared
                column = get(mapping, name, name)
                hasproperty(frame, column) || continue
                values = collect(Float64, frame[!, column])
                all(iszero, values) && continue
                push!(into, _flow_label(name, column) => values)
            end
        end
    end

    total = zeros(Float64, length(sources), length(sinks))
    supply = zeros(Float64, n)
    for (_, values) in sources
        supply .+= values
    end
    for k = 1:n
        supply[k] > 0 || continue
        for (i, (_, from)) in enumerate(sources)
            from[k] > 0 || continue
            share = from[k] / supply[k]
            for (j, (_, to)) in enumerate(sinks)
                total[i, j] += share * to[k] * dt
            end
        end
    end

    return DataFrame(
        source = repeat(first.(sources), inner = length(sinks)),
        sink = repeat(first.(sinks), outer = length(sources)),
        kwh = vec(permutedims(total)),
    )
end

"""
    solar_use(result::SimulationResult) -> NamedTuple

What became of the PV, as fractions of what the array *could* have produced.

Fields are `available_kwh`, `curtailed`, and one entry per destination — `base_load`, `export`,
`battery_charge`, `ev_charge` and so on, named after the sinks in [`energy_flows`](@ref) with spaces
replaced by underscores. The fractions sum to 1.

`curtailed` is the share the inverter or the optimizer threw away, and it is the reason this is
measured against *available* rather than produced PV: a house that curtails a third of its array is
not using its solar well, and a ratio taken over production would hide that entirely.
"""
function solar_use(result::SimulationResult)
    frame = result.frame
    dt = hours(result.grid)
    available = sum(frame.pv_available_kw) * dt
    curtailed = sum(frame.curtail_kw) * dt
    flows = energy_flows(result)
    solar = flows[flows.source .== "PV", :]
    shares = NamedTuple(
        Symbol(replace(row.sink, " " => "_")) =>
            (available > 0 ? row.kwh / available : NaN) for row in eachrow(solar)
    )
    return merge(
        (;
            available_kwh = available,
            curtailed = available > 0 ? curtailed / available : NaN,
        ),
        shares,
    )
end

"""
    source_mix(result::SimulationResult, sink::AbstractString) -> NamedTuple

Where one sink's energy came from, as fractions summing to 1.

`sink` names a column of [`energy_flows`](@ref) — `"ev charge"`, `"battery charge"`, `"base load"`,
`"export"`. Throws if it is not one of them rather than returning an empty mix, because a typo that
silently answers "0% from everything" is worse than an error.

```julia
source_mix(result, "ev charge")   # (; total_kwh = 2_600.0, PV = 0.41, grid = 0.37, battery_discharge = 0.22)
```
"""
function source_mix(result::SimulationResult, sink::AbstractString)
    flows = energy_flows(result)
    rows = flows[flows.sink .== sink, :]
    isempty(rows) && throw(
        ArgumentError(
            "no sink named \"$sink\"; this result has " *
            join(sort(unique(flows.sink)), ", "),
        ),
    )
    total = sum(rows.kwh)
    shares = NamedTuple(
        Symbol(replace(row.source, " " => "_")) => (total > 0 ? row.kwh / total : NaN) for
        row in eachrow(rows)
    )
    return merge((; total_kwh = total), shares)
end
