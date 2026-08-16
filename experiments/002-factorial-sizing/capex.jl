# What the sizing answer becomes at a different battery price. Reads `data/results.csv`, writes
# `data/capex-sweep.csv` and `data/breakeven.csv`, prints the rest.
#
#     julia --project=. experiments/002-factorial-sizing/capex.jl
#
# **This re-prices the study without re-solving it.** Capex reaches only the investment arithmetic:
# it is not in the dispatch objective, not in the bill, and not in the simulation cache key. What a
# home does with its battery, and therefore what it saves, is identical whatever the battery cost —
# so `annual_savings` and `cycles_per_year` from `results.csv` are all this needs, and 4410 priced
# cases come out in seconds against the hours the 630 simulations behind them took.
#
# What *would* need re-solving is a change to `degradation_cost`, which is part of the battery and
# does shape dispatch. Cell price and wear cost are different things and only one of them is free.

using DataFrames
using HEMSSimulator: Investment, cashflows, npv, irr, payback, effective_lifetime
using Printf: @printf, @sprintf

include(joinpath(@__DIR__, "..", "common.jl"))
include(joinpath(@__DIR__, "run-config.jl"))
const DATA = data_dir(@__FILE__)

results = read_table(DATA, "results")
const ORDER = [s.name for s in SCENARIOS if s.name in results.scenario]
const SIZES = sort(unique(results.pv_kwp))
const BASE = "base"
const REFERENCE_KWP = 6.0

sized = results[results.battery_kwh .> 0, :]

investment(capacity, per_kwh) = Investment(
    capex = FIXED_CAPEX + per_kwh * capacity,
    lifetime_years = LIFETIME_YEARS,
    rated_cycles = RATED_CYCLES,
    discount_rate = DISCOUNT_RATE,
)

"""
Re-price one simulated case at one cell price. `savings` and `cycles` are what the simulation
produced and neither depends on what the battery cost.
"""
function reprice(capacity, savings, cycles, per_kwh)
    inv = investment(capacity, per_kwh)
    flows = cashflows(savings, inv; cycles_per_year = cycles)
    return (;
        capex = inv.capex,
        npv = npv(flows, DISCOUNT_RATE),
        irr = irr(flows),
        payback_years = payback(flows),
        lifetime_years = effective_lifetime(inv, cycles),
    )
end

# ---------------------------------------------------------------------------------------------
# The full priced grid.

priced = DataFrame()
for row in eachrow(sized), per_kwh in CAPEX_LADDER
    metrics = reprice(row.battery_kwh, row.annual_savings, row.cycles_per_year, per_kwh)
    push!(
        priced,
        merge(
            (;
                scenario = row.scenario,
                pv_kwp = row.pv_kwp,
                battery_kwh = row.battery_kwh,
                capex_per_kwh = per_kwh,
                annual_savings = row.annual_savings,
                cycles_per_year = row.cycles_per_year,
            ),
            metrics,
        ),
    )
end
save_table(DATA, "capex-sweep", priced)

# A self-check rather than a comment: at the price `results.csv` was written at, the re-priced NPV
# must reproduce the column already in it. If this fails, the arithmetic here and the arithmetic in
# `kpis` have drifted apart and every number below is suspect.
let
    check = priced[priced.capex_per_kwh .== RESULTS_PER_KWH, :]
    joined = innerjoin(
        check,
        select(sized, :scenario, :pv_kwp, :battery_kwh, :npv => :npv_original),
        on = [:scenario, :pv_kwp, :battery_kwh],
    )
    worst = maximum(abs.(joined.npv - joined.npv_original); init = 0.0)
    @assert worst < 1e-6 "re-priced NPV disagrees with results.csv by $worst EUR"
    println("  re-pricing reproduces results.csv to ", round(worst, sigdigits = 2), " EUR")
end

best(frame) = isempty(frame) ? nothing : frame[argmax(frame.npv), :]
cell(scenario, kwp, per_kwh) = priced[
    (priced.scenario .== scenario) .& (priced.pv_kwp .== kwp) .& (priced.capex_per_kwh .== per_kwh),
    :,
]

# ---------------------------------------------------------------------------------------------

println("\n", "="^92)
println("`$BASE` scenario: NPV-optimal battery, kWh (NPV EUR), by cell price and array")
println("="^92)
@printf("%12s", "EUR/kWh")
for kwp in SIZES
    @printf("%16s", string(Int(kwp), " kWp"))
end
println()
for per_kwh in CAPEX_LADDER
    @printf("%12.0f", per_kwh)
    for kwp in SIZES
        pick = best(cell(BASE, kwp, per_kwh))
        pick === nothing && (@printf("%16s", "-"); continue)
        @printf("%16s", @sprintf("%.1f (%.0f)", pick.battery_kwh, pick.npv))
    end
    println()
end

# ---------------------------------------------------------------------------------------------
# The number a buyer actually wants: how cheap does a battery have to get.
#
# NPV is affine in the cell price — the only place price enters is the year-zero outlay, and nothing
# else in the cashflow depends on it — so the break-even price follows from a single evaluation
# rather than a search. It is asserted below rather than assumed.

function breakeven(scenario, kwp, capacity, savings, cycles)
    capacity > 0 || return NaN
    free = reprice(capacity, savings, cycles, 0.0).npv     # NPV if the cells were free
    price = free / capacity
    residual = reprice(capacity, savings, cycles, price).npv
    abs(residual) < 1e-6 || error(
        "NPV is not affine in the cell price ($scenario, $kwp kWp, $capacity kWh): " *
        "solved $price EUR/kWh leaves $residual EUR",
    )
    return price
end

rows = NamedTuple[]
for row in eachrow(sized)
    push!(
        rows,
        (;
            row.scenario,
            row.pv_kwp,
            row.battery_kwh,
            row.annual_savings,
            breakeven_eur_per_kwh = breakeven(
                row.scenario,
                row.pv_kwp,
                row.battery_kwh,
                row.annual_savings,
                row.cycles_per_year,
            ),
        ),
    )
end
thresholds = DataFrame(rows)
save_table(DATA, "breakeven", thresholds)

println("\n", "="^92)
println(
    "Break-even cell price, EUR/kWh — the most a buyer could pay and still not lose money",
)
println(
    "(best over battery sizes; a battery below this price pays for itself, above it does not)",
)
println("="^92)
@printf("%-32s", "scenario")
for kwp in SIZES
    @printf("%12s", string(Int(kwp), " kWp"))
end
println()
for name in ORDER
    @printf("%-32s", name)
    for kwp in SIZES
        block = thresholds[(thresholds.scenario .== name) .& (thresholds.pv_kwp .== kwp), :]
        isempty(block) && (@printf("%12s", "-"); continue)
        index = argmax(block.breakeven_eur_per_kwh)
        @printf(
            "%12s",
            @sprintf(
                "%.0f @%.1f",
                block.breakeven_eur_per_kwh[index],
                block.battery_kwh[index]
            )
        )
    end
    println()
end
println(
    "\n\"180 @7.5\" reads: a 7.5 kWh pack breaks even at 180 EUR/kWh, the best any size manages.",
)

# ---------------------------------------------------------------------------------------------
# How the optimum grows as batteries get cheaper, across every scenario at one array.

println("\n", "="^92)
println(
    "Optimal battery at $(Int(REFERENCE_KWP)) kWp as the cell price falls, kWh (NPV EUR)",
)
println("="^92)
@printf("%-32s", "scenario")
for per_kwh in CAPEX_LADDER
    @printf("%15s", string(Int(per_kwh), " EUR"))
end
println()
for name in ORDER
    @printf("%-32s", name)
    for per_kwh in CAPEX_LADDER
        pick = best(cell(name, REFERENCE_KWP, per_kwh))
        pick === nothing && (@printf("%15s", "-"); continue)
        @printf("%15s", @sprintf("%.1f (%.0f)", pick.battery_kwh, pick.npv))
    end
    println()
end
println()
