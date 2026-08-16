# What the sizing answer becomes at a different battery price and a different discount rate. Reads
# `data/results.csv`, writes `data/investment-sweep.csv` and `data/breakeven.csv`, prints the rest.
#
#     julia --project=. experiments/002-factorial-sizing/investment.jl
#
# **This re-prices the study without re-solving it.** Neither capex nor the discount rate reaches the
# dispatch objective, the bill, or the simulation cache key. What a home does with its battery — and
# therefore what it saves — is identical whatever the battery cost and whatever the owner's hurdle
# rate, so `annual_savings` and `cycles_per_year` from `results.csv` are all this needs. Tens of
# thousands of priced cases come out in seconds against the hours of solving behind them.
#
# What *would* need re-solving is a change to `degradation_cost`, which is part of the battery and
# does shape dispatch. Wear cost and cell price are different things and only one of them is free.
#
# Three things follow from `cashflows` building an **undiscounted** flow vector, with the rate
# entering only in `npv`, and are worth holding on to while reading the output:
#
#   - **IRR, payback and effective lifetime do not depend on the discount rate.** They are properties
#     of the cash flows. Only NPV moves.
#   - **The rate at which NPV reaches zero is the IRR**, by definition. The discount sweep traces a
#     line whose x-intercept is already in the IRR column, which is why IRR is the better single
#     answer to "how good an investment is this".
#   - Cell price enters only `flows[1]`, at year zero and therefore undiscounted, so NPV stays
#     exactly affine in price at every rate. The break-even price follows from one evaluation rather
#     than a search — asserted below, not assumed.

using DataFrames
using HEMSSimulator: Investment, cashflows, npv, irr, payback, effective_lifetime
using Printf: @printf, @sprintf
using Statistics: mean, std

include(joinpath(@__DIR__, "..", "common.jl"))
include(joinpath(@__DIR__, "run-config.jl"))
const DATA = data_dir(@__FILE__)

results = read_table(DATA, "results")
const ORDER = [s.name for s in SCENARIOS if s.name in results.scenario]
const SIZES = sort(unique(results.pv_kwp))
const BASE = "base"
const REFERENCE_KWP = 6.0

sized = results[results.battery_kwh .> 0, :]

"""
The cash flows of one simulated case at one cell price, plus everything about it that the discount
rate cannot change. `savings` and `cycles` are what the simulation produced and neither depends on
what the battery cost or on what the owner's alternative use of the money is.
"""
function flows_of(capacity, savings, cycles, per_kwh)
    inv = Investment(
        capex = FIXED_CAPEX + per_kwh * capacity,
        lifetime_years = LIFETIME_YEARS,
        rated_cycles = RATED_CYCLES,
        # Irrelevant here: `cashflows` never reads it. The rate is applied by `npv` below.
        discount_rate = 0.0,
    )
    flows = cashflows(savings, inv; cycles_per_year = cycles)
    return (;
        capex = inv.capex,
        flows,
        irr = irr(flows),
        payback_years = payback(flows),
        lifetime_years = effective_lifetime(inv, cycles),
    )
end

# ---------------------------------------------------------------------------------------------
# The full priced grid: every case, at every price, at every rate.

priced = DataFrame()
for row in eachrow(sized), per_kwh in CAPEX_LADDER
    case = flows_of(row.battery_kwh, row.annual_savings, row.cycles_per_year, per_kwh)
    for rate in DISCOUNT_LADDER
        push!(
            priced,
            (;
                scenario = row.scenario,
                pv_kwp = row.pv_kwp,
                battery_kwh = row.battery_kwh,
                capex_per_kwh = per_kwh,
                discount_rate = rate,
                annual_savings = row.annual_savings,
                cycles_per_year = row.cycles_per_year,
                capex = case.capex,
                npv = npv(case.flows, rate),
                irr = case.irr,
                payback_years = case.payback_years,
                lifetime_years = case.lifetime_years,
            ),
        )
    end
end
save_table(DATA, "investment-sweep", priced)

# A self-check rather than a comment: at the price and rate `results.csv` was written at, this must
# reproduce the `npv` column already in it. If it fails, the arithmetic here and the arithmetic in
# `kpis` have drifted apart and every number below is suspect.
let
    check = priced[
        (priced.capex_per_kwh .== RESULTS_PER_KWH) .& (priced.discount_rate .== DISCOUNT_RATE),
        :,
    ]
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
# One slice of the priced grid. Every argument is optional and an omitted one is not filtered on, so
# the tables below can each cut it a different way without four near-identical selectors.
function at(; scenario = nothing, kwp = nothing, per_kwh = nothing, rate = nothing)
    keep = trues(nrow(priced))
    scenario === nothing || (keep .&= priced.scenario .== scenario)
    kwp === nothing || (keep .&= priced.pv_kwp .== kwp)
    per_kwh === nothing || (keep .&= priced.capex_per_kwh .== per_kwh)
    rate === nothing || (keep .&= priced.discount_rate .== rate)
    return priced[keep, :]
end
cellname(pick) =
    pick === nothing ? "-" : @sprintf("%.1f (%.0f)", pick.battery_kwh, pick.npv)

# ---------------------------------------------------------------------------------------------

println("\n", "="^96)
println(
    "`$BASE`: NPV-optimal battery, kWh (NPV EUR), by cell price and array, at $(round(Int, 100DISCOUNT_RATE))% discount",
)
println("="^96)
@printf("%12s", "EUR/kWh")
foreach(kwp -> @printf("%16s", string(Int(kwp), " kWp")), SIZES)
println()
for per_kwh in CAPEX_LADDER
    @printf("%12.0f", per_kwh)
    foreach(
        kwp -> @printf(
            "%16s",
            cellname(best(at(; scenario = BASE, kwp, per_kwh, rate = DISCOUNT_RATE)))
        ),
        SIZES,
    )
    println()
end

# ---------------------------------------------------------------------------------------------
# The discount sweep the same way round: what the owner's hurdle rate does to the answer.

println("\n", "="^96)
println(
    "`$BASE`: NPV-optimal battery, kWh (NPV EUR), by discount rate and array, at $(Int(RESULTS_PER_KWH)) EUR/kWh",
)
println("="^96)
@printf("%12s", "discount")
foreach(kwp -> @printf("%16s", string(Int(kwp), " kWp")), SIZES)
println()
for rate in DISCOUNT_LADDER
    @printf("%11.0f%%", 100rate)
    foreach(
        kwp -> @printf(
            "%16s",
            cellname(best(at(; scenario = BASE, kwp, per_kwh = RESULTS_PER_KWH, rate)))
        ),
        SIZES,
    )
    println()
end

# ---------------------------------------------------------------------------------------------
# A sizing rule of thumb, and how it moves with the cell price.
#
# The optimum is close to linear in the array, but **not proportional to it**: at a low enough cell
# price a battery is worth buying with no solar at all, so the line has an intercept and quoting a
# single "kWh per kWp" would be wrong at both ends. Fitted as `kWh = a + b x kWp` by least squares
# across every scenario and array at each price.
#
# Cells whose optimum is the largest candidate on the grid are **excluded, not clipped**. They mean
# "at least 30 kWh" rather than "30 kWh" (see the README), and since censoring bites hardest at the
# large arrays it would drag the slope down exactly where the slope is being measured. The count of
# excluded cells is printed: where it is large, the fit rests on the small arrays alone and the rule
# should not be trusted.

const CENSOR = maximum(BATTERY_KWH)

function sizing_rule(per_kwh, rate)
    arrays, capacities, censored = Float64[], Float64[], 0
    for name in ORDER, kwp in SIZES
        pick = best(at(; scenario = name, kwp, per_kwh, rate))
        pick === nothing && continue
        if pick.battery_kwh >= CENSOR - 1e-9
            censored += 1
            continue
        end
        push!(arrays, kwp)
        push!(capacities, pick.battery_kwh)
    end
    length(arrays) >= 4 && length(unique(arrays)) >= 2 || return nothing
    x̄, ȳ = mean(arrays), mean(capacities)
    slope = sum((arrays .- x̄) .* (capacities .- ȳ)) / sum((arrays .- x̄) .^ 2)
    intercept = ȳ - slope * x̄
    residual = capacities .- (intercept .+ slope .* arrays)
    spread = length(residual) > 2 ? std(residual) : NaN
    return (; intercept, slope, spread, n = length(arrays), censored)
end

println("\n", "="^96)
println(
    "Sizing rule: NPV-optimal battery as kWh = a + b x kWp, fitted across all scenarios",
)
println(
    "(cells at the 30 kWh grid edge are excluded — they mean \"at least 30\", not \"30\")",
)
println("="^96)
@printf(
    "%12s%10s%12s%14s%22s\n",
    "EUR/kWh",
    "rate",
    "a (kWh)",
    "b (kWh/kWp)",
    "scatter / cells used"
)
for per_kwh in CAPEX_LADDER, rate in (DISCOUNT_RATE, last(DISCOUNT_LADDER))
    fit = sizing_rule(per_kwh, rate)
    @printf("%12.0f%9.0f%%", per_kwh, 100rate)
    fit === nothing && (println("            — every cell is at the grid edge"); continue)
    @printf(
        "%12.1f%14.2f%12.1f kWh, %2d of %2d\n",
        fit.intercept,
        fit.slope,
        fit.spread,
        fit.n,
        fit.n + fit.censored
    )
end
println(
    "\nAt today's prices the rule is roughly one kWh of battery per kWp of array plus a small",
)
println(
    "fixed part; as cells get cheaper both the slope and the standalone battery grow, and below",
)
println(
    "about 250 EUR/kWh the grid edge starts removing the cells the slope is measured from.",
)

# ---------------------------------------------------------------------------------------------
# The rate-independent verdict. This is the column to read if the question is "how good an
# investment is it" rather than "what is it worth to me at my hurdle rate".

println("\n", "="^96)
println(
    "Internal rate of return of the best battery at $(Int(RESULTS_PER_KWH)) EUR/kWh, percent per year",
)
println(
    "(same at every discount rate; the rate at which NPV reaches zero *is* this number)",
)
println("="^96)
@printf("%-32s", "scenario")
foreach(kwp -> @printf("%14s", string(Int(kwp), " kWp")), SIZES)
println()
for name in ORDER
    @printf("%-32s", name)
    for kwp in SIZES
        # Rank by NPV at the study's own rate, then report that candidate's IRR — the alternative,
        # picking the highest-IRR candidate, would always name the smallest battery, since IRR is a
        # rate of return and says nothing about how much money is made.
        pick = best(
            at(; scenario = name, kwp, per_kwh = RESULTS_PER_KWH, rate = DISCOUNT_RATE),
        )
        pick === nothing && (@printf("%14s", "-"); continue)
        @printf(
            "%14s",
            isnan(pick.irr) ? @sprintf("never @%.1f", pick.battery_kwh) :
            @sprintf("%.1f%% @%.1f", 100pick.irr, pick.battery_kwh)
        )
    end
    println()
end
println("\n\"8.4% @12.5\" reads: the best battery is 12.5 kWh and returns 8.4% a year.")
println(
    "\"never\" means the cash flows never cross zero — it does not pay back at any rate.",
)

# ---------------------------------------------------------------------------------------------
# How cheap does a battery have to get. Affine in price at every rate, so one evaluation each.

function breakeven(capacity, savings, cycles, rate)
    capacity > 0 || return NaN
    free = npv(flows_of(capacity, savings, cycles, 0.0).flows, rate)  # if the cells were free
    price = free / capacity
    residual = npv(flows_of(capacity, savings, cycles, price).flows, rate)
    abs(residual) < 1e-6 ||
        error("NPV is not affine in the cell price: $price EUR/kWh leaves $residual EUR")
    return price
end

rows = NamedTuple[]
for row in eachrow(sized), rate in DISCOUNT_LADDER
    push!(
        rows,
        (;
            row.scenario,
            row.pv_kwp,
            row.battery_kwh,
            discount_rate = rate,
            row.annual_savings,
            breakeven_eur_per_kwh = breakeven(
                row.battery_kwh,
                row.annual_savings,
                row.cycles_per_year,
                rate,
            ),
        ),
    )
end
thresholds = DataFrame(rows)
save_table(DATA, "breakeven", thresholds)

println("\n", "="^96)
println(
    "Break-even cell price, EUR/kWh — the most a buyer could pay and still not lose money",
)
println("(best over battery sizes; rows are the buyer's discount rate; `$BASE` scenario)")
println("="^96)
@printf("%12s", "discount")
foreach(kwp -> @printf("%14s", string(Int(kwp), " kWp")), SIZES)
println()
for rate in DISCOUNT_LADDER
    @printf("%11.0f%%", 100rate)
    for kwp in SIZES
        block = thresholds[
            (thresholds.scenario .== BASE) .& (thresholds.pv_kwp .== kwp) .& (thresholds.discount_rate .== rate),
            :,
        ]
        isempty(block) && (@printf("%14s", "-"); continue)
        index = argmax(block.breakeven_eur_per_kwh)
        @printf(
            "%14s",
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
    "\n\"680 @5.0\" reads: a 5.0 kWh pack breaks even at 680 EUR/kWh, the best any size manages.",
)
println("Every scenario and rate is in breakeven.csv.")

# ---------------------------------------------------------------------------------------------

println("\n", "="^96)
println(
    "Optimal battery at $(Int(REFERENCE_KWP)) kWp as the cell price falls, kWh (NPV EUR), at $(round(Int, 100DISCOUNT_RATE))% discount",
)
println("="^96)
@printf("%-32s", "scenario")
foreach(per_kwh -> @printf("%15s", string(Int(per_kwh), " EUR")), CAPEX_LADDER)
println()
for name in ORDER
    @printf("%-32s", name)
    foreach(
        per_kwh -> @printf(
            "%15s",
            cellname(
                best(
                    at(;
                        scenario = name,
                        kwp = REFERENCE_KWP,
                        per_kwh,
                        rate = DISCOUNT_RATE,
                    ),
                ),
            )
        ),
        CAPEX_LADDER,
    )
    println()
end
println()
