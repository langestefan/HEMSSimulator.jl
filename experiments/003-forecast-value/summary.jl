# What experiment 003 found, as tables. Reads `data/results.csv`; no solver, no Makie.
#
#     julia --project=. experiments/003-forecast-value/summary.jl

using DataFrames
using Printf: @printf, @sprintf
using Statistics: mean

include(joinpath(@__DIR__, "..", "common.jl"))
include(joinpath(@__DIR__, "run-config.jl"))
const DATA = data_dir(@__FILE__)

results = read_table(DATA, "results")
const ORDER = [f.name for f in FORECASTS if f.name in results.forecast]
const WINS = sort(unique(results.window_hours))
const ARRAYS = sort(unique(results.pv_kwp))

cell(f, w, kwp) = results[
    (results.forecast .== f) .& (results.window_hours .== w) .& (results.pv_kwp .== kwp),
    :,
]
best(frame) = isempty(frame) ? nothing : frame[argmax(frame.npv), :]
sized(frame) = frame[frame.battery_kwh .> 0, :]

# ---------------------------------------------------------------------------------------------
# The headline: what the year costs, per forecast, at each planning horizon.
#
# Read down a column for the cost of blindness; read across a row for whether planning further ahead
# helps or merely exposes you to being wrong further ahead.

println("\n", "="^92)
println("Annual bill at the best battery, EUR — rows are forecast quality, columns the window")
println("(6 kWp array; lower is better)")
println("="^92)
@printf("%-14s", "forecast")
foreach(w -> @printf("%14s", string(Int(w), " h")), WINS)
println()
for f in ORDER
    @printf("%-14s", f)
    for w in WINS
        pick = best(sized(cell(f, w, 6.0)))
        pick === nothing && (@printf("%14s", "-"); continue)
        @printf("%14s", @sprintf("%.0f @%.1f", pick.annual_bill, pick.battery_kwh))
    end
    println()
end
println("\n\"215 @10.0\" reads: a 10 kWh battery is best and the year costs EUR 215.")

# ---------------------------------------------------------------------------------------------
# The number the study exists for.

println("\n", "="^92)
println("Cost of imperfect foresight, EUR/year against `perfect` at the same window and array")
println("="^92)
@printf("%-14s%10s", "forecast", "window")
foreach(kwp -> @printf("%13s", string(Int(kwp), " kWp")), ARRAYS)
println()
for f in ORDER
    f == "perfect" && continue
    for w in WINS
        @printf("%-14s%9.0fh", f, w)
        for kwp in ARRAYS
            here, there = best(sized(cell(f, w, kwp))), best(sized(cell("perfect", w, kwp)))
            (here === nothing || there === nothing) && (@printf("%13s", "-"); continue)
            @printf("%13.1f", here.annual_bill - there.annual_bill)
        end
        println()
    end
end
println("\nPositive means the forecast costs money. Prices are never perturbed — in this market the")
println("day-ahead auction publishes 12 to 36 hours out, so they are known, not forecast.")

# ---------------------------------------------------------------------------------------------
# Does blindness change what to buy, or only what it earns?

println("\n", "="^92)
println("NPV-optimal battery, kWh — if this moves with the forecast, sizing depends on foresight")
println("="^92)
@printf("%-14s%10s", "forecast", "window")
foreach(kwp -> @printf("%13s", string(Int(kwp), " kWp")), ARRAYS)
println()
for f in ORDER, w in WINS
    @printf("%-14s%9.0fh", f, w)
    for kwp in ARRAYS
        pick = best(sized(cell(f, w, kwp)))
        pick === nothing && (@printf("%13s", "-"); continue)
        @printf("%13s", @sprintf("%.1f (%.0f)", pick.battery_kwh, pick.npv))
    end
    println()
end

# ---------------------------------------------------------------------------------------------
# Which of the two unknowns is actually costing the money.

println("\n", "="^92)
println("Apportioning the loss at the `typical` level, EUR/year against `perfect`, 6 kWp")
println("="^92)
@printf("%-14s", "window")
foreach(f -> @printf("%14s", f), ["pv-only", "load-only", "typical"])
println()
for w in WINS
    @printf("%13.0fh", w)
    base = best(sized(cell("perfect", w, 6.0)))
    for f in ("pv-only", "load-only", "typical")
        pick = best(sized(cell(f, w, 6.0)))
        (pick === nothing || base === nothing) && (@printf("%14s", "-"); continue)
        @printf("%14.1f", pick.annual_bill - base.annual_bill)
    end
    println()
end
println("\nIf `pv-only` and `load-only` sum to about `typical`, the two errors are independent and")
println("buying a better forecast of either pays separately. If not, they interact.")
println()
