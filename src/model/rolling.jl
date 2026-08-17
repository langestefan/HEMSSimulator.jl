"""
    simulate(system::HomeSystem, inputs::SimulationInputs; options = RunOptions())
        -> SimulationResult

Run the home over the whole horizon on a receding horizon.

Each solve optimizes `options.window_hours` with perfect foresight but keeps only the first
`options.step_hours`; the assets' states are carried into the next window and the horizon advances.
That overlap is what stops the optimizer from emptying the battery at every boundary, and it is the
structure a forecast model later plugs into — replacing perfect foresight means substituting the
data sliced into each window, not changing this loop.

`cache = true` looks the result up on disk first and stores it on a miss, keyed by everything this
function reads — see [`simulation_key`](@ref). It is off by default because a cache that is on
without being asked for is a cache that eventually answers the wrong question; turn it on in a script
that solves the same configuration more than once, which a sweep followed by a dashboard does.

`progress`, if given, is called after every window as `progress(done, total)`. A year at a
15-minute control step is 35 040 windows and several minutes, so anything with a person waiting on it
needs a way to say how far along it is; see [`ProgressBar`](@ref). It is called from inside the loop,
once per window, so keep it cheap — the cost lands on the simulation.

# Examples

```julia
inputs = prepare(system, weather, load_kw, contract)
result = simulate(system, inputs)
bill = settle(result, contract)
```
"""
function simulate(
    system::HomeSystem,
    inputs::SimulationInputs;
    options::RunOptions = RunOptions(),
    forecast::AbstractForecast = PerfectForecast(),
    progress = nothing,
    cache::Bool = false,
)
    cache || return _simulate(system, inputs, options, forecast, progress)
    key = simulation_key(system, inputs, options, forecast)
    hit = _load_simulation(key, system, inputs.grid)
    hit === nothing || return hit
    result = _simulate(system, inputs, options, forecast, progress)
    _store_simulation(key, result)
    return result
end

function _simulate(
    system::HomeSystem,
    inputs::SimulationInputs,
    options::RunOptions,
    forecast::AbstractForecast,
    progress,
)
    grid = inputs.grid
    dt = hours(grid)
    window_len = max(1, round(Int, options.window_hours / dt))
    step_len = max(1, round(Int, options.step_hours / dt))
    step_len <= window_len || throw(
        ArgumentError(
            "step_hours ($(options.step_hours)) exceeds window_hours ($(options.window_hours))",
        ),
    )

    frame = DataFrame(
        timestamp = timestamps(grid),
        load_kw = inputs.load_kw,
        pv_available_kw = inputs.pv_kw,
        price_buy = inputs.price_buy,
        price_sell = inputs.price_sell,
        curtail_kw = zeros(grid.n),
        import_kw = zeros(grid.n),
        export_kw = zeros(grid.n),
    )
    asset_columns = Dict{Symbol,Vector{Float64}}()
    # Which frame column each asset's declared column name ended up in, so the reporting layer can
    # find an asset's flows without knowing its type. Stable after the first window.
    column_names = [Dict{Symbol,Symbol}() for _ in system.assets]

    states = [initial_state(asset) for asset in system.assets]
    # Known before the loop, because the step is fixed: the last window is short, not extra.
    total_windows = cld(grid.n, step_len)
    first_interval = 1
    windows = 0
    solve_time = 0.0
    overrun = 0
    meter_clashes = 0
    asset_clashes = 0
    while first_interval <= grid.n
        remaining = grid.n - first_interval + 1
        len = min(window_len, remaining)
        implemented = min(step_len, remaining)
        ctx = DispatchContext(
            window(grid, first_interval, len),
            dt,
            forecast_window(forecast, inputs, first_interval, len),
            options,
            first_interval,
        )
        vars, model, degeneracy = solve_window(system, ctx, states)
        solve_time += JuMP.solve_time(model)
        windows += 1
        progress === nothing || progress(windows, total_windows)
        meter_clashes += degeneracy.meter
        asset_clashes += degeneracy.assets

        rows = first_interval:(first_interval+implemented-1)
        # The plan was made against what the controller *believed*. What gets implemented is the
        # asset setpoints — those are commands, and they happen — while the meter absorbs whatever
        # the belief got wrong. `recourse!` writes the grid flows that actually result, against the
        # true series. Under `PerfectForecast` it reproduces the solver's own values exactly, which
        # a test asserts.
        overrun += recourse!(frame, system, vars, inputs, rows, implemented)
        for (index, (asset, avars)) in enumerate(zip(system.assets, vars.assets))
            for (name, values) in pairs(result_columns(asset, avars, implemented))
                # Resolved once, on this asset's first window. Recomputing it every window would
                # move an asset to a suffixed column the moment the unsuffixed one exists — which
                # it does, because the asset itself created it on the previous pass.
                column = get!(
                    () -> unique_column(asset_columns, name, index),
                    column_names[index],
                    name,
                )
                get!(asset_columns, column, zeros(grid.n))[rows] .= values
            end
        end

        states = [
            carry_state(asset, avars, implemented) for
            (asset, avars) in zip(system.assets, vars.assets)
        ]
        first_interval += implemented
    end

    # One report for the whole run, not one per window: at a 15-minute control step a year is
    # 35 040 windows, and warning from each of them buries the finding it is trying to surface.
    if meter_clashes > 0 || asset_clashes > 0
        @warn "the solution imports and exports, or charges and discharges, in the same " *
              "interval; the linear program cannot rule this out under negative prices. " *
              "Enable RunOptions.exclusive if the affected flows matter." meter_intervals =
            meter_clashes asset_intervals = asset_clashes windows
    end

    # A forecast error can ask the meter for more than the connection can carry. The model has no
    # mechanism for shedding load, so the flow is recorded and the violation reported rather than
    # quietly clamped — clamping would break the energy balance every downstream number relies on.
    overrun > 0 && @warn "the connection limit was exceeded after forecast error; the flows " *
          "are recorded as they balance, not as a meter could deliver them" intervals = overrun

    for (name, values) in asset_columns
        frame[!, name] = values
    end
    return SimulationResult(grid, frame, system, windows, solve_time, column_names)
end

# Two assets of the same type would otherwise write to the same column. Suffix by asset index so the
# frame stays unambiguous rather than silently keeping the last writer. Call this once per asset per
# column name — the answer depends on what has been claimed already, so it is not idempotent.
function unique_column(columns::Dict{Symbol,Vector{Float64}}, name::Symbol, index::Integer)
    index == 1 && return name
    return haskey(columns, name) ? Symbol(name, :_, index) : name
end

"""
    simulate(system, weather, load_kw, contract; options = RunOptions()) -> SimulationResult

Convenience form that calls [`prepare`](@ref) first.
"""
function simulate(
    system::HomeSystem,
    weather::Weather,
    load_kw::AbstractVector,
    contract::Contract;
    options::RunOptions = RunOptions(),
    forecast::AbstractForecast = PerfectForecast(),
    progress = nothing,
    cache::Bool = false,
)
    inputs = prepare(system, weather, load_kw, contract; options)
    return simulate(system, inputs; options, forecast, progress, cache)
end

"""
    recourse!(frame, system, vars, truth, rows, implemented) -> Int

Write the grid flows that actually result from implementing a plan, and return how many intervals
asked the connection for more than it can carry.

The plan came from an optimization over what the controller *believed*. Three things then happen when
it meets reality, and the split between them is the whole modelling content of imperfect foresight:

  - **Asset setpoints are commands, so they happen.** Charging the battery at 3 kW charges it at
    3 kW whatever the sun does. Their trajectories, and therefore the state carried into the next
    window, are exactly as planned — which is why `carry_state` needs no adjustment.
  - **Curtailment cannot exceed what arrived.** A plan to spill 4 kW of a forecast 6 kW spills only
    what is there if 3 kW turns up.
  - **The meter absorbs the rest.** Whatever the balance still needs is imported or exported, and
    that residual is precisely the cost of having been wrong.

Only when the surplus exceeds the connection is anything further thrown away, because at that point
there is nowhere for it to go.

Under [`PerfectForecast`](@ref) the true series are the believed ones, the residual is the LP's own
import minus its own export, and every number written here equals the value the solver returned.
"""
function recourse!(frame, system, vars, truth::SimulationInputs, rows, implemented::Integer)
    connection = system.connection_kw
    planned = zeros(Float64, implemented)          # asset production minus asset consumption
    for (asset, avars) in zip(system.assets, vars.assets)
        terms = power_terms(asset, avars)
        for k = 1:implemented
            planned[k] += value(terms.production[k]) - value(terms.consumption[k])
        end
    end
    overrun = 0
    for (k, row) in enumerate(rows)
        pv = truth.pv_kw[row]
        curtail = min(value(vars.curtail[k]), pv)
        net = (pv - curtail) + planned[k] - truth.load_kw[row]
        if net >= 0
            export_kw = min(net, connection)
            # Anything above the connection has nowhere to go, so it is spilled on top of whatever
            # the plan already meant to spill.
            curtail += net - export_kw
            frame.export_kw[row] = export_kw
            frame.import_kw[row] = 0.0
        else
            frame.export_kw[row] = 0.0
            frame.import_kw[row] = -net
            -net > connection + 1e-9 && (overrun += 1)
        end
        frame.curtail_kw[row] = curtail
    end
    return overrun
end
