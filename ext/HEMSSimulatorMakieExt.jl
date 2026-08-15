"""
    HEMSSimulatorMakieExt

Methods for the plotting functions declared in `src/plots.jl`, loaded when Makie is — `using
GLMakie` being the usual way in, though any Makie backend works.

Everything here is drawing. The window arithmetic, the colour table and the per-asset descriptions
of what a state panel contains all live in the package proper, so the logic most likely to be wrong
is ordinary Julia that loads without a plotting stack.
"""
module HEMSSimulatorMakieExt

using HEMSSimulator
using HEMSSimulator:
    ASSET_COLOURS,
    Bill,
    Contract,
    Intervals,
    HomeSystem,
    RunOptions,
    Weather,
    PLOT_MAX_POINTS,
    SimulationResult,
    StatePanel,
    bill_components,
    block_first,
    block_mean,
    flow_series,
    interval_range,
    plot_blocks,
    state_panels,
    with_assets
using DataFrames: DataFrame, nrow
using Dates: Date, DateTime, Day
using Makie
using Makie: Axis, Figure, Label, Legend, Point2f, RGBAf, Theme

const HOURS_PER_DAY = 24

_colour(hex::AbstractString, alpha::Real = 1.0) = (Makie.parse(Makie.Colorant, hex), alpha)

# Hours from the start of the drawn window, which reads better on an axis than absolute timestamps
# and stays honest when the series has been averaged into blocks.
function _axis_hours(result::SimulationResult, rows, blocks::Integer)
    dt = hours(result.grid)
    centres = [(k - first(rows)) * dt for k in rows]
    return block_first(centres, blocks)
end

function _window(result::SimulationResult, days, max_points::Integer)
    rows = interval_range(result.grid, days)
    blocks = plot_blocks(length(rows), max_points)
    return rows, blocks, _axis_hours(result, rows, blocks)
end

_note(blocks::Integer, dt::Real) =
    blocks == 1 ? "" : "averaged over $(round(blocks * dt; digits = 2)) h blocks"

# Minor ticks between the majors on both axes. Four on x puts a mark every three hours under a
# twelve-hour label, which is the resolution a reader actually wants to interpolate against; two on y
# halves the gridline spacing without turning the panel into graph paper.
function _minor_ticks!(axis::Axis; x::Bool = true)
    major, minor = RGBAf(0, 0, 0, 0.10), RGBAf(0, 0, 0, 0.04)
    if x
        axis.xminorticksvisible = true
        axis.xminorgridvisible = true
        axis.xminorticks = IntervalsBetween(4)
        axis.xgridcolor = major
        axis.xminorgridcolor = minor
    end
    axis.yminorticksvisible = true
    axis.yminorgridvisible = true
    axis.yminorticks = IntervalsBetween(2)
    axis.ygridcolor = major
    axis.yminorgridcolor = minor
    return axis
end

# A time axis is drawn in hours since the window opened but labelled with dates, so a reader can find
# an evening peak without counting. `time_ticks` does the arithmetic; this only hands it to Makie.
function _time_axis!(axis::Axis, result::SimulationResult, rows)
    dt = hours(result.grid)
    axis.xticks = time_ticks(timestamp(result.grid, first(rows)), length(rows) * dt)
    return _minor_ticks!(axis)
end

# ---------------------------------------------------------------------------------------------
# Dispatch

function HEMSSimulator.dispatch_plot!(
    axis::Axis,
    result::SimulationResult;
    days = 1:3,
    max_points::Integer = PLOT_MAX_POINTS,
    include = nothing,
)
    rows, blocks, x = _window(result, days, max_points)
    series = flow_series(result)
    keep(entries) =
        include === nothing ? entries : [e for e in entries if first(e) in include]

    # Sources stack up from zero, sinks stack down, so the meter balance shows as symmetry.
    function stack!(entries, sign)
        running = zeros(length(x))
        handles = Pair{String,Any}[]
        for (label, (values, hex)) in entries
            drawn = block_mean(values[rows], blocks)
            all(iszero, drawn) && continue
            lower = copy(running)
            running .+= drawn
            colour, = _colour(hex)
            handle = band!(
                axis,
                x,
                sign .* lower,
                sign .* running;
                color = RGBAf(
                    Makie.red(colour),
                    Makie.green(colour),
                    Makie.blue(colour),
                    0.85,
                ),
            )
            push!(handles, label => handle)
        end
        return handles
    end

    handles = vcat(stack!(keep(series.sources), 1), stack!(keep(series.sinks), -1))
    hlines!(axis, [0.0]; color = :black, linewidth = 0.8)

    _time_axis!(axis, result, rows)
    axis.xlabel = _note(blocks, hours(result.grid))
    axis.ylabel = "kW  (sources up, sinks down)"
    return handles
end

function HEMSSimulator.dispatch_plot(
    result::SimulationResult;
    days = 1:3,
    max_points::Integer = PLOT_MAX_POINTS,
    include = nothing,
    size = (1000, 420),
)
    figure = Figure(; size)
    axis = Axis(figure[1, 1]; title = "Dispatch")
    handles = HEMSSimulator.dispatch_plot!(axis, result; days, max_points, include)
    Legend(
        figure[1, 2],
        [handle for (_, handle) in handles],
        [label for (label, _) in handles];
        framevisible = false,
    )
    return figure
end

# ---------------------------------------------------------------------------------------------
# States

function HEMSSimulator.state_plot!(
    axis::Axis,
    panel::StatePanel,
    rows,
    blocks::Integer,
    x::AbstractVector,
)
    # The band moves per interval (a comfort band with a setback); the rules do not.
    if panel.band !== nothing
        lower, upper = panel.band
        band!(
            axis,
            x,
            block_mean(lower[rows], blocks),
            block_mean(upper[rows], blocks);
            color = RGBAf(0.5, 0.5, 0.5, 0.18),
        )
    end
    for (bound, style) in ((panel.lower, :dash), (panel.upper, :dash))
        bound === nothing && continue
        hlines!(axis, [bound]; color = (:black, 0.35), linestyle = style, linewidth = 1)
    end
    if panel.shade !== nothing
        away = panel.shade[rows]
        top = maximum(panel.values[rows]; init = 1.0)
        band!(
            axis,
            x,
            zeros(length(x)),
            block_mean(away .* top, blocks);
            color = RGBAf(0.5, 0.5, 0.5, 0.10),
        )
    end
    colour, = _colour(panel.colour)
    lines!(axis, x, block_mean(panel.values[rows], blocks); color = colour, linewidth = 1.6)
    # Point constraints are drawn by the caller, which knows the window offset in axis units.
    axis.ylabel = panel.label
    return axis
end

function HEMSSimulator.state_plot(
    result::SimulationResult;
    days = 1:3,
    max_points::Integer = PLOT_MAX_POINTS,
    size = (1000, 240),
)
    panels = StatePanel[]
    for (index, asset) in enumerate(result.system.assets)
        append!(panels, state_panels(asset, result, index))
    end
    isempty(panels) && throw(
        ArgumentError(
            "none of the system's $(length(result.system.assets)) assets has a state worth " *
            "plotting; see `state_panels`",
        ),
    )

    rows, blocks, x = _window(result, days, max_points)
    dt = hours(result.grid)
    figure = Figure(; size = (size[1], size[2] * length(panels)))
    axes = Axis[]
    for (row, panel) in enumerate(panels)
        axis = Axis(figure[row, 1])
        HEMSSimulator.state_plot!(axis, panel, rows, blocks, x)
        # Point constraints are drawn here, where the window offset is known.
        marks = [
            (first(x) + (k - first(rows)) * dt, v) for (k, v) in panel.markers if k in rows
        ]
        isempty(marks) || scatter!(
            axis,
            first.(marks),
            last.(marks);
            color = :black,
            marker = :hline,
            markersize = 14,
        )
        _time_axis!(axis, result, rows)
        row == length(panels) ||
            (axis.xticklabelsvisible = false; axis.xlabelvisible = false)
        push!(axes, axis)
    end
    linkxaxes!(axes...)
    axes[end].xlabel = _note(blocks, dt)
    axes[1].title = "State"
    return figure
end

# ---------------------------------------------------------------------------------------------
# Sizing sweep

function HEMSSimulator.sweep_plot!(axis::Axis, table::DataFrame; by::Symbol = :npv)
    hasproperty(table, :capacity_kwh) ||
        throw(ArgumentError("table has no `capacity_kwh` column; is it a sweep table?"))
    hasproperty(table, by) || throw(ArgumentError("table has no `$by` column"))

    groups = if hasproperty(table, :scenario)
        [(string(s), table[findall(==(s), table.scenario), :]) for s in unique(table.scenario)]
    else
        [("", table)]
    end

    handles = Pair{String,Any}[]
    for (index, (label, block)) in enumerate(groups)
        x = block.capacity_kwh
        y = block[!, by]
        line = lines!(
            axis,
            x,
            y;
            linewidth = 1.8,
            color = first(_colour(series_colour(index))),
        )
        index = argmax(y)
        edge = index == 1 || index == nrow(block)
        scatter!(
            axis,
            [x[index]],
            [y[index]];
            color = edge ? :white : line.color[],
            strokecolor = line.color[],
            strokewidth = 1.6,
            markersize = 12,
        )
        isempty(label) || push!(handles, label => line)
    end
    hlines!(axis, [0.0]; color = (:black, 0.3), linewidth = 0.8)
    _minor_ticks!(axis)
    axis.xlabel = "battery capacity, kWh"
    axis.ylabel = string(by)
    return handles
end

function HEMSSimulator.sweep_plot(table::DataFrame; by::Symbol = :npv, size = (760, 420))
    figure = Figure(; size)
    axis = Axis(figure[1, 1]; title = "Business case")
    handles = HEMSSimulator.sweep_plot!(axis, table; by)
    isempty(handles) || Legend(
        figure[1, 2],
        [h for (_, h) in handles],
        [l for (l, _) in handles];
        framevisible = false,
    )
    return figure
end

# ---------------------------------------------------------------------------------------------
# Bill

function HEMSSimulator.bill_plot!(
    axis::Axis,
    bill::Bill;
    baseline::Union{Nothing,Bill} = nothing,
)
    components = bill_components(bill)
    labels = [label for (label, _) in components]
    values = [value for (_, value) in components]

    running = 0.0
    bottoms = Float64[]
    for value in values
        push!(bottoms, running)
        running += value
    end

    colours = [
        v >= 0 ? first(_colour(ASSET_COLOURS.var"import")) :
        first(_colour(ASSET_COLOURS.export_)) for v in values
    ]
    barplot!(
        axis,
        1:length(values),
        bottoms .+ values;
        fillto = bottoms,
        color = colours,
        width = 0.55,
    )
    barplot!(
        axis,
        [length(values) + 1],
        [running];
        color = first(_colour(ASSET_COLOURS.load)),
        width = 0.55,
    )

    # Where each bar would have ended under the baseline, anchored at this bill's own bottom, so
    # the tick reads as "this component moved by that much".
    if baseline !== nothing
        base = [value for (_, value) in bill_components(baseline)]
        marks = vcat(bottoms .+ base, sum(base))
        scatter!(
            axis,
            1:(length(values)+1),
            marks;
            marker = :hline,
            markersize = 22,
            color = RGBAf(0.2, 0.2, 0.2, 0.75),
        )
    end
    hlines!(axis, [0.0]; color = :black, linewidth = 0.8)

    # Categorical x, so minor ticks belong on the money axis only — there is nothing to interpolate
    # between "energy tax" and "transport".
    _minor_ticks!(axis; x = false)
    axis.xticks = (1:(length(labels)+1), vcat(labels, "total"))
    axis.xticklabelrotation = π / 4
    axis.ylabel = "€ over the settled period"
    return axis
end

function HEMSSimulator.bill_plot(
    bill::Bill;
    baseline::Union{Nothing,Bill} = nothing,
    size = (760, 420),
)
    figure = Figure(; size)
    axis = Axis(figure[1, 1]; title = "Bill")
    HEMSSimulator.bill_plot!(axis, bill; baseline)
    return figure
end

# ---------------------------------------------------------------------------------------------
# Interactive dashboard

# Everything about a window that is worth reading as a number rather than a shape.
function _window_kpis(result::SimulationResult, rows)
    frame = result.frame
    dt = hours(result.grid)
    imported = sum(@view frame.import_kw[rows]) * dt
    exported = sum(@view frame.export_kw[rows]) * dt
    pv = (frame.pv_available_kw .- frame.curtail_kw)[rows]
    sinks = HEMSSimulator.onsite_sinks(result)[rows]
    produced = sum(pv)
    self = produced > 0 ? sum(min.(pv, sinks)) / produced : NaN
    cost =
        sum(@view(frame.import_kw[rows]) .* @view(frame.price_buy[rows])) * dt -
        sum(@view(frame.export_kw[rows]) .* @view(frame.price_sell[rows])) * dt
    return """
    import          $(round(imported; digits = 1)) kWh
    export          $(round(exported; digits = 1)) kWh
    PV used         $(round(produced * dt; digits = 1)) kWh
    self-consumed   $(isnan(self) ? "n/a" : string(round(100self; digits = 1)) * "%")
    window cost     €$(round(cost; digits = 2))
    """
end

# RunOptions is immutable, so a strategy switch rebuilds it field for field.
_with_strategy(o::RunOptions, strategy) = RunOptions(
    o.window_hours,
    o.step_hours,
    o.optimizer,
    o.exclusive,
    o.terminal_value,
    o.price_epsilon,
    o.check_degeneracy,
    strategy,
    o.silent,
)

function HEMSSimulator.dashboard(
    system::HomeSystem,
    weather::Weather,
    load_kw::AbstractVector,
    contracts,
    candidates::AbstractVector{<:AbstractAsset};
    options::RunOptions = RunOptions(),
    strategies = nothing,
    width::Integer = 3,
    max_points::Integer = PLOT_MAX_POINTS,
    size = (1500, 900),
)
    regimes = contracts isa Contract ? (; contract = contracts) : contracts
    plans = strategies === nothing ? (; strategy = options.strategy) : strategies
    isempty(candidates) && throw(ArgumentError("give at least one candidate asset"))
    grid = weather.grid
    days = cld(grid.n, intervals_per_day(grid))

    # One simulation per (scenario, candidate, strategy), computed the first time it is asked for.
    # Scrubbing the window never triggers one; changing a menu does, once.
    cache = Dict{Tuple{Symbol,Int,Symbol},SimulationResult}()
    function simulation(scenario::Symbol, candidate::Int, plan::Symbol)
        return get!(cache, (scenario, candidate, plan)) do
            simulate(
                with_assets(system, vcat(system.assets, [candidates[candidate]])),
                weather,
                load_kw,
                regimes[scenario];
                options = _with_strategy(options, plans[plan]),
            )
        end
    end

    scenario_names = collect(keys(regimes))
    plan_names = collect(keys(plans))
    battery_labels = [
        c isa Battery ? string(c.capacity_kwh, " kWh") : string(nameof(typeof(c)), " ", i) for (i, c) in enumerate(candidates)
    ]

    figure = Figure(; size)
    left = figure[1, 1] = GridLayout()
    right = figure[1, 2] = GridLayout(; tellheight = false)
    colsize!(figure.layout, 1, Relative(0.78))

    initial = simulation(first(scenario_names), 1, first(plan_names))
    panel_count = sum(
        length(state_panels(a, initial, i)) for (i, a) in enumerate(initial.system.assets);
        init = 0,
    )

    dispatch_axis = Axis(left[1, 1]; title = "Dispatch")
    state_axes = [Axis(left[1+row, 1]) for row = 1:panel_count]
    rowsize!(left, 1, Relative(0.34))
    linkxaxes!(dispatch_axis, state_axes...)

    # The sliders read in the units a person thinks in: a date to start from, and a width in hours.
    # Their *values* stay an integer day index and an integer hour count; only the labels change.
    per_day = intervals_per_day(grid)
    interval = hours(grid)
    start_date = Date(grid.start)
    widths = sort(unique(vcat([3, 6, 12], collect(24:24:(24*min(28, days))))))
    sliders = SliderGrid(
        left[panel_count+2, 1],
        (
            label = "from",
            range = 1:days,
            startvalue = 1,
            format = day -> string(start_date + Day(day - 1)),
        ),
        (
            label = "width",
            range = widths,
            startvalue = widths[argmin(abs.(widths .- 24 * width))],
            format = span -> span < 24 ? "$(span) h" : "$(span) h  ($(span ÷ 24) d)",
        ),
    )

    scenario_menu = Menu(
        right[1, 1];
        options = string.(scenario_names),
        default = string(first(scenario_names)),
    )
    battery_menu =
        Menu(right[2, 1]; options = battery_labels, default = first(battery_labels))
    Label(right[1, 1, Top()], "scenario"; halign = :left, padding = (0, 0, 4, 0))
    Label(right[2, 1, Top()], "battery"; halign = :left, padding = (0, 0, 4, 0))

    # Only worth a menu when there is a choice to make, so the row below it moves.
    strategy_menu = if length(plan_names) > 1
        Label(right[3, 1, Top()], "strategy"; halign = :left, padding = (0, 0, 4, 0))
        Menu(
            right[3, 1];
            options = string.(plan_names),
            default = string(first(plan_names)),
        )
    else
        nothing
    end
    next_row = strategy_menu === nothing ? 3 : 4

    series = flow_series(initial)
    labels = vcat(first.(series.sources), first.(series.sinks))
    toggles = [Toggle(figure; active = true) for _ in labels]
    right[next_row, 1] = grid!(
        hcat([Label(figure, l; halign = :left) for l in labels], [t for t in toggles]);
        tellheight = false,
    )

    readout = Label(
        right[next_row+1, 1],
        "";
        halign = :left,
        justification = :left,
        font = :regular,
    )

    # Makie blanks a menu's `selection` to `nothing` whenever its `i_selected` reaches 0 — an options
    # update does it, and it is reachable by setting `i_selected` directly. `findfirst` then returns
    # `nothing`, and the next thing to touch it is a `MethodError` inside an event callback, which
    # takes the window down rather than printing. A blank menu has not asked for anything, so hold
    # the last good choice instead of crashing on it.
    last_choice = Ref((1, 1, 1))

    function _chosen(menu, names, previous::Int)
        menu === nothing && return previous
        selection = menu.selection[]
        selection === nothing && return previous
        index = findfirst(==(selection), names)
        return index === nothing ? previous : index
    end

    function refresh()
        previous = last_choice[]
        chosen = (
            _chosen(scenario_menu, string.(scenario_names), previous[1]),
            _chosen(battery_menu, battery_labels, previous[2]),
            _chosen(strategy_menu, string.(plan_names), previous[3]),
        )
        last_choice[] = chosen
        scenario = scenario_names[chosen[1]]
        candidate = chosen[2]
        plan = plan_names[chosen[3]]
        result = simulation(scenario, candidate, plan)

        # Width is in hours, so the window is an exact interval range rather than whole days.
        first_day = sliders.sliders[1].value[]
        span_hours = sliders.sliders[2].value[]
        origin = (first_day - 1) * per_day + 1
        rows = interval_range(
            result.grid,
            Intervals(origin:min(origin+round(Int, span_hours/interval)-1, result.grid.n)),
        )
        blocks = plot_blocks(length(rows), max_points)
        x = _axis_hours(result, rows, blocks)
        keep = [l for (l, t) in zip(labels, toggles) if t.active[]]

        empty!(dispatch_axis)
        HEMSSimulator.dispatch_plot!(
            dispatch_axis,
            result;
            days = Intervals(rows),
            max_points,
            include = keep,
        )
        dispatch_axis.title =
            length(plan_names) > 1 ?
            "Dispatch — $(scenario), $(battery_labels[candidate]), $(plan)" :
            "Dispatch — $(scenario), $(battery_labels[candidate])"

        panels = StatePanel[]
        for (index, asset) in enumerate(result.system.assets)
            append!(panels, state_panels(asset, result, index))
        end
        for (axis, panel) in zip(state_axes, panels)
            empty!(axis)
            HEMSSimulator.state_plot!(axis, panel, rows, blocks, x)
        end
        # The axes are x-linked, so only the bottom one needs a labelled x-axis; `dispatch_plot!`
        # sets one every redraw, which is right for a standalone figure and noise here.
        stacked = vcat(dispatch_axis, state_axes)
        for axis in stacked
            autolimits!(axis)
            _time_axis!(axis, result, rows)
            axis.xticklabelsvisible = false
            axis.xlabelvisible = false
        end
        last(stacked).xticklabelsvisible = true
        last(stacked).xlabelvisible = true
        readout.text[] =
            "$(timestamp(result.grid, first(rows))) → $(timestamp(result.grid, last(rows)))\n\n" *
            _window_kpis(result, rows)
        return nothing
    end

    for slider in sliders.sliders
        on(_ -> refresh(), slider.value)
    end
    on(_ -> refresh(), scenario_menu.selection)
    on(_ -> refresh(), battery_menu.selection)
    strategy_menu === nothing || on(_ -> refresh(), strategy_menu.selection)
    for toggle in toggles
        on(_ -> refresh(), toggle.active)
    end
    refresh()

    return (; figure, refresh, sliders, scenario_menu, battery_menu, strategy_menu, toggles)
end

# ---------------------------------------------------------------------------------------------
# Theme

function HEMSSimulator.hems_theme()
    return Theme(;
        fontsize = 12,
        palette = (color = [first(_colour(hex)) for hex in SERIES_COLOURS],),
        Axis = (;
            rightspinevisible = false,
            topspinevisible = false,
            xgridcolor = RGBAf(0, 0, 0, 0.10),
            ygridcolor = RGBAf(0, 0, 0, 0.10),
            xminorticksvisible = true,
            yminorticksvisible = true,
            xminorgridvisible = true,
            yminorgridvisible = true,
            xminorgridcolor = RGBAf(0, 0, 0, 0.04),
            yminorgridcolor = RGBAf(0, 0, 0, 0.04),
            xminorticks = IntervalsBetween(4),
            yminorticks = IntervalsBetween(2),
        ),
        Legend = (; framevisible = false),
    )
end

end # module
