# Figures for experiment 001, drawn from the CSVs `run.jl` wrote.
#
#     julia --project=examples experiments/001-tibber-2025-strategies/figures.jl
#
# Reads `data/`, writes `figures/`. Runs in a minute, so a figure can be reworked as often as it
# needs without re-solving a year — the whole reason simulation and plotting are separate steps.
# It needs no ENTSO-E token: everything it reads is already on disk.

using CSV
using DataFrames
using GLMakie
using HEMSSimulator: ASSET_COLOURS, series_colour, time_ticks

# Never open a window: this script only writes files, and a stray window kills it on a headless or
# remote session.
GLMakie.activate!(; visible = false)

include(joinpath(@__DIR__, "..", "common.jl"))
# The config too, for the one thing a CSV cannot carry: what the NPV column was discounted at. A
# figure captioned "Net present value" is misleading out of context when the rate is zero.
include(joinpath(@__DIR__, "run-config.jl"))
const DATA = data_dir(@__FILE__)
const FIGS = figures_dir(@__FILE__)

table(name) = read_table(DATA, name)
colour(series) = get(
    Dict(
        "PV" => ASSET_COLOURS.pv,
        "import" => ASSET_COLOURS.var"import",
        "export" => ASSET_COLOURS.export_,
        "curtailed" => ASSET_COLOURS.curtail,
        "base load" => ASSET_COLOURS.load,
        "battery charge" => ASSET_COLOURS.battery,
        "battery discharge" => ASSET_COLOURS.battery,
        "ev charge" => ASSET_COLOURS.ev,
        "ev discharge" => ASSET_COLOURS.ev,
        "heatpump" => ASSET_COLOURS.heatpump,
        "dhw" => ASSET_COLOURS.dhw,
    ),
    series,
    ASSET_COLOURS.neutral,
)

# The same axis furniture the package's own plots use, applied here by hand because these figures are
# rebuilt from CSVs rather than from a `SimulationResult`.
function minor_ticks!(axis; x = true)
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

# The long tables carry both the timestamp and the hour-from-window-start each row was drawn at, so
# the date labels come straight out of the data rather than out of the config.
function time_axis!(axis, block)
    marks = sort(unique(block.hour))
    step = length(marks) > 1 ? marks[2] - marks[1] : 1.0
    axis.xticks = time_ticks(minimum(block.timestamp), maximum(marks) + step)
    return minor_ticks!(axis)
end

# ---------------------------------------------------------------------------------------------
# KPI curves against battery capacity, one line per strategy.

comparison = table("comparison")

function kpi_figure(column, ylabel, title)
    figure = Figure(size = (760, 420))
    axis = Axis(figure[1, 1]; title, xlabel = "battery capacity, kWh", ylabel)
    for (index, name) in enumerate(unique(comparison.strategy))
        block = comparison[comparison.strategy .== name, :]
        shade = series_colour(index)
        lines!(
            axis,
            block.capacity_kwh,
            block[!, column];
            label = string(name),
            linewidth = 2,
            color = shade,
        )
        scatter!(axis, block.capacity_kwh, block[!, column]; markersize = 9, color = shade)
    end
    column === :npv && hlines!(axis, [0.0]; color = (:black, 0.3), linewidth = 0.8)
    minor_ticks!(axis)
    axislegend(axis; framevisible = false)
    return figure
end

for (column, ylabel, title) in (
    (:annual_savings, "EUR/year", "Annual savings"),
    (:savings_per_kwh, "EUR/year per kWh installed", "Savings per kWh of battery"),
    (:imported_kwh, "kWh/year", "Energy taken from the grid"),
    (
        :npv,
        "EUR",
        "Net present value over $(LIFETIME_YEARS) years, $(round(Int, 100DISCOUNT_RATE))% real discount",
    ),
    (:cycles_per_year, "full equivalent cycles/year", "Battery cycling"),
    (:self_sufficiency, "fraction", "Self-sufficiency"),
)
    save_figure(FIGS, string(column), kpi_figure(column, ylabel, title))
end

# The trade the two strategies make, on one pair of axes: money given up against grid energy saved.
let figure = Figure(size = (620, 460))
    axis = Axis(
        figure[1, 1];
        title = "What the green strategy costs and buys",
        xlabel = "annual savings, EUR",
        ylabel = "energy taken from the grid, kWh/year",
    )
    for (index, name) in enumerate(unique(comparison.strategy))
        block = comparison[comparison.strategy .== name, :]
        shade = series_colour(index)
        lines!(
            axis,
            block.annual_savings,
            block.imported_kwh;
            label = string(name),
            linewidth = 2,
            color = shade,
        )
        scatter!(
            axis,
            block.annual_savings,
            block.imported_kwh;
            markersize = 9,
            color = shade,
        )
        for row in eachrow(block)
            text!(
                axis,
                row.annual_savings,
                row.imported_kwh;
                text = string(row.capacity_kwh, " kWh"),
                fontsize = 9,
                offset = (6, 4),
                color = (:black, 0.6),
            )
        end
    end
    minor_ticks!(axis)
    axislegend(axis; framevisible = false)
    save_figure(FIGS, "trade-off", figure)
end

# ---------------------------------------------------------------------------------------------
# Dispatch and state windows, rebuilt from the long tables.

function dispatch_figure(flows, title)
    figure = Figure(size = (1000, 420))
    axis = Axis(figure[1, 1]; title, ylabel = "kW  (sources up, sinks down)")
    time_axis!(axis, flows)
    handles, labels = Any[], String[]
    for (direction, sign) in ((:source, 1), (:sink, -1))
        running = nothing
        for name in unique(flows[flows.direction .== string(direction), :series])
            block =
                flows[(flows.direction .== string(direction)) .& (flows.series .== name), :]
            running = running === nothing ? zeros(nrow(block)) : running
            lower = copy(running)
            running = running .+ block.kw
            push!(
                handles,
                band!(
                    axis,
                    block.hour,
                    sign .* lower,
                    sign .* running;
                    color = (colour(name), 0.85),
                ),
            )
            push!(labels, name)
        end
    end
    hlines!(axis, [0.0]; color = :black, linewidth = 0.8)
    Legend(figure[1, 2], handles, labels; framevisible = false)
    return figure
end

function state_figure(states, title)
    panels = unique(states.panel)
    figure = Figure(size = (1000, 220 * length(panels)))
    axes = Axis[]
    for (row, name) in enumerate(panels)
        block = states[states.panel .== name, :]
        axis = Axis(figure[row, 1]; ylabel = name)
        if !all(ismissing, block.band_lower)
            band!(
                axis,
                block.hour,
                collect(Float64, block.band_lower),
                collect(Float64, block.band_upper);
                color = (:grey, 0.18),
            )
        end
        for bound in (first(block.lower), first(block.upper))
            ismissing(bound) && continue
            hlines!(axis, [bound]; color = (:black, 0.35), linestyle = :dash, linewidth = 1)
        end
        any(block.away) && band!(
            axis,
            block.hour,
            zeros(nrow(block)),
            [a ? maximum(block.value) : 0.0 for a in block.away];
            color = (:grey, 0.10),
        )
        lines!(axis, block.hour, block.value; linewidth = 1.6)
        marks = block[.!ismissing.(block.target), :]
        nrow(marks) == 0 || scatter!(
            axis,
            marks.hour,
            collect(Float64, marks.target);
            color = :black,
            marker = :hline,
            markersize = 14,
        )
        time_axis!(axis, block)
        row == length(panels) || (axis.xticklabelsvisible = false)
        push!(axes, axis)
    end
    linkxaxes!(axes...)
    axes[1].title = title
    return figure
end

for file in readdir(DATA)
    startswith(file, "flows-") && endswith(file, ".csv") || continue
    stem = replace(file, "flows-" => "", ".csv" => "")
    save_figure(FIGS, "dispatch-$stem", dispatch_figure(table("flows-$stem"), stem))
    save_figure(FIGS, "state-$stem", state_figure(table("states-$stem"), stem))
end

println("figures done")
