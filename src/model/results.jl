"""
    SimulationResult

The outcome of a [`simulate`](@ref) run: one row per interval of the horizon.

# Fields

  - `grid::TimeGrid`: the horizon.
  - `frame::DataFrame`: the dispatched flows. Always present: `timestamp`, `load_kw`,
    `pv_available_kw`, `curtail_kw`, `import_kw`, `export_kw`, `price_buy`, `price_sell`. Each
    controllable asset adds its own columns — a [`Battery`](@ref) adds `battery_charge_kw`,
    `battery_discharge_kw` and `battery_soc_kwh`.
  - `system::HomeSystem`: the home that was simulated.
  - `windows::Int`: number of optimization windows solved.
  - `solve_time::Float64`: total wall-clock seconds spent in the solver.

The frame is the raw material for [`settle`](@ref); everything downstream reads it rather than
re-deriving flows.
"""
struct SimulationResult
    grid::TimeGrid
    frame::DataFrame
    system::HomeSystem
    windows::Int
    solve_time::Float64
end

Base.length(result::SimulationResult) = result.grid.n

"""
    energy(result::SimulationResult, column::Symbol) -> Float64

Total energy in kWh of a power column, i.e. its sum times the interval length.
"""
energy(result::SimulationResult, column::Symbol) =
    sum(result.frame[!, column]) * hours(result.grid)

"""
    imported_kwh(result::SimulationResult) -> Float64

Total energy taken from the grid, kWh.
"""
imported_kwh(result::SimulationResult) = energy(result, :import_kw)

"""
    exported_kwh(result::SimulationResult) -> Float64

Total energy fed into the grid, kWh.
"""
exported_kwh(result::SimulationResult) = energy(result, :export_kw)

"""
    produced_kwh(result::SimulationResult) -> Float64

PV energy actually used, kWh — production available less curtailment.
"""
produced_kwh(result::SimulationResult) =
    energy(result, :pv_available_kw) - energy(result, :curtail_kw)

"""
    consumed_kwh(result::SimulationResult) -> Float64

Household base load energy, kWh. Excludes battery losses and charging.
"""
consumed_kwh(result::SimulationResult) = energy(result, :load_kw)

"""
    onsite_sinks(result::SimulationResult) -> Vector{Float64}

Per-interval on-site demand in kW: the base load plus anything the assets consume. This is the
ceiling on how much PV can be self-consumed in an interval.
"""
function onsite_sinks(result::SimulationResult)
    sinks = copy(result.frame.load_kw)
    hasproperty(result.frame, :battery_charge_kw) &&
        (sinks .+= result.frame.battery_charge_kw)
    return sinks
end

"""
    onsite_supply(result::SimulationResult) -> Vector{Float64}

Per-interval on-site generation in kW: PV actually used plus anything the assets discharge.
"""
function onsite_supply(result::SimulationResult)
    supply = result.frame.pv_available_kw .- result.frame.curtail_kw
    hasproperty(result.frame, :battery_discharge_kw) &&
        (supply .+= result.frame.battery_discharge_kw)
    return supply
end

"""
    self_consumption(result::SimulationResult) -> Float64

Fraction of PV production consumed on site.

Attributed per interval as `min(pv, on-site demand)`, because PV can only be self-consumed up to the
demand present at that instant. Comparing total export against total production would not do: once a
battery can export energy it charged from the grid, export is no longer a proxy for un-consumed PV
and the naive ratio goes negative.

`NaN` when there is no PV.
"""
function self_consumption(result::SimulationResult)
    pv = result.frame.pv_available_kw .- result.frame.curtail_kw
    produced = sum(pv)
    produced <= 0 && return NaN
    sinks = onsite_sinks(result)
    return sum(min.(pv, sinks)) / produced
end

"""
    self_sufficiency(result::SimulationResult) -> Float64

Fraction of household consumption met from on-site supply, attributed per interval as
`min(load, PV + discharge)`. `NaN` when there is no consumption.
"""
function self_sufficiency(result::SimulationResult)
    load = result.frame.load_kw
    consumed = sum(load)
    consumed <= 0 && return NaN
    return sum(min.(load, onsite_supply(result))) / consumed
end

"""
    balance_residual(result::SimulationResult) -> Vector{Float64}

Per-interval violation of the meter balance, kW. Every element should be zero to solver tolerance;
the integration tests assert this, because a non-zero residual means the accounting is wrong
regardless of what the objective reported.
"""
function balance_residual(result::SimulationResult)
    frame = result.frame
    residual =
        frame.import_kw .- frame.export_kw .+ frame.pv_available_kw .- frame.curtail_kw .-
        frame.load_kw
    hasproperty(frame, :battery_discharge_kw) && (residual .+= frame.battery_discharge_kw)
    hasproperty(frame, :battery_charge_kw) && (residual .-= frame.battery_charge_kw)
    return residual
end
