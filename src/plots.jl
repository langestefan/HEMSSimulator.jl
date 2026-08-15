# Plotting. The functions here are documented stubs; their methods live in
# `ext/HEMSSimulatorMakieExt.jl` and appear once Makie is loaded — `using GLMakie` is the usual way,
# and any other backend works too. That keeps the Makie stack, by far the heaviest thing this package could depend on, out of a
# plain `using HEMSSimulator`.
#
# Everything that does not need Makie lives here rather than in the extension: the colour table, the
# window arithmetic, and the per-asset descriptions of what a state panel contains. The extension is
# then only about drawing, and the parts most likely to be wrong are ordinary Julia in the package
# proper.

"""
    ASSET_COLOURS

Colour per flow, as hex strings. Shared by every plot so an asset is the same colour wherever it
appears — an EV in a dispatch plot and in a state plot are visibly the same thing.

Stored as strings rather than `Colorant`s because this file is loaded without Makie.
"""
const ASSET_COLOURS = (
    pv = "#F2B705",
    load = "#2E2E2E",
    var"import" = "#C1436D",
    export_ = "#4C9F70",
    battery = "#3B7EA1",
    ev = "#7B5EA7",
    heatpump = "#D96C3B",
    dhw = "#3FA7A0",
    curtail = "#9E9E9E",
    neutral = "#767676",
)

"""
    PLOT_MAX_POINTS

Above this many points in a window, the time-series plots average into blocks before drawing. A year
at 15-minute resolution is 35 136 intervals: Cairo will draw them all, slowly, and the result is
unreadable. See [`plot_blocks`](@ref).
"""
const PLOT_MAX_POINTS = 1500

"""
    Intervals(range)

A window given as exact interval indices rather than as whole days, for a caller that has already
worked out where it wants to look — a slider measuring width in hours, say. Wrapping it keeps
[`interval_range`](@ref) unambiguous: a bare `1:3` means the first three *days*, and there is no way
to tell that apart from three intervals without saying which you meant.
"""
struct Intervals{R<:AbstractUnitRange{<:Integer}}
    range::R
end

"""
    interval_range(grid::TimeGrid, days) -> UnitRange{Int}

Interval indices covered by `days`, which may be

  - an integer — that day of the horizon, 1-based;
  - an integer range — those days, so `1:3` is the first three days;
  - a `Date` or a range of `Date`s — those calendar days;
  - an [`Intervals`](@ref) — exact interval indices, for sub-day windows;
  - `:` or `nothing` — the whole horizon.

Throws if the selection falls outside the horizon, rather than silently clipping to nothing.
"""
function interval_range(grid::TimeGrid, days)
    per_day = intervals_per_day(grid)
    total = grid.n

    range_of(first_day, last_day) = begin
        1 <= first_day <= last_day || throw(
            ArgumentError("day selection $days is empty or starts before the horizon"),
        )
        start = (first_day - 1) * per_day + 1
        start <= total || throw(
            ArgumentError(
                "day $first_day starts at interval $start but the horizon has $total",
            ),
        )
        return start:min(last_day*per_day, total)
    end

    days === nothing && return 1:total
    days === Colon() && return 1:total
    if days isa Intervals
        first(days.range) >= 1 && last(days.range) <= total || throw(
            ArgumentError(
                "interval selection $(days.range) falls outside the horizon's 1:$total",
            ),
        )
        isempty(days.range) && throw(ArgumentError("interval selection is empty"))
        return first(days.range):last(days.range)
    end
    days isa Integer && return range_of(days, days)
    days isa AbstractUnitRange{<:Integer} && return range_of(first(days), last(days))
    if days isa Date
        return interval_range(grid, days:days)
    end
    if days isa AbstractRange{Date}
        origin = Date(grid.start)
        offset(d) = Dates.value(d - origin) + 1
        return range_of(offset(first(days)), offset(last(days)))
    end
    throw(
        ArgumentError(
            "`days` must be an integer, an integer range, a Date, a Date range, or `:`; " *
            "got $(typeof(days))",
        ),
    )
end

"""
    plot_blocks(n, max_points = PLOT_MAX_POINTS) -> Int

How many consecutive intervals to average into one drawn point so that `n` intervals become at most
`max_points`. Returns 1 when no aggregation is needed.
"""
plot_blocks(n::Integer, max_points::Integer = PLOT_MAX_POINTS) =
    n <= max_points ? 1 : cld(n, max_points)

"""
    block_mean(values, block) -> Vector{Float64}

Average `values` in consecutive groups of `block`. A short final group is averaged over what it has,
so no interval is silently dropped. `block == 1` copies.
"""
function block_mean(values::AbstractVector, block::Integer)
    block <= 1 && return collect(Float64, values)
    n = length(values)
    out = Vector{Float64}(undef, cld(n, block))
    for (index, start) in enumerate(1:block:n)
        stop = min(start + block - 1, n)
        out[index] = sum(Float64, @view values[start:stop]) / (stop - start + 1)
    end
    return out
end

"""
    block_first(values, block) -> Vector

Take the first element of each group of `block`. Used for the timestamps that label a block, where
averaging would be meaningless.
"""
block_first(values::AbstractVector, block::Integer) =
    block <= 1 ? collect(values) : collect(values[1:block:end])

# Frame column an asset's declared name ended up in, or `nothing` when the asset never wrote it.
function _column_for(result::SimulationResult, index::Integer, name::Symbol)
    mapping = get(result.asset_columns, index, Dict{Symbol,Symbol}())
    column = get(mapping, name, name)
    return hasproperty(result.frame, column) ? column : nothing
end

"""
    StatePanel

One row of a [`state_plot`](@ref): a stored quantity against the limits it has to respect.

# Fields

  - `label::String`: axis label, including units.
  - `values::Vector{Float64}`: the trajectory, one element per interval of the horizon.
  - `lower::Union{Nothing,Float64}`, `upper::Union{Nothing,Float64}`: constant bounds to draw as
    rules, if any.
  - `band::Union{Nothing,Tuple{Vector{Float64},Vector{Float64}}}`: a per-interval band to shade,
    for limits that move — the comfort band being the reason this exists.
  - `markers::Vector{Tuple{Int,Float64}}`: point constraints, as (interval, value). EV departure
    targets.
  - `shade::Union{Nothing,BitVector}`: intervals to grey out, for "the car is not here".
  - `colour::String`: from [`ASSET_COLOURS`](@ref).
"""
Base.@kwdef struct StatePanel
    label::String
    values::Vector{Float64}
    lower::Union{Nothing,Float64} = nothing
    upper::Union{Nothing,Float64} = nothing
    band::Union{Nothing,Tuple{Vector{Float64},Vector{Float64}}} = nothing
    markers::Vector{Tuple{Int,Float64}} = Tuple{Int,Float64}[]
    shade::Union{Nothing,BitVector} = nothing
    colour::String = ASSET_COLOURS.neutral
end

"""
    state_panels(asset, result, index) -> Vector{StatePanel}

What [`state_plot`](@ref) should draw for `asset`, the `index`-th asset of `result`'s system.

Unlike the meter balance, this cannot be derived from the asset contract: a battery's limits are
constant fractions of capacity, a car's are deadlines at particular instants, and a house's move
every interval. So each asset that has something worth watching gets a method here, and the default
is to draw nothing. Adding one is optional — an asset without a method is simply absent from the
plot rather than wrong in it.

This lives in the package rather than in the Makie extension so that it needs no plotting library:
it returns data, not drawings.
"""
state_panels(::AbstractAsset, ::SimulationResult, ::Integer) = StatePanel[]

function state_panels(battery::Battery, result::SimulationResult, index::Integer)
    column = _column_for(result, index, :battery_soc_kwh)
    column === nothing && return StatePanel[]
    return [
        StatePanel(;
            label = "battery, kWh",
            values = collect(Float64, result.frame[!, column]),
            lower = battery.soc_min * battery.capacity_kwh,
            upper = battery.soc_max * battery.capacity_kwh,
            colour = ASSET_COLOURS.battery,
        ),
    ]
end

function state_panels(ev::ElectricVehicle, result::SimulationResult, index::Integer)
    column = _column_for(result, index, :ev_soc_kwh)
    column === nothing && return StatePanel[]
    horizon = 1:result.grid.n
    return [
        StatePanel(;
            label = "EV, kWh",
            values = collect(Float64, result.frame[!, column]),
            lower = ev.soc_min * ev.capacity_kwh,
            upper = ev.soc_max * ev.capacity_kwh,
            markers = [(k, ev.target_kwh[k]) for k in horizon if ev.target_kwh[k] > 0],
            shade = .!ev.connected[horizon],
            colour = ASSET_COLOURS.ev,
        ),
    ]
end

function state_panels(hp::HeatPump, result::SimulationResult, index::Integer)
    column = _column_for(result, index, :indoor_temp)
    column === nothing && return StatePanel[]
    horizon = 1:result.grid.n
    setpoint = hp.setpoint[horizon]
    return [
        StatePanel(;
            label = "indoor, °C",
            values = collect(Float64, result.frame[!, column]),
            band = (setpoint .- hp.band, setpoint .+ hp.band),
            colour = ASSET_COLOURS.heatpump,
        ),
    ]
end

function state_panels(tank::WaterTank, result::SimulationResult, index::Integer)
    column = _column_for(result, index, :dhw_energy_kwh)
    column === nothing && return StatePanel[]
    return [
        StatePanel(;
            label = "tank, kWh",
            values = collect(Float64, result.frame[!, column]),
            lower = tank_reserve_kwh(tank),
            upper = tank_capacity_kwh(tank),
            colour = ASSET_COLOURS.dhw,
        ),
    ]
end

"""
    flow_series(result::SimulationResult) -> (; sources, sinks)

The stacked series a [`dispatch_plot`](@ref) draws, each as `label => (values, colour)`.

Sources and sinks come from the assets' own [`consumption_columns`](@ref) and
[`production_columns`](@ref) — the same declarations [`balance_residual`](@ref) uses. So a new asset
appears in the plot without the plotting code knowing anything about it, and the picture cannot
disagree with the accounting.
"""
function flow_series(result::SimulationResult)
    frame = result.frame
    sources = Pair{String,Tuple{Vector{Float64},String}}[
        "PV"=>(frame.pv_available_kw .- frame.curtail_kw, ASSET_COLOURS.pv),
        "import"=>(collect(Float64, frame.import_kw), ASSET_COLOURS.var"import"),
    ]
    sinks = Pair{String,Tuple{Vector{Float64},String}}[
        "export"=>(collect(Float64, frame.export_kw), ASSET_COLOURS.export_),
        "curtailed"=>(collect(Float64, frame.curtail_kw), ASSET_COLOURS.curtail),
    ]

    for (index, asset) in enumerate(result.system.assets)
        for (declared_names, into) in
            ((production_columns(asset), sources), (consumption_columns(asset), sinks))
            for declared in declared_names
                column = _column_for(result, index, declared)
                column === nothing && continue
                values = collect(Float64, frame[!, column])
                all(iszero, values) && continue
                push!(
                    into,
                    _flow_label(declared, column) => (values, _flow_colour(declared)),
                )
            end
        end
    end
    # The base load is a sink like any other, and always present.
    push!(sinks, "load" => (collect(Float64, frame.load_kw), ASSET_COLOURS.load))
    return (; sources, sinks)
end

# A second asset of the same type writes to a suffixed column; carry that suffix into the label so
# two batteries are distinguishable, and only then. The asset's own index is not the suffix — an EV
# that happens to be asset 2 is still the only EV.
function _flow_label(declared::Symbol, column::Symbol)
    text = replace(string(declared), "_kw" => "", "_" => " ")
    column === declared && return text
    suffix = replace(string(column), string(declared) => "", "_" => "")
    return "$text ($suffix)"
end

function _flow_colour(column::Symbol)
    name = string(column)
    startswith(name, "battery") && return ASSET_COLOURS.battery
    startswith(name, "ev") && return ASSET_COLOURS.ev
    startswith(name, "heatpump") && return ASSET_COLOURS.heatpump
    startswith(name, "dhw") && return ASSET_COLOURS.dhw
    return ASSET_COLOURS.neutral
end

"""
    flow_table(result::SimulationResult; days = :) -> DataFrame

The data behind a [`dispatch_plot`](@ref), in long form: one row per interval per series.

| column | |
|:--|:--|
| `timestamp` | interval beginning, UTC |
| `hour` | hours from the start of the window, which is what a plot's x-axis wants |
| `series` | `"PV"`, `"import"`, `"battery discharge"`, … as the legend would say |
| `direction` | `:source` or `:sink` |
| `kw` | always positive; `direction` carries the sign |

This exists so that simulating and plotting can be separate steps. A study writes this to CSV once,
and a figure script reads it back and redraws as often as the figure needs changing — without
re-solving a year. It is also the honest artifact: the numbers behind a picture, in a form anyone
can check with a spreadsheet.

Series come from [`flow_series`](@ref), so they agree with the meter balance by construction.
"""
function flow_table(result::SimulationResult; days = Colon())
    rows = interval_range(result.grid, days)
    dt = hours(result.grid)
    stamps = timestamps(result.grid)
    series = flow_series(result)
    table = DataFrame(
        timestamp = DateTime[],
        hour = Float64[],
        series = String[],
        direction = Symbol[],
        kw = Float64[],
    )
    for (direction, entries) in ((:source, series.sources), (:sink, series.sinks))
        for (label, (values, _)) in entries
            all(iszero, @view values[rows]) && continue
            for k in rows
                push!(
                    table,
                    (stamps[k], (k - first(rows)) * dt, label, direction, values[k]),
                )
            end
        end
    end
    return table
end

"""
    state_table(result::SimulationResult; days = :) -> DataFrame

The data behind a [`state_plot`](@ref), in long form: one row per interval per panel, carrying the
limits alongside the trajectory so a figure script needs nothing else.

| column | |
|:--|:--|
| `timestamp`, `hour` | as [`flow_table`](@ref) |
| `panel` | `"battery, kWh"`, `"indoor, °C"`, … |
| `value` | the trajectory |
| `lower`, `upper` | constant bounds, `missing` when the panel has none |
| `band_lower`, `band_upper` | per-interval bounds — the comfort band — else `missing` |
| `target` | a point constraint at this interval, else `missing` |
| `away` | `true` where the asset is absent, for the EV's shading |

Same purpose as `flow_table`: it lets the plotting step be re-run without the simulation step.
"""
function state_table(result::SimulationResult; days = Colon())
    rows = interval_range(result.grid, days)
    dt = hours(result.grid)
    stamps = timestamps(result.grid)
    panels = StatePanel[]
    for (index, asset) in enumerate(result.system.assets)
        append!(panels, state_panels(asset, result, index))
    end

    table = DataFrame(
        timestamp = DateTime[],
        hour = Float64[],
        panel = String[],
        value = Float64[],
        lower = Union{Missing,Float64}[],
        upper = Union{Missing,Float64}[],
        band_lower = Union{Missing,Float64}[],
        band_upper = Union{Missing,Float64}[],
        target = Union{Missing,Float64}[],
        away = Bool[],
    )
    for panel in panels
        targets = Dict(panel.markers)
        for k in rows
            push!(
                table,
                (
                    stamps[k],
                    (k - first(rows)) * dt,
                    panel.label,
                    panel.values[k],
                    panel.lower === nothing ? missing : panel.lower,
                    panel.upper === nothing ? missing : panel.upper,
                    panel.band === nothing ? missing : panel.band[1][k],
                    panel.band === nothing ? missing : panel.band[2][k],
                    get(targets, k, missing),
                    panel.shade === nothing ? false : panel.shade[k],
                ),
            )
        end
    end
    return table
end

"""
    dispatch_plot(result::SimulationResult; days = 1:3, max_points = PLOT_MAX_POINTS)
    dispatch_plot!(axis, result; kwargs...)

Where the energy comes from and where it goes, over time.

Sources — PV actually used, import, and anything the assets discharge — are stacked upward; sinks —
export, curtailment, the base load and anything the assets consume — are stacked downward, so the
meter balance is visible as the two halves mirroring each other. Which series exist is taken from
the assets themselves, so this needs no updating when an asset is added.

`days` selects a window ([`interval_range`](@ref)); the default is the first three days, because a
year at 15 minutes is 35 136 points and unreadable. A longer window is averaged into blocks so that
at most `max_points` are drawn, and the axis label says so.

`include` restricts the drawn series to those labels — `["PV", "import", "load"]` to strip a
four-asset stack back to something readable. `nothing`, the default, draws everything.

Requires a Makie backend: `using GLMakie` first.
"""
function dispatch_plot end

"""
    dispatch_plot!(axis, result::SimulationResult; kwargs...)

Draw a [`dispatch_plot`](@ref) into an existing axis, for composing into your own figure.
"""
function dispatch_plot! end

"""
    state_plot(result::SimulationResult; days = 1:3, max_points = PLOT_MAX_POINTS)

One panel per stored quantity — battery and EV state of charge, tank energy, indoor temperature —
each drawn against the limits it has to respect: state-of-charge bounds, departure targets, the
comfort band, the tank's reserve. Intervals where the car is away are shaded.

This is the picture of what the integration tests assert numerically, which makes it the fastest way
to see *why* a run violated something.

Assets with nothing worth watching are omitted; see [`state_panels`](@ref). Requires Makie.
"""
function state_plot end

"""
    state_plot!(axis, panel::StatePanel; kwargs...)

Draw a single [`StatePanel`](@ref) into an existing axis.
"""
function state_plot! end

"""
    sweep_plot(table::DataFrame; by = :npv)
    sweep_plot!(axis, table; by = :npv)

The business case against battery size: `by` on the left axis, annual savings on the right, and the
optimum marked. A table from a scenario sweep — one with a `scenario` column — gets one series per
regime, which is the comparison the four scenarios exist to make.

The optimum is marked with the same rule [`best`](@ref) uses, and an optimum at the edge of the
candidate range is drawn hollow: it means the range did not bracket it. Requires Makie.
"""
function sweep_plot end

"""
    sweep_plot!(axis, table::DataFrame; by = :npv)

Draw a [`sweep_plot`](@ref) into an existing axis.
"""
function sweep_plot! end

"""
    bill_plot(bill::Bill; baseline = nothing)
    bill_plot!(axis, bill; baseline = nothing)

A waterfall of what the household pays: commodity, the netting credit, feed-in revenue, energy tax,
the tax credit, transport, fixed charges and VAT, running to the total. Pass `baseline` — the no-battery bill, usually — and each bar gets a tick showing where it would
have ended under that baseline, so the components that actually moved are the ones that stand out.
A second full waterfall behind this one would not do: the two have different cumulative paths, so
its bars would float at unrelated heights and read as noise.

Costs run up and credits run down, so the sign convention of [`Bill`](@ref) is visible rather than
implied. Requires Makie.
"""
function bill_plot end

"""
    bill_plot!(axis, bill::Bill; baseline = nothing)

Draw a [`bill_plot`](@ref) into an existing axis.
"""
function bill_plot! end

"""
    bill_components(bill::Bill) -> Vector{Pair{String,Float64}}

The waterfall steps of a [`Bill`](@ref), in the order they are charged, signed as they affect the
total. Their sum is `bill.total`, which is what makes the waterfall close.
"""
bill_components(bill::Bill) = [
    "commodity" => bill.commodity_cost,
    "netting" => -bill.netting_credit,
    "feed-in" => -bill.feed_in_revenue,
    "energy tax" => bill.energy_tax,
    "tax credit" => bill.tax_credit,
    "transport" => bill.transport_cost,
    "fixed" => bill.fixed_cost,
    "VAT" => bill.vat,
]

"""
    dashboard(system, weather, load_kw, contracts, candidates; kwargs...)

An interactive window over a whole study: scrub the time axis, switch regulatory scenario and
battery size, hide series, and read the numbers for whatever is on screen.

The static plots answer a question you already have. This one is for the questions you do not have
yet — what the battery is doing in February, why one scenario cycles harder, whether that spike is
the car or the heat pump.

Needs a Makie backend that can open a window and handle events: **GLMakie**. Under a file-writing
backend the figure still builds, but nothing responds.

# Controls

  - **day** and **width** sliders move the window over the horizon. Free — no resimulation.
  - **scenario**, **battery** and, when more than one is offered, **strategy** menus. Each
    combination is simulated once, on first selection, and cached; a month is seconds, a year a few.
  - **toggles** filter the dispatch stack. State panels always show every asset.
  - a **KPI block** recomputed for the visible window: energy in and out, self-consumption, and what
    that window cost at the dispatch price.

# Arguments

  - `contracts`: a [`Contract`](@ref), or the `NamedTuple` from [`scenarios`](@ref).
  - `candidates`: the assets to offer in the battery menu. Each is *added* to `system`'s own assets,
    exactly as [`sweep`](@ref) does, so a home that already has a car keeps it in every view.
  - `strategies`: a `NamedTuple` of [`AbstractStrategy`](@ref) to offer, or `nothing` to use only
    the one already in `options`. Strategy lives in [`RunOptions`](@ref) rather than in the
    contract, so it needs its own menu to be comparable side by side.

The drawing is the same `dispatch_plot!` and `state_plot!` the static figures use, redrawn on
change rather than rebuilt around observables — one drawing path, two front ends, so the
interactive view cannot drift away from the figures you put in a report.
"""
function dashboard end

"""
    hems_theme() -> Makie.Theme

An opt-in theme: muted grid, no top or right spine, a serif-free stack, and the package's own colour
cycle. Nothing applies it for you — `set_theme!(hems_theme())` if you want it, and every plot works
without it.

Requires Makie.
"""
function hems_theme end

# Without Makie the plotting functions exist but have no methods, so calling one gives a bare
# `MethodError` naming a function the user can see is exported. The hint says what is actually
# missing. Registered in `__init__` because error hints are runtime state, not precompilable.
const _PLOT_FUNCTIONS = (
    dashboard,
    dispatch_plot,
    dispatch_plot!,
    state_plot,
    state_plot!,
    sweep_plot,
    sweep_plot!,
    bill_plot,
    bill_plot!,
    hems_theme,
)

function _register_plot_hint()
    Base.Experimental.register_error_hint(MethodError) do io, exception, _, _
        exception.f in _PLOT_FUNCTIONS || return nothing
        print(
            io,
            "\n\n`$(nameof(exception.f))` is provided by HEMSSimulator's Makie extension. ",
            "Run `using GLMakie` (or another Makie backend) and try again.",
        )
        return nothing
    end
    return nothing
end
