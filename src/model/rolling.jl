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
    progress = nothing,
    cache::Bool = false,
)
    cache || return _simulate(system, inputs, options, progress)
    key = simulation_key(system, inputs, options)
    hit = _load_simulation(key, system, inputs.grid)
    hit === nothing || return hit
    result = _simulate(system, inputs, options, progress)
    _store_simulation(key, result)
    return result
end

function _simulate(
    system::HomeSystem,
    inputs::SimulationInputs,
    options::RunOptions,
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
    meter_clashes = 0
    asset_clashes = 0
    while first_interval <= grid.n
        remaining = grid.n - first_interval + 1
        len = min(window_len, remaining)
        implemented = min(step_len, remaining)
        ctx = DispatchContext(
            window(grid, first_interval, len),
            dt,
            window(inputs, first_interval, len),
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
        frame.import_kw[rows] .= value.(vars.imported[1:implemented])
        frame.export_kw[rows] .= value.(vars.exported[1:implemented])
        frame.curtail_kw[rows] .= value.(vars.curtail[1:implemented])
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
    progress = nothing,
    cache::Bool = false,
)
    inputs = prepare(system, weather, load_kw, contract; options)
    return simulate(system, inputs; options, progress, cache)
end
