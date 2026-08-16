# What the study found, as tables. Reads `data/results.csv`, writes `data/sensitivity.csv`, prints
# the rest. No Makie, no solver — runs in seconds.
#
#     julia --project=. experiments/002-factorial-sizing/summary.jl
#
# `figures.jl` draws the same material. This exists because a sizing answer is a small table and
# reading it should not require a plotting stack.

using DataFrames
using Printf: @printf, @sprintf
using Statistics: mean, median

include(joinpath(@__DIR__, "..", "common.jl"))
include(joinpath(@__DIR__, "run-config.jl"))
const DATA = data_dir(@__FILE__)

results = read_table(DATA, "results")
const ORDER = [s.name for s in SCENARIOS if s.name in results.scenario]
const SIZES = sort(unique(results.pv_kwp))
const BASE = "base"

sized = results[results.battery_kwh .> 0, :]
cell(scenario, kwp) = sized[(sized.scenario .== scenario) .& (sized.pv_kwp .== kwp), :]

"""
The NPV-maximising battery for one (scenario, array) pair, and the runner-up gap.

The gap matters more than the winner. Adjacent candidates sit within the solver noise this model
carries — roughly EUR 0.4/year on the bill, which compounds into single-digit euros of NPV — so a
winner that beats the runner-up by less than that is a coin toss dressed as a result.
"""
function optimum(scenario, kwp)
    rows = cell(scenario, kwp)
    isempty(rows) && return nothing
    order = sortperm(rows.npv; rev = true)
    best = rows[order[1], :]
    gap = length(order) > 1 ? best.npv - rows[order[2], :npv] : NaN
    return (;
        capacity = best.battery_kwh,
        npv = best.npv,
        gap,
        runner_up = length(order) > 1 ? rows[order[2], :battery_kwh] : NaN,
        savings = best.annual_savings,
        cycles = best.cycles_per_year,
        lifetime = best.lifetime_years,
        payback = best.payback_years,
    )
end

# ---------------------------------------------------------------------------------------------

println("\n", "="^96)
println("NPV-optimal battery per scenario and array — capacity kWh (NPV EUR)")
println("="^96)
@printf("%-32s", "scenario")
for kwp in SIZES
    @printf("%14s", string(Int(kwp), " kWp"))
end
println()
for name in ORDER
    @printf("%-32s", name)
    for kwp in SIZES
        best = optimum(name, kwp)
        best === nothing && (@printf("%14s", "-"); continue)
        @printf("%14s", @sprintf("%.1f (%.0f)", best.capacity, best.npv))
    end
    println()
end

# ---------------------------------------------------------------------------------------------
# How much each factor is worth, which is the whole reason for running scenarios rather than one
# home. Measured at the best battery for each, against `base` with the same array — so this is the
# effect of the *context*, with the sizing decision re-optimised inside it rather than held fixed.

println("\n", "="^96)
println("Effect of each factor on the best case, against `$BASE` with the same array")
println("="^96)
@printf(
    "%-32s%10s%12s%12s%12s\n",
    "scenario",
    "d(kWh)",
    "d(NPV)",
    "d(savings)",
    "d(import)"
)
sensitivity = DataFrame()
for name in ORDER
    name == BASE && continue
    deltas = NamedTuple[]
    for kwp in SIZES
        here, there = optimum(name, kwp), optimum(BASE, kwp)
        (here === nothing || there === nothing) && continue
        best_row = cell(name, kwp)[argmax(cell(name, kwp).npv), :]
        base_row = cell(BASE, kwp)[argmax(cell(BASE, kwp).npv), :]
        push!(
            deltas,
            (;
                scenario = name,
                pv_kwp = kwp,
                capacity = here.capacity,
                base_capacity = there.capacity,
                d_capacity = here.capacity - there.capacity,
                d_npv = here.npv - there.npv,
                d_savings = here.savings - there.savings,
                d_import = best_row.imported_kwh - base_row.imported_kwh,
            ),
        )
    end
    isempty(deltas) && continue
    append!(sensitivity, DataFrame(deltas))
    frame = DataFrame(deltas)
    @printf(
        "%-32s%10.1f%12.0f%12.1f%12.0f\n",
        name,
        mean(frame.d_capacity),
        mean(frame.d_npv),
        mean(frame.d_savings),
        mean(frame.d_import)
    )
end
println("\n(means over the five array sizes; per-array detail in sensitivity.csv)")
isempty(sensitivity) || save_table(DATA, "sensitivity", sensitivity)

# ---------------------------------------------------------------------------------------------
# How confident the sizing answer is. A winner inside the noise is not a winner.

println("\n", "="^96)
println("How separated is the winner from the runner-up")
println("="^96)
gaps = NamedTuple[]
for name in ORDER, kwp in SIZES
    best = optimum(name, kwp)
    best === nothing && continue
    push!(gaps, (; name, kwp, best.capacity, best.runner_up, best.gap))
end
if !isempty(gaps)
    frame = DataFrame(gaps)
    tight = frame[frame.gap .< 25, :]
    @printf(
        "median gap %.0f EUR; %d of %d pairs separate the top two by under 25 EUR\n",
        median(frame.gap),
        nrow(tight),
        nrow(frame)
    )
    isempty(tight) || println(
        "\nthose, where the sizing answer should be read as a range rather than a number:",
    )
    for row in eachrow(tight)
        @printf(
            "  %-32s %5s kWp   %.1f or %.1f kWh, %.0f EUR apart\n",
            row.name,
            string(Int(row.kwp)),
            row.capacity,
            row.runner_up,
            row.gap
        )
    end
end

# ---------------------------------------------------------------------------------------------
# Where the energy went, at the best battery for each scenario and a mid-sized array.

const REFERENCE_KWP = 6.0
println("\n", "="^96)
println(
    "Energy at $(Int(REFERENCE_KWP)) kWp and each scenario's best battery — shares as percent",
)
println("="^96)
@printf(
    "%-32s%7s%9s%9s%9s%9s%14s%10s\n",
    "scenario",
    "kWh",
    "sun>use",
    "sun>bat",
    "sun>car",
    "sun>out",
    "demand>grid",
    "car>sun"
)
for name in ORDER
    rows = cell(name, REFERENCE_KWP)
    isempty(rows) && continue
    row = rows[argmax(rows.npv), :]
    pct(value) = ismissing(value) || isnan(value) ? "  -  " : @sprintf("%5.1f", 100value)
    # `demand_from_grid_share` is only in tables written after that column was added; fall back to
    # rebuilding it from the per-sink shares, which is exactly how it is defined.
    grid_share = if hasproperty(rows, :demand_from_grid_share)
        row.demand_from_grid_share
    else
        total = row.base_load_kwh + row.ev_charge_kwh
        total > 0 ?
        (
            row.base_load_kwh * row.load_from_grid_share +
            row.ev_charge_kwh * row.ev_from_grid_share
        ) / total : NaN
    end
    @printf(
        "%-32s%7.1f%9s%9s%9s%9s%14s%10s\n",
        name,
        row.battery_kwh,
        pct(row.solar_to_load_share),
        pct(row.solar_to_battery_share),
        pct(row.solar_to_ev_share),
        pct(row.solar_to_export_share),
        pct(grid_share),
        pct(row.ev_from_solar_share)
    )
end
println()
