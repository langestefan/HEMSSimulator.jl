# How large a battery is worth buying, across a grid of PV sizes and eight household contexts.
#
#     julia --project=. -t auto experiments/002-factorial-sizing/run.jl
#
# 8 scenarios x 5 PV sizes x 10 battery sizes = 400 annual simulations at a 15-minute step, each of
# them 35 040 solves. On 32 threads that is roughly an hour. See `run-config.jl` for why eight named
# scenarios rather than the full factorial over the same factors, which would be 4320 runs.
#
# **Simulation only.** Everything this produces is a CSV in `data/`; not a single plot is drawn, and
# Makie is never loaded.
#
# Two files make a long run watchable and a crashed one cheap:
#
#   - `data/solved.txt` gets one line per finished configuration, appended as it finishes. `tail -f`
#     it. It is an append log across runs, not a per-run file, so the history of what was solved when
#     survives.
#   - `simulate(...; cache = true)` stores every result under `simulation_cache_dir()`, keyed by a
#     digest of the system, the inputs and the options. A re-run after a crash re-reads rather than
#     re-solves, so resuming costs minutes rather than the hour. It also costs disk: 400 years of
#     15-minute flows is a couple of gigabytes.
#
# Needs ENV["ENTSOE_API_TOKEN"] for the day-ahead prices; downloads are cached too.

using HEMSSimulator
using DataFrames
using Dates
using Printf: @sprintf
using Statistics: mean

include(joinpath(@__DIR__, "..", "common.jl"))
include(joinpath(@__DIR__, "run-config.jl"))
include(joinpath(@__DIR__, "kpis.jl"))
const DATA = data_dir(@__FILE__)
const SOLVED = joinpath(DATA, "solved.txt")

# ---------------------------------------------------------------------------------------------

println("fetching inputs")
weather = openmeteo_weather(SITE, YEAR)
prices = entsoe_prices(YEAR)
load = synthetic_load(YEAR; annual_kwh = HOUSEHOLD_KWH)

println(
    "  day-ahead mean ",
    round(100 * mean(prices), digits = 2),
    " ct/kWh, ",
    count(<(0), prices),
    " negative quarter-hours",
)
println(
    "  irradiation ",
    round(sum(weather.ghi) * hours(YEAR) / 1000, digits = 1),
    " kWh/m2",
)

save_inputs(DATA, YEAR, weather, prices, load)
contract = tibber_contract(YEAR, prices)

# ---------------------------------------------------------------------------------------------
# The run.

configs = vec([
    (; scenario = s, kwp, kwh, name = config_name(s, kwp, kwh)) for
    s in SCENARIOS, kwp in PV_KWP, kwh in BATTERY_KWH
])
baselines = filter(config -> config.kwh == 0, configs)
cases = filter(config -> config.kwh > 0, configs)

println(
    "\n",
    length(SCENARIOS),
    " scenarios x ",
    length(PV_KWP),
    " PV sizes x ",
    length(BATTERY_KWH),
    " battery sizes = ",
    length(configs),
    " annual simulations of ",
    YEAR.n,
    " intervals, on ",
    Threads.nthreads(),
    " threads",
)
Threads.nthreads() == 1 &&
    @warn "running on one thread; start julia with -t auto or this will take a day"

# `inputs` depends on the array layout and on the contract, so it is shared by every configuration
# with the same scenario orientation and PV size — 10 battery sizes each. Prepared once per pair.
prepared = Dict{Tuple{Symbol,Float64},SimulationInputs}()
for orientation in unique(s.orientation for s in SCENARIOS), kwp in PV_KWP
    key = (orientation, float(kwp))
    haskey(prepared, key) && continue
    reference = HomeSystem(site = SITE, pv = arrays(kwp, orientation))
    prepared[key] = prepare(reference, weather, load, contract; options = OPTIONS)
end
inputs_for(config) = prepared[(config.scenario.orientation, float(config.kwp))]

log_lock = ReentrantLock()
open(SOLVED, "a") do io
    println(
        io,
        "# run started ",
        Dates.format(Dates.now(), dateformat"yyyy-mm-dd HH:MM:SS"),
    )
    println(io, "# name\tseconds\timported_kwh\tannual_bill_eur\tnpv_eur")
end

function note!(row, seconds)
    Base.@lock log_lock begin
        open(SOLVED, "a") do io
            println(
                io,
                @sprintf(
                    "%-34s\t%7.1f\t%8.1f\t%9.2f\t%9.2f",
                    row.name,
                    seconds,
                    row.imported_kwh,
                    row.annual_bill,
                    row.npv
                )
            )
        end
    end
    return nothing
end

"""
Simulate one configuration and turn it into a KPI row. `baseline_bill` is the same home with the
same array and no battery, so `annual_savings` is what the *battery* adds — the panels cancel.
"""
function solve(config, baseline_bill)
    system = home(config.scenario, config.kwp)
    config.kwh > 0 && (
        system = with_assets(
            system,
            vcat(system.assets, [battery(config.scenario, config.kwh)]),
        )
    )
    elapsed = @elapsed result =
        simulate(system, inputs_for(config); options = OPTIONS, cache = true)
    bill = settle(result, contract)
    row = metrics(config, result, bill, baseline_bill)
    note!(row, elapsed)
    return row, bill
end

# Phase 1: the no-battery homes. Every battery case is measured against the one with its own
# scenario and its own array, so these must all exist before any of them run.
println("\nphase 1: ", length(baselines), " no-battery baselines")
bar = ProgressBar(length(baselines); label = "baselines")
baseline_rows = Vector{NamedTuple}(undef, length(baselines))
baseline_bills = Dict{Tuple{String,Float64},Any}()
baseline_lock = ReentrantLock()
Threads.@threads for index in eachindex(baselines)
    config = baselines[index]
    row, bill = solve(config, nothing)
    baseline_rows[index] = row
    Base.@lock baseline_lock baseline_bills[(config.scenario.name, float(config.kwp))] =
        bill
    step!(bar)
end
save_table(DATA, "results", DataFrame(baseline_rows))

# Phase 2: every battery size, all of them independent.
println("\nphase 2: ", length(cases), " battery cases")
bar = ProgressBar(length(cases); label = "cases     ")
case_rows = Vector{NamedTuple}(undef, length(cases))
Threads.@threads for index in eachindex(cases)
    config = cases[index]
    baseline = baseline_bills[(config.scenario.name, float(config.kwp))]
    case_rows[index], _ = solve(config, baseline)
    step!(bar)
end

results = DataFrame(vcat(baseline_rows, case_rows))
sort!(results, [:scenario, :pv_kwp, :battery_kwh])
save_table(DATA, "results", results)

# ---------------------------------------------------------------------------------------------
# What it found, briefly. The figures script is where this gets read properly.

println("\nbest battery by NPV, per scenario and array:")
sized = filter(row -> row.battery_kwh > 0, results)
picks = [
    parentindices(group)[1][argmax(group.npv)] for
    group in groupby(sized, [:scenario, :pv_kwp])
]
best_rows = sort(sized[picks, :], [:scenario, :pv_kwp])
println(
    select(
        best_rows,
        :scenario,
        :pv_kwp,
        :battery_kwh,
        :annual_savings,
        :npv,
        :cycles_per_year,
        :self_sufficiency,
    ),
)
save_table(DATA, "best-by-scenario", best_rows)

println("\nsolved ", nrow(results), " configurations; names logged to ", relpath(SOLVED))
println("simulation done — run figures.jl to draw")
