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
    HomeSystem,
    Intervals,
    PlotTheme,
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
    plot_theme,
    state_panels,
    with_assets
using DataFrames: DataFrame, nrow
using Dates: Date, DateTime, Day, Millisecond
using Makie
using Makie: Axis, Box, Figure, Label, Legend, Point2f, PolyElement, RGBAf, Theme, to_color

const HOURS_PER_DAY = 24

_colour(hex::AbstractString, alpha::Real = 1.0) = (Makie.parse(Makie.Colorant, hex), alpha)

# Makie's block attributes are typed, and not uniformly. An `Axis` parses a hex string for you; a
# `Menu`'s cell colours, a `Toggle`'s frame and a `Box`'s fill are `RGBAf` fields, and a String
# assigned to one of those survives the assignment and then fails *inside the render loop* — where it
# takes the window down with a `convert(::String, ::RGBA)` that names none of this code. So every
# colour crosses into Makie through here.
_c(hex::AbstractString) = to_color(hex)

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
    colours = ASSET_COLOURS,
    now = nothing,
    zero_colour = :black,
)
    rows, blocks, x = _window(result, days, max_points)
    dt = hours(result.grid)
    series = flow_series(result; colours)
    keep(entries) =
        include === nothing ? entries : [e for e in entries if first(e) in include]

    # Bars rather than a filled band, which is what VRM draws and what the quantity actually is: an
    # interval's energy, not a value sampled at an instant. Each bar spans its own block, so the
    # width is the block width and the anchor is its centre.
    span = blocks * dt
    centres = x .+ span / 2

    # Sources stack up from zero, sinks stack down, so the meter balance shows as symmetry.
    function stack!(entries, sign)
        running = zeros(length(x))
        handles = Pair{String,Any}[]
        for (label, (values, hex)) in entries
            drawn = block_mean(values[rows], blocks)
            all(iszero, drawn) && continue
            lower = copy(running)
            running .+= drawn
            handle = barplot!(
                axis,
                centres,
                sign .* running;
                fillto = sign .* lower,
                width = span,
                gap = 0,
                color = first(_colour(hex)),
            )
            push!(handles, label => handle)
        end
        return handles
    end

    _cursor!(axis, result, rows, now)
    handles = vcat(stack!(keep(series.sources), 1), stack!(keep(series.sinks), -1))
    hlines!(axis, [0.0]; color = zero_colour, linewidth = 0.8)

    _time_axis!(axis, result, rows)
    axis.xlabel = _note(blocks, dt)
    axis.ylabel = "kW  (sources up, sinks down)"
    return handles
end

# The "Now" band. A simulation has no now — every interval of it has already been solved — so this is
# opt-in rather than derived: pass a `DateTime` to mark the instant a reader should be looking at.
function _cursor!(axis::Axis, result::SimulationResult, rows, now)
    now === nothing && return nothing
    dt = hours(result.grid)
    origin = timestamp(result.grid, first(rows))
    offset = (now - origin) / Millisecond(1) / 3_600_000
    0 <= offset <= length(rows) * dt || return nothing
    vspan!(axis, offset, offset + dt; color = RGBAf(0.5, 0.5, 0.5, 0.35))
    return offset
end

function HEMSSimulator.dispatch_plot(
    result::SimulationResult;
    days = 1:3,
    max_points::Integer = PLOT_MAX_POINTS,
    include = nothing,
    colours = ASSET_COLOURS,
    now = nothing,
    size = (1000, 420),
)
    figure = Figure(; size)
    axis = Axis(figure[1, 1]; title = "Dispatch")
    handles =
        HEMSSimulator.dispatch_plot!(axis, result; days, max_points, include, colours, now)
    Legend(
        figure[1, 2],
        [handle for (_, handle) in handles],
        [label for (label, _) in handles];
        framevisible = false,
    )
    return figure
end

# ---------------------------------------------------------------------------------------------
# Prices

function HEMSSimulator.price_plot!(
    axis::Axis,
    result::SimulationResult;
    days = 1:3,
    max_points::Integer = PLOT_MAX_POINTS,
    colours = ASSET_COLOURS,
    now = nothing,
)
    rows, blocks, x = _window(result, days, max_points)
    dt = hours(result.grid)

    # Steps, not a line. A quarter-hour price is flat across its interval and jumps at the boundary;
    # joining the points with a slope would draw a price that was never charged.
    _cursor!(axis, result, rows, now)
    handles = Pair{String,Any}[]
    for (label, column, hex) in (
        ("buy price", :price_buy, colours.var"import"),
        ("sell price", :price_sell, colours.export_),
    )
        values = block_mean(result.frame[!, column][rows], blocks)
        edges = vcat(x, last(x) + blocks * dt)
        handle = stairs!(
            axis,
            edges,
            vcat(values, last(values));
            step = :post,
            color = first(_colour(hex)),
            linewidth = 1.8,
        )
        push!(handles, label => handle)
    end

    _time_axis!(axis, result, rows)
    axis.xlabel = _note(blocks, dt)
    axis.ylabel = "€/kWh"
    return handles
end

function HEMSSimulator.price_plot(
    result::SimulationResult;
    days = 1:3,
    max_points::Integer = PLOT_MAX_POINTS,
    colours = ASSET_COLOURS,
    now = nothing,
    size = (1000, 320),
)
    figure = Figure(; size)
    axis = Axis(figure[1, 1]; title = "Energy prices")
    handles = HEMSSimulator.price_plot!(axis, result; days, max_points, colours, now)
    Legend(
        figure[2, 1],
        [h for (_, h) in handles],
        [l for (l, _) in handles];
        orientation = :horizontal,
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

# Everything about a window that is worth reading as a number rather than a shape. Returned as
# numbers rather than a formatted block, because the cards each want one of them on its own.
function _window_totals(result::SimulationResult, rows)
    frame = result.frame
    dt = hours(result.grid)
    pv = (frame.pv_available_kw .- frame.curtail_kw)[rows]
    sinks = HEMSSimulator.onsite_sinks(result)[rows]
    produced = sum(pv)
    return (;
        imported = sum(@view frame.import_kw[rows]) * dt,
        exported = sum(@view frame.export_kw[rows]) * dt,
        pv = produced * dt,
        self = produced > 0 ? sum(min.(pv, sinks)) / produced : NaN,
        cost = sum(@view(frame.import_kw[rows]) .* @view(frame.price_buy[rows])) * dt -
               sum(@view(frame.export_kw[rows]) .* @view(frame.price_sell[rows])) * dt,
    )
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
    o.direct,
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
    precompute::Bool = true,
    cache::Bool = false,
    investment = nothing,
    theme::Symbol = :dark,
    size = (1500, 1020),
)
    regimes = contracts isa Contract ? (; contract = contracts) : contracts
    plans = strategies === nothing ? (; strategy = options.strategy) : strategies
    isempty(candidates) && throw(ArgumentError("give at least one candidate asset"))
    grid = weather.grid
    days = cld(grid.n, intervals_per_day(grid))
    scenario_names = collect(keys(regimes))
    plan_names = collect(keys(plans))

    # Candidate 0 is the home *without* a candidate — the baseline every saving is measured against,
    # and the reason the financial cards can show a saving at all.
    _assets(candidate::Int) =
        candidate == 0 ? system.assets : vcat(system.assets, [candidates[candidate]])

    _run(scenario::Symbol, candidate::Int, plan::Symbol; progress = nothing) = simulate(
        with_assets(system, _assets(candidate)),
        weather,
        load_kw,
        regimes[scenario];
        options = _with_strategy(options, plans[plan]),
        progress,
        cache,
    )

    # One simulation per (scenario, candidate, strategy), held for the life of the window. Named
    # `memo` rather than `cache` because `cache` is the keyword deciding whether `simulate` consults
    # the *disk*, and a local of that name silently shadows it — which is exactly what it did.
    memo = Dict{Tuple{Symbol,Int,Symbol},SimulationResult}()
    simulation(scenario::Symbol, candidate::Int, plan::Symbol) =
        get!(() -> _run(scenario, candidate, plan), memo, (scenario, candidate, plan))

    # Every combination up front rather than one per click, and threaded like `sweep`. Solving on
    # demand looks cheaper, but the solve runs *inside the menu's event callback*: a year is 35 040
    # solves and some minutes, and for all of them GLMakie processes no events, so the window goes
    # unresponsive and the desktop offers to kill it. That is not slowness, it is a crash. Paying the
    # cost once, before the window exists, makes every interaction afterwards instant.
    if precompute
        combos = [
            (scenario, candidate, plan) for scenario in scenario_names for
            candidate = 0:length(candidates) for plan in plan_names
        ]
        # One bar over *windows*, not over combinations. With more threads than combinations they all
        # run at once and finish together, so a combination-level bar would sit at zero for the whole
        # wait and then jump to done — precisely the shape that tells you nothing.
        per_combo = cld(grid.n, max(1, round(Int, options.step_hours / hours(grid))))
        bar = ProgressBar(
            length(combos) * per_combo;
            label = "simulating $(length(combos)) combination(s) on $(Threads.nthreads()) thread(s)",
        )
        computed = Vector{SimulationResult}(undef, length(combos))
        Threads.@threads for k in eachindex(combos)
            computed[k] = _run(combos[k]...; progress = (_, _) -> step!(bar))
        end
        for (k, combo) in enumerate(combos)
            memo[combo] = computed[k]
        end
    end
    battery_labels = [
        c isa Battery ? string(c.capacity_kwh, " kWh") : string(nameof(typeof(c)), " ", i) for (i, c) in enumerate(candidates)
    ]

    # The live theme. Everything drawn reads `palette[]` rather than a captured value, so the switch
    # is a redraw and not a rebuild.
    palette = Ref(plot_theme(theme))

    figure = Figure(; size, backgroundcolor = _c(palette[].background))
    left = figure[1, 1] = GridLayout()
    right = figure[1, 2] = GridLayout(; tellheight = false)
    cards = figure[2, 1:2] = GridLayout()
    money = figure[3, 1:2] = GridLayout()
    colsize!(figure.layout, 1, Relative(0.80))

    initial = simulation(first(scenario_names), 1, first(plan_names))
    initial_panels = StatePanel[]
    for (index, asset) in enumerate(initial.system.assets)
        append!(initial_panels, state_panels(asset, initial, index))
    end
    panel_count = length(initial_panels)

    # VRM's arrangement: a section heading, the unit written horizontally above the axis rather than
    # rotated beside it, the plot, then a horizontal legend underneath. Prices on top, energy below.
    headings = Label[]
    units = Label[]
    function _section(row, title, unit)
        push!(
            headings,
            Label(
                left[row, 1],
                title;
                halign = :left,
                fontsize = 15,
                tellwidth = false,
                padding = (0, 0, 2, 10),
            ),
        )
        # The unit goes above the axis, horizontal, the way VRM writes it — not rotated up the side.
        push!(
            units,
            Label(
                left[row+1, 1],
                unit;
                halign = :left,
                fontsize = 10,
                tellwidth = false,
                padding = (4, 0, 2, 0),
            ),
        )
        return Axis(left[row+2, 1])
    end

    price_axis = _section(1, "Energy prices", "€/kWh")
    energy_axis = _section(5, "Energy", "kW  (sources up, sinks down)")
    state_axes = [Axis(left[8+row, 1]) for row = 1:panel_count]
    linkxaxes!(price_axis, energy_axis, state_axes...)
    # The two headline panels carry most of the height; the state panels still need enough not to
    # collapse their y ticks into a smear.
    rowsize!(left, 3, Auto(1.8))
    rowsize!(left, 7, Auto(2.6))
    for row = 1:panel_count
        rowsize!(left, 8 + row, Auto(1.2))
        state_axes[row].yticks = Makie.LinearTicks(4)
    end

    # The sliders read in the units a person thinks in: a date to start from, and a width in hours.
    # Their *values* stay an integer day index and an integer hour count; only the labels change.
    per_day = intervals_per_day(grid)
    interval = hours(grid)
    start_date = Date(grid.start)
    widths = sort(unique(vcat([3, 6, 12], collect(24:24:(24*min(28, days))))))
    sliders = SliderGrid(
        left[9+panel_count, 1],
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

    # ---- collapsible rows -------------------------------------------------------------------
    # A section is a block of rows in `left` plus the blocks that draw into them. Collapsing zeroes
    # the rows *and* hides the drawing: `rowsize!(Fixed(0))` alone leaves the plot rendering into a
    # zero-height strip, which reads as a stray line rather than as an absence.
    row_gap = 12.0
    rowgap!(left, row_gap)
    left_rows = 10 + panel_count

    price_rows, energy_rows = 1:4, 5:8
    section_rows = vcat([price_rows, energy_rows], [(8+r):(8+r) for r = 1:panel_count])
    section_axis = vcat([3, 7], [8 + r for r = 1:panel_count])
    section_weight = vcat([1.8, 2.6], fill(1.2, panel_count))
    section_names = vcat(["prices", "energy"], [p.label for p in initial_panels])
    # The legends are rebuilt on a theme change, so they are looked up rather than captured.
    section_blocks = vcat(
        [
            () -> Any[headings[1], units[1], price_axis, get(legends, 1, nothing)],
            () -> Any[headings[2], units[2], energy_axis, get(legends, 2, nothing)],
        ],
        [(r -> () -> Any[state_axes[r]])(r) for r = 1:panel_count],
    )

    _hide!(::Nothing, _) = nothing
    function _hide!(block, visible::Bool)
        block.blockscene.visible[] = visible
        block isa Axis && (block.scene.visible[] = visible)
        return nothing
    end

    row_toggles = [Toggle(figure; active = true) for _ in section_names]
    row_labels = [Label(figure, name; halign = :left) for name in section_names]

    function _apply_collapse!()
        hidden = Set{Int}()
        for (index, rows) in enumerate(section_rows)
            visible = row_toggles[index].active[]
            for row in rows
                rowsize!(left, row, if !visible
                    Fixed(0)
                elseif row == section_axis[index]
                    Auto(section_weight[index])
                else
                    Auto()
                end)
                visible || push!(hidden, row)
            end
            foreach(b -> _hide!(b, visible), section_blocks[index]())
        end
        # A gap next to a collapsed row would still take space, so it is recomputed from scratch
        # rather than toggled per section — two neighbours must not fight over the gap they share.
        for gap = 1:(left_rows-1)
            rowgap!(left, gap, (gap in hidden || gap + 1 in hidden) ? 0.0 : row_gap)
        end
        return nothing
    end

    scenario_menu = Menu(
        right[1, 1];
        options = string.(scenario_names),
        default = string(first(scenario_names)),
    )
    battery_menu =
        Menu(right[2, 1]; options = battery_labels, default = first(battery_labels))
    menu_labels = [
        Label(
            right[1, 1, Top()],
            "scenario";
            halign = :left,
            tellwidth = false,
            padding = (0, 0, 4, 0),
        ),
        Label(
            right[2, 1, Top()],
            "battery";
            halign = :left,
            tellwidth = false,
            padding = (0, 0, 4, 0),
        ),
    ]

    # Only worth a menu when there is a choice to make, so the row below it moves.
    strategy_menu = if length(plan_names) > 1
        push!(
            menu_labels,
            Label(right[3, 1, Top()], "strategy"; halign = :left, padding = (0, 0, 4, 0)),
        )
        Menu(
            right[3, 1];
            options = string.(plan_names),
            default = string(first(plan_names)),
        )
    else
        nothing
    end
    theme_row = strategy_menu === nothing ? 3 : 4
    push!(
        menu_labels,
        Label(right[theme_row, 1, Top()], "theme"; halign = :left, padding = (0, 0, 4, 0)),
    )
    theme_menu =
        Menu(right[theme_row, 1]; options = ["dark", "light"], default = string(theme))
    next_row = theme_row + 1

    series = flow_series(initial)
    labels = vcat(first.(series.sources), first.(series.sinks))
    toggles = [Toggle(figure; active = true) for _ in labels]
    toggle_labels = [Label(figure, l; halign = :left) for l in labels]
    # `tellheight = true` so each toggle block hugs its own heading; with `false` the two groups
    # share the leftover height and the "rows" label drifts away from the toggles it names.
    right[next_row, 1] = grid!(hcat(toggle_labels, [t for t in toggles]); tellheight = true)
    rows_heading = Label(
        right[next_row+1, 1, Top()],
        "rows";
        halign = :left,
        tellwidth = false,
        padding = (0, 0, 4, 10),
    )
    right[next_row+1, 1] =
        grid!(hcat(row_labels, [t for t in row_toggles]); tellheight = true)

    window_label =
        Label(left[10+panel_count, 1], ""; halign = :left, fontsize = 11, tellwidth = false)
    row_labels = [
        Label(cards[1, 0], "window"; halign = :right, fontsize = 11),
        Label(money[1, 0], "annual"; halign = :right, fontsize = 11),
    ]

    # VRM's cards. The first row is the visible window; the second is the business case, which does
    # not depend on the window at all — so the two rows are labelled to say which is which.
    function _card_row(parent, titles)
        boxes, heads, values = Box[], Label[], Label[]
        for (column, title) in enumerate(titles)
            inner = parent[1, column] = GridLayout()
            push!(
                boxes,
                Box(
                    inner[1:2, 1];
                    color = _c(palette[].panel),
                    strokevisible = false,
                    cornerradius = 6,
                ),
            )
            push!(
                heads,
                Label(
                    inner[1, 1],
                    title;
                    halign = :left,
                    fontsize = 11,
                    tellwidth = false,
                    padding = (14, 14, 10, 0),
                ),
            )
            push!(
                values,
                Label(
                    inner[2, 1],
                    "—";
                    halign = :left,
                    fontsize = 22,
                    tellwidth = false,
                    padding = (14, 14, 0, 12),
                ),
            )
        end
        return boxes, heads, values
    end

    card_boxes, card_heads, card_values =
        _card_row(cards, ("From grid", "To grid", "PV used", "Window cost"))
    money_boxes, money_heads, money_values = _card_row(
        money,
        ("Annual bill", "Annual saving", "NPV", "Payback", "Cycles / year"),
    )

    # Rebuilt rather than restyled on a theme change: a legend entry carries its swatch colour, and
    # the swatch is exactly what the theme changes.
    legends = Legend[]
    function _rebuild_legends!()
        foreach(delete!, legends)
        empty!(legends)
        colours = palette[].colours
        swatches(hexes) = [PolyElement(; color = first(_colour(h))) for h in hexes]
        bar(row, hexes, names) = push!(
            legends,
            Legend(
                left[row, 1],
                swatches(hexes),
                names;
                orientation = :horizontal,
                nbanks = 1,
                framevisible = false,
                labelcolor = _c(palette[].foreground),
                labelsize = 11,
                colgap = 14,
                patchsize = (11, 11),
                tellwidth = false,
                halign = :left,
                padding = (0, 0, 2, 2),
            ),
        )
        bar(4, [colours.var"import", colours.export_], ["buy price", "sell price"])
        # Re-derived from the themed table rather than reused from the initial `series`, whose
        # colours are whatever palette was in force when the dashboard was built.
        themed = flow_series(initial; colours)
        entries = vcat(themed.sources, themed.sinks)
        bar(8, [last(v) for (_, v) in entries], [k for (k, _) in entries])
        return nothing
    end

    # One place that knows how a theme reaches every piece of chrome. The plots themselves are
    # recoloured by `refresh`, which reads `palette[]` when it redraws.
    function _apply_theme!()
        active = palette[]
        figure.scene.backgroundcolor[] = _c(active.background)
        for axis in vcat(price_axis, energy_axis, state_axes)
            axis.backgroundcolor = _c(active.background)
            axis.xgridcolor = _c(active.grid)
            axis.ygridcolor = _c(active.grid)
            axis.xminorgridcolor = _c(active.minorgrid)
            axis.yminorgridcolor = _c(active.minorgrid)
            # VRM draws no box: an axis line along the bottom and the left, and nothing else.
            axis.topspinevisible = false
            axis.rightspinevisible = false
            axis.leftspinecolor = _c(active.grid)
            axis.bottomspinecolor = _c(active.grid)
            axis.xtickcolor = _c(active.muted)
            axis.ytickcolor = _c(active.muted)
            axis.xminortickcolor = _c(active.muted)
            axis.yminortickcolor = _c(active.muted)
            axis.xticklabelcolor = _c(active.muted)
            axis.yticklabelcolor = _c(active.muted)
            axis.xlabelcolor = _c(active.muted)
            axis.ylabelcolor = _c(active.muted)
            axis.titlecolor = _c(active.foreground)
        end
        for label in vcat(
            headings,
            menu_labels,
            toggle_labels,
            row_labels,
            rows_heading,
            card_heads,
            money_heads,
        )
            label.color = _c(active.foreground)
        end
        for label in vcat(units, window_label, row_labels)
            label.color = _c(active.muted)
        end
        foreach(box -> box.color = _c(active.panel), vcat(card_boxes, money_boxes))
        foreach(
            label -> label.color = _c(active.foreground),
            vcat(card_values, money_values),
        )
        # Makie's controls default to a light chrome that looks pasted on over a dark panel.
        for menu in
            filter(!isnothing, (scenario_menu, battery_menu, strategy_menu, theme_menu))
            menu.textcolor = _c(active.foreground)
            menu.dropdown_arrow_color = _c(active.muted)
            menu.cell_color_inactive_even = _c(active.panel)
            menu.cell_color_inactive_odd = _c(active.panel)
            menu.cell_color_hover = _c(active.grid)
            menu.cell_color_active = _c(active.grid)
            menu.selection_cell_color_inactive = _c(active.panel)
        end
        for toggle in vcat(toggles, row_toggles)
            toggle.framecolor_inactive = _c(active.grid)
            toggle.framecolor_active = first(_colour(active.colours.battery))
        end
        for slider in sliders.sliders
            slider.color_inactive = _c(active.grid)
            slider.color_active_dimmed = _c(active.panel)
        end
        for slider in sliders.labels
            slider.color = _c(active.muted)
        end
        for value in sliders.valuelabels
            value.color = _c(active.muted)
        end
        _rebuild_legends!()
        return nothing
    end

    # The business case for one selection. It depends on the choice and never on the window, so it is
    # memoised: dragging a slider must not resettle a year of flows.
    finance = Dict{Tuple{Symbol,Int,Symbol},NamedTuple}()
    function _finance(scenario::Symbol, candidate::Int, plan::Symbol)
        return get!(finance, (scenario, candidate, plan)) do
            contract = regimes[scenario]
            case = simulation(scenario, candidate, plan)
            case_bill = settle(case, contract)
            base_bill = settle(simulation(scenario, 0, plan), contract)
            spent = annualise(case_bill)
            saved = annualise(base_bill) - spent
            cycles = cycles_per_year(case)
            investment === nothing &&
                return (; spent, saved, cycles, npv = nothing, payback = nothing)
            k = kpis(base_bill, case_bill, investment(candidates[candidate]); result = case)
            return (; spent, saved, cycles, npv = k.npv, payback = k.payback_years)
        end
    end

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
        active = palette[]

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

        empty!(price_axis)
        HEMSSimulator.price_plot!(
            price_axis,
            result;
            days = Intervals(rows),
            max_points,
            colours = active.colours,
        )

        empty!(energy_axis)
        HEMSSimulator.dispatch_plot!(
            energy_axis,
            result;
            days = Intervals(rows),
            max_points,
            include = keep,
            colours = active.colours,
            zero_colour = _c(active.muted),
        )
        headings[2].text[] =
            length(plan_names) > 1 ?
            "Energy — $(scenario), $(battery_labels[candidate]), $(plan)" :
            "Energy — $(scenario), $(battery_labels[candidate])"

        panels = StatePanel[]
        for (index, asset) in enumerate(result.system.assets)
            append!(panels, state_panels(asset, result, index; colours = active.colours))
        end
        for (axis, panel) in zip(state_axes, panels)
            empty!(axis)
            HEMSSimulator.state_plot!(axis, panel, rows, blocks, x)
        end
        # The axes are x-linked, so only the bottom one needs a labelled x-axis; the plot functions
        # set one every redraw, which is right for a standalone figure and noise here.
        stacked = vcat(price_axis, energy_axis, state_axes)
        for axis in stacked
            autolimits!(axis)
            _time_axis!(axis, result, rows)
            axis.xticklabelsvisible = false
            axis.xlabelvisible = false
            axis.ylabelvisible = false
        end
        # The *lowest visible* axis carries the dates. Using the lowest axis outright would hide the
        # time axis entirely the moment someone collapsed the bottom panel.
        shown = [a for (a, t) in zip(stacked, row_toggles) if t.active[]]
        bottom = isempty(shown) ? last(stacked) : last(shown)
        bottom.xticklabelsvisible = true
        bottom.xlabelvisible = true

        window = _window_totals(result, rows)
        card_values[1].text[] = "$(round(window.imported; digits = 1)) kWh"
        card_values[2].text[] = "$(round(window.exported; digits = 1)) kWh"
        card_values[3].text[] = "$(round(window.pv; digits = 1)) kWh"
        card_values[4].text[] = "€$(round(window.cost; digits = 2))"
        window_label.text[] = "$(timestamp(result.grid, first(rows)))  →  $(timestamp(result.grid, last(rows)))"

        money_row = _finance(scenario, candidate, plan)
        money_values[1].text[] = "€$(round(Int, money_row.spent))"
        money_values[2].text[] = "€$(round(Int, money_row.saved))"
        money_values[3].text[] =
            money_row.npv === nothing ? "—" : "€$(round(Int, money_row.npv))"
        money_values[4].text[] = if money_row.payback === nothing
            "—"
        elseif isfinite(money_row.payback)
            "$(round(money_row.payback; digits = 1)) yr"
        else
            "never"
        end
        money_values[5].text[] = string(round(Int, money_row.cycles))
        return nothing
    end

    on(theme_menu.selection) do choice
        choice === nothing && return nothing
        palette[] = plot_theme(Symbol(choice))
        _apply_theme!()
        refresh()
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
    for toggle in row_toggles
        on(toggle.active) do _
            _apply_collapse!()
            refresh()          # the date labels move to whichever axis is now lowest
        end
    end
    _apply_theme!()
    _apply_collapse!()
    refresh()

    return (;
        figure,
        refresh,
        sliders,
        scenario_menu,
        battery_menu,
        strategy_menu,
        theme_menu,
        toggles,
        row_toggles,
        palette,
    )
end

# ---------------------------------------------------------------------------------------------
# Theme

function HEMSSimulator.hems_theme(name::Symbol = :light)
    active = plot_theme(name)
    return Theme(;
        fontsize = 12,
        backgroundcolor = active.background,
        textcolor = active.foreground,
        palette = (color = [first(_colour(hex)) for hex in SERIES_COLOURS],),
        Axis = (;
            backgroundcolor = active.background,
            rightspinevisible = false,
            topspinevisible = false,
            leftspinecolor = active.grid,
            bottomspinecolor = active.grid,
            xgridcolor = active.grid,
            ygridcolor = active.grid,
            xticklabelcolor = active.muted,
            yticklabelcolor = active.muted,
            xlabelcolor = active.muted,
            ylabelcolor = active.muted,
            titlecolor = active.foreground,
            xminorticksvisible = true,
            yminorticksvisible = true,
            xminorgridvisible = true,
            yminorgridvisible = true,
            xminorgridcolor = active.minorgrid,
            yminorgridcolor = active.minorgrid,
            xminorticks = IntervalsBetween(4),
            yminorticks = IntervalsBetween(2),
        ),
        Legend = (; framevisible = false, labelcolor = active.foreground),
    )
end

end # module
