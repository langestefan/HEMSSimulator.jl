"""
    HEMSSimulatorMakieExt

Methods for the plotting functions declared in `src/plots.jl`, loaded when Makie is — `using
CairoMakie` being the usual way in.

Everything here is drawing. The window arithmetic, the colour table and the per-asset descriptions
of what a state panel contains all live in the package proper, so the logic most likely to be wrong
is ordinary Julia that loads without a plotting stack.
"""
module HEMSSimulatorMakieExt

using HEMSSimulator
using HEMSSimulator:
    ASSET_COLOURS,
    Bill,
    PLOT_MAX_POINTS,
    SimulationResult,
    StatePanel,
    bill_components,
    block_first,
    block_mean,
    flow_series,
    interval_range,
    plot_blocks,
    state_panels
using DataFrames: DataFrame, nrow
using Dates: DateTime
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
    blocks == 1 ? "" : "  (averaged over $(round(blocks * dt; digits = 2)) h blocks)"

# ---------------------------------------------------------------------------------------------
# Dispatch

function HEMSSimulator.dispatch_plot!(
    axis::Axis,
    result::SimulationResult;
    days = 1:3,
    max_points::Integer = PLOT_MAX_POINTS,
)
    rows, blocks, x = _window(result, days, max_points)
    series = flow_series(result)

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
                color = RGBAf(Makie.red(colour), Makie.green(colour), Makie.blue(colour), 0.85),
            )
            push!(handles, label => handle)
        end
        return handles
    end

    handles = vcat(stack!(series.sources, 1), stack!(series.sinks, -1))
    hlines!(axis, [0.0]; color = :black, linewidth = 0.8)

    dt = hours(result.grid)
    axis.xlabel = "hours from the start of the window" * _note(blocks, dt)
    axis.ylabel = "kW  (sources up, sinks down)"
    return handles
end

function HEMSSimulator.dispatch_plot(
    result::SimulationResult;
    days = 1:3,
    max_points::Integer = PLOT_MAX_POINTS,
    size = (1000, 420),
)
    figure = Figure(; size)
    axis = Axis(figure[1, 1]; title = "Dispatch")
    handles = HEMSSimulator.dispatch_plot!(axis, result; days, max_points)
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
        row == length(panels) ||
            (axis.xticklabelsvisible = false; axis.xlabelvisible = false)
        push!(axes, axis)
    end
    linkxaxes!(axes...)
    axes[end].xlabel = "hours from the start of the window" * _note(blocks, dt)
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
    for (label, block) in groups
        x = block.capacity_kwh
        y = block[!, by]
        line = lines!(axis, x, y; linewidth = 1.8)
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
    axis.xlabel = "battery capacity, kWh"
    axis.ylabel = string(by)
    return handles
end

function HEMSSimulator.sweep_plot(
    table::DataFrame;
    by::Symbol = :npv,
    size = (760, 420),
)
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
# Theme

function HEMSSimulator.hems_theme()
    return Theme(;
        fontsize = 12,
        palette = (
            color = [
                first(_colour(hex)) for hex in (
                    ASSET_COLOURS.battery,
                    ASSET_COLOURS.heatpump,
                    ASSET_COLOURS.ev,
                    ASSET_COLOURS.dhw,
                    ASSET_COLOURS.pv,
                    ASSET_COLOURS.export_,
                )
            ],
        ),
        Axis = (;
            rightspinevisible = false,
            topspinevisible = false,
            xgridcolor = RGBAf(0, 0, 0, 0.06),
            ygridcolor = RGBAf(0, 0, 0, 0.06),
        ),
        Legend = (; framevisible = false),
    )
end

end # module
