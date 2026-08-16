# Figures for experiment 002, drawn from the CSVs `run.jl` wrote.
#
#     julia --project=examples experiments/002-factorial-sizing/figures.jl
#
# Reads `data/`, writes `figures/`. Runs in a minute against hours of solver time, which is the whole
# reason simulation and plotting are separate steps. Needs no ENTSO-E token.

using CSV
using DataFrames
using GLMakie
using HEMSSimulator: ASSET_COLOURS, series_colour

# Never open a window: this script only writes files, and a stray window kills it on a headless or
# remote session.
GLMakie.activate!(; visible = false)

include(joinpath(@__DIR__, "..", "common.jl"))
# The config too, for the two things a results CSV cannot carry: what the NPV column was discounted
# at, and which wave each scenario came from.
include(joinpath(@__DIR__, "run-config.jl"))
const DATA = data_dir(@__FILE__)
const FIGS = figures_dir(@__FILE__)

results = read_table(DATA, "results")

# The `demand_from_*` columns were added to `kpis.jl` after the first wave had already been written,
# so a table from before that is missing them. Rebuild them from the per-sink shares, which is
# exactly how they are defined: final demand is the base load plus the car, each supplied by its own
# mix. A figure should not fail because of when its input happened to be produced.
if !hasproperty(results, :demand_from_grid_share)
    demand = results.base_load_kwh .+ results.ev_charge_kwh
    for source in ("solar", "grid", "battery")
        results[!, Symbol("demand_from_", source, "_share")] =
            (
                results.base_load_kwh .*
                results[!, Symbol("load_from_", source, "_share")] .+
                results.ev_charge_kwh .* results[!, Symbol("ev_from_", source, "_share")]
            ) ./ demand
    end
    results[!, :demand_kwh] = demand
end
# Draw scenarios in the order they were designed in, not alphabetically: wave 1 is the one-at-a-time
# ladder and reads as one, and `base` belongs first because everything else is measured against it.
const ORDER = [s.name for s in SCENARIOS if s.name in results.scenario]
const SIZES = sort(unique(results.pv_kwp))
const WAVE_OF = Dict(s.name => wave_of(s.name) for s in SCENARIOS)

block(source, scenario) =
    sort(source[source.scenario .== scenario, :], [:pv_kwp, :battery_kwh])
sized(frame) = frame[frame.battery_kwh .> 0, :]

# `investment.jl` re-prices every simulated case across the cell-price and discount ladders and
# writes the result. Reading it back rather than recomputing NPV here keeps the three steps separate
# — simulate, analyse, draw — so a chart can never disagree with the table it is a picture of.
# Absent when only `run.jl` has been run; the price figures are then simply skipped.
const SWEEP_PATH = joinpath(DATA, "investment-sweep.csv")
const SWEEP = isfile(SWEEP_PATH) ? read_table(DATA, "investment-sweep") : nothing
priced_at(per_kwh, rate = DISCOUNT_RATE) =
    SWEEP[(SWEEP.capex_per_kwh .== per_kwh) .& (SWEEP.discount_rate .== rate), :]

function minor_ticks!(axis)
    major, minor = RGBAf(0, 0, 0, 0.10), RGBAf(0, 0, 0, 0.04)
    axis.xminorticksvisible = true
    axis.xminorgridvisible = true
    axis.xminorticks = IntervalsBetween(2)
    axis.xgridcolor = major
    axis.xminorgridcolor = minor
    axis.yminorticksvisible = true
    axis.yminorgridvisible = true
    axis.yminorticks = IntervalsBetween(2)
    axis.ygridcolor = major
    axis.yminorgridcolor = minor
    return axis
end

# 14 scenarios is too many for one set of axes and too few to need a scrollable page, so every
# scenario-level figure is a grid of small multiples with one shared legend. Four columns keeps each
# panel wide enough to read a curve's shape, which is the only thing these curves are for — the
# rankings between adjacent battery sizes are inside the solver noise.
const COLUMNS = 4
cell(index) = (fldmod1(index, COLUMNS))

# The colour of the "this one wins" marker. Deliberately outside `SERIES_COLOURS` — it has to read as
# annotation rather than as a sixth array size, and the palette's warmest entry is a vermillion that
# a red cross drawn on top of it would disappear into. Stroked in white for the same reason.
# What the money figures were priced at. Every NPV in this study is one point in `investment.jl`'s
# price sweep, so a chart of it that does not say which point is a chart of an unnamed number. Both
# halves of the capex are named because "400 EUR/kWh" alone would understate a small pack: a 2.5 kWh
# battery costs 400 + 400 x 2.5, which is 560 EUR/kWh installed, not 400.
const PRICING =
    "battery at $(Int(RESULTS_PER_KWH)) EUR/kWh plus $(Int(FIXED_CAPEX)) EUR fixed, " *
    "$(round(Int, 100DISCOUNT_RATE))% discount"

const OPTIMUM_MARKER = (
    color = RGBf(0.85, 0.0, 0.10),
    marker = :xcross,
    markersize = 15,
    strokewidth = 1.2,
    strokecolor = :white,
)

# One panel's worth of curves: capacity on x, `column` on y, one line per array size.
function draw_curves!(axis, frame, column; mark_max = false, zero_line = false)
    for (level, kwp) in enumerate(SIZES)
        line = frame[frame.pv_kwp .== kwp, :]
        isempty(line) && continue
        shade = series_colour(level)
        values = line[!, column]
        lines!(axis, line.battery_kwh, values; linewidth = 2, color = shade)
        scatter!(axis, line.battery_kwh, values; markersize = 6, color = shade)
        # The best candidate on this curve. Drawn after the line so it is never occluded, and drawn
        # per curve rather than per panel because the question is which battery to buy *given* an
        # array — not which array to buy.
        if mark_max && any(isfinite, values)
            peak = argmax(replace(values, NaN => -Inf))
            scatter!(axis, [line.battery_kwh[peak]], [values[peak]]; OPTIMUM_MARKER...)
        end
    end
    zero_line && hlines!(axis, [0.0]; color = (:black, 0.35), linewidth = 0.8)
    return minor_ticks!(axis)
end

function curve_legend(figure, row; mark_max = false)
    handles = Any[
        LineElement(color = series_colour(level), linewidth = 3) for
        level in eachindex(SIZES)
    ]
    labels = [string(Int(kwp), " kWp") for kwp in SIZES]
    if mark_max
        push!(handles, MarkerElement(; OPTIMUM_MARKER...))
        push!(labels, "best size")
    end
    return Legend(
        figure[row, 1:COLUMNS],
        handles,
        labels;
        orientation = :horizontal,
        framevisible = false,
    )
end

# One panel per scenario, at a single price.
function facet(column, ylabel, title; source = results, zero_line = false, mark_max = false)
    rows = cld(length(ORDER), COLUMNS)
    figure = Figure(size = (330 * COLUMNS, 250 * rows + 90))
    Label(figure[0, 1:COLUMNS], title; fontsize = 17, font = :bold)
    axes = Axis[]
    for (index, name) in enumerate(ORDER)
        row, col = cell(index)
        axis = Axis(
            figure[row, col];
            # Wave 1 is the reference ladder and needs no label; anything later is worth marking,
            # because a reader comparing panels should know which were chosen after seeing results.
            title = name * (WAVE_OF[name] > 1 ? "  (wave $(WAVE_OF[name]))" : ""),
            titlesize = 12,
            # The last row is short — 14 scenarios in a 4-wide grid — so "is this the bottom row"
            # is the wrong question. Label whatever has nothing under it, in every column.
            xlabel = index + COLUMNS > length(ORDER) ? "battery, kWh" : "",
            ylabel = col == 1 ? ylabel : "",
        )
        draw_curves!(axis, sized(block(source, name)), column; mark_max, zero_line)
        push!(axes, axis)
    end
    # One shared scale, or the panels cannot be compared — which is the only reason to face them.
    linkaxes!(axes...)
    curve_legend(figure, rows + 1; mark_max)
    return figure
end

# One panel per cell price, at a single scenario. The other way round from `facet`, and the figure
# that actually answers "how does the answer move with the price of a battery".
#
# **Axes are deliberately not linked here.** At 100 EUR/kWh the NPVs are several times those at 400,
# so a shared scale would flatten the dear panels into featureless lines — and the shape of each
# curve, especially where its peak sits, is the whole point. The zero line is drawn in every panel
# so the one comparison that does need a common reference still has one.
function price_facet(scenario_name; rate = DISCOUNT_RATE)
    prices = sort(unique(SWEEP.capex_per_kwh); rev = true)
    rows = cld(length(prices), COLUMNS)
    figure = Figure(size = (330 * COLUMNS, 250 * rows + 110))
    Label(
        figure[0, 1:COLUMNS],
        "Net present value against battery price — `$scenario_name`, " *
        "plus $(Int(FIXED_CAPEX)) EUR fixed, $(round(Int, 100rate))% discount";
        fontsize = 17,
        font = :bold,
    )
    for (index, per_kwh) in enumerate(prices)
        row, col = cell(index)
        axis = Axis(
            figure[row, col];
            title = "$(Int(per_kwh)) EUR/kWh",
            titlesize = 13,
            xlabel = index + COLUMNS > length(prices) ? "battery, kWh" : "",
            ylabel = col == 1 ? "EUR" : "",
        )
        draw_curves!(
            axis,
            sized(block(priced_at(per_kwh, rate), scenario_name)),
            :npv;
            mark_max = true,
            zero_line = true,
        )
    end
    curve_legend(figure, rows + 1; mark_max = true)
    return figure
end

save_figure(
    FIGS,
    "npv",
    facet(
        :npv,
        "EUR",
        "Net present value over $(LIFETIME_YEARS) years — $(PRICING)";
        zero_line = true,
        mark_max = true,
    ),
)
save_figure(FIGS, "annual-savings", facet(:annual_savings, "EUR/year", "Annual savings"))
save_figure(
    FIGS,
    "imported",
    facet(:imported_kwh, "kWh/year", "Energy taken from the grid"),
)
save_figure(
    FIGS,
    "cycles",
    facet(:cycles_per_year, "cycles/year", "Battery cycling, full equivalent cycles"),
)
save_figure(
    FIGS,
    "demand-from-grid",
    facet(
        :demand_from_grid_share,
        "fraction",
        "Share of final demand bought from the grid (base load + car)",
    ),
)

# ---------------------------------------------------------------------------------------------
# The same NPV, at every cell price. Needs `investment.jl` to have run.

if SWEEP === nothing
    @warn "no investment-sweep.csv; run investment.jl for the price figures" SWEEP_PATH
else
    # One figure per scenario would be twenty; `base` is the reference every other scenario is
    # measured against, so it is the one that carries the price comparison.
    save_figure(FIGS, "npv-by-price", price_facet("base"))

    # And the scenario grid at four prices spanning the ladder, so the *ranking between scenarios*
    # can be checked for stability as batteries get cheaper — a factor that matters at 400 EUR/kWh
    # and stops mattering at 100 would be worth knowing about, and is invisible in a single figure.
    for per_kwh in (400.0, 300.0, 200.0, 100.0)
        per_kwh in SWEEP.capex_per_kwh || continue
        save_figure(
            FIGS,
            "npv-at-$(Int(per_kwh))",
            facet(
                :npv,
                "EUR",
                "Net present value — battery at $(Int(per_kwh)) EUR/kWh plus " *
                "$(Int(FIXED_CAPEX)) EUR fixed, $(round(Int, 100DISCOUNT_RATE))% discount";
                source = priced_at(per_kwh),
                zero_line = true,
                mark_max = true,
            ),
        )
    end
end

# ---------------------------------------------------------------------------------------------
# The sizing answer itself, as one picture: which battery wins, everywhere.

let
    optimum = fill(NaN, length(ORDER), length(SIZES))
    gain = fill(NaN, length(ORDER), length(SIZES))
    for (row, name) in enumerate(ORDER), (col, kwp) in enumerate(SIZES)
        frame = sized(block(results, name))
        candidates = frame[frame.pv_kwp .== kwp, :]
        isempty(candidates) && continue
        best = candidates[argmax(candidates.npv), :]
        optimum[row, col] = best.battery_kwh
        gain[row, col] = best.npv
    end

    figure = Figure(size = (620, 34 * length(ORDER) + 190))
    axis = Axis(
        figure[1, 1];
        title = "NPV-optimal battery, kWh (label) over its NPV, EUR (colour)\n$(PRICING)",
        titlesize = 13,
        xlabel = "array, kWp",
        ylabel = "",
        xticks = (eachindex(SIZES), [string(Int(kwp)) for kwp in SIZES]),
        yticks = (eachindex(ORDER), ORDER),
        yreversed = true,
    )
    plot = heatmap!(
        axis,
        eachindex(SIZES),
        eachindex(ORDER),
        permutedims(gain);
        colormap = :viridis,
    )
    for (row, _) in enumerate(ORDER), (col, _) in enumerate(SIZES)
        isnan(optimum[row, col]) && continue
        text!(
            axis,
            col,
            row;
            text = string(optimum[row, col]),
            align = (:center, :center),
            fontsize = 11,
            color = :white,
            strokewidth = 1.5,
            strokecolor = (:black, 0.55),
        )
    end
    Colorbar(figure[1, 2], plot; label = "NPV of the best battery, EUR")
    save_figure(FIGS, "optimum", figure)
end

# ---------------------------------------------------------------------------------------------
# Where the energy went, at one reference home per scenario.
#
# A stacked bar per scenario needs a single configuration to stack, so these fix the array and the
# battery at the middle of each grid. The facet figures above are where the *trends* live; these are
# for reading composition at a glance.

const REFERENCE_KWP = 6.0
const REFERENCE_KWH = 10.0

reference = let
    rows = results[
        (results.pv_kwp .== REFERENCE_KWP) .& (results.battery_kwh .== REFERENCE_KWH),
        :,
    ]
    rows[[findfirst(==(name), rows.scenario) for name in ORDER if name in rows.scenario], :]
end

function composition(columns, labels, colours, title, subtitle)
    # Wide enough that the bars still have room once the longest combined scenario name has taken
    # its share of the axis.
    figure = Figure(size = (1120, 30 * nrow(reference) + 210))
    Label(figure[0, 1], title; fontsize = 17, font = :bold, padding = (0, 0, 0, 6))
    axis = Axis(
        figure[1, 1];
        title = subtitle,
        titlesize = 11,
        xlabel = "fraction",
        yticks = (1:nrow(reference), reference.scenario),
        yreversed = true,
    )
    handles = Any[]
    running = zeros(nrow(reference))
    for (column, colour) in zip(columns, colours)
        # A share is NaN where its sink took nothing at all — a home with no array has no solar
        # mix. Stacking needs a number, and zero is the honest one for "none of this went here".
        values = [ismissing(v) || isnan(v) ? 0.0 : Float64(v) for v in reference[!, column]]
        push!(
            handles,
            barplot!(
                axis,
                1:nrow(reference),
                running .+ values;
                fillto = running,
                direction = :x,
                color = colour,
                width = 0.72,
            ),
        )
        running = running .+ values
    end
    xlims!(axis, 0, 1)
    Legend(figure[2, 1], handles, labels; orientation = :horizontal, framevisible = false)
    return figure
end

save_figure(
    FIGS,
    "solar-destination",
    composition(
        [
            :solar_to_load_share,
            :solar_to_battery_share,
            :solar_to_ev_share,
            :solar_to_export_share,
            :solar_curtailed_share,
        ],
        ["base load", "battery", "car", "export", "curtailed"],
        [
            ASSET_COLOURS.load,
            ASSET_COLOURS.battery,
            ASSET_COLOURS.ev,
            ASSET_COLOURS.export_,
            ASSET_COLOURS.curtail,
        ],
        "What became of the solar",
        "as fractions of what the array could have produced — $(Int(REFERENCE_KWP)) kWp, $(REFERENCE_KWH) kWh battery",
    ),
)

save_figure(
    FIGS,
    "ev-source",
    composition(
        [:ev_from_solar_share, :ev_from_battery_share, :ev_from_grid_share],
        ["solar", "battery", "grid"],
        [ASSET_COLOURS.pv, ASSET_COLOURS.battery, ASSET_COLOURS.var"import"],
        "Where the car's energy came from",
        "attributed per interval — $(Int(REFERENCE_KWP)) kWp, $(REFERENCE_KWH) kWh battery",
    ),
)

save_figure(
    FIGS,
    "demand-source",
    composition(
        [:demand_from_solar_share, :demand_from_battery_share, :demand_from_grid_share],
        ["solar", "battery", "grid"],
        [ASSET_COLOURS.pv, ASSET_COLOURS.battery, ASSET_COLOURS.var"import"],
        "Where the household's energy came from",
        "final demand: base load plus car — $(Int(REFERENCE_KWP)) kWp, $(REFERENCE_KWH) kWh battery",
    ),
)

println("\nfigures done")
