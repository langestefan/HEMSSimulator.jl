# What a battery is worth when the controller cannot see the future.
#
#     julia --project=. -t auto experiments/003-forecast-value/run.jl
#
# 6 forecasts x 4 window lengths x 3 PV sizes x 5 battery sizes = 360 annual simulations at a
# 15-minute control step. The perfect-forecast arm is shared with nothing — experiment 002 solved a
# different home — so all of it is new work.
#
# **What is being measured.** Every result in experiments 001 and 002 optimizes each window against
# the truth. That measures what the assets are physically worth and is an upper bound on what any
# controller can deliver. Here the controller optimizes against a *belief*, implements the asset
# setpoints it decided on, and the meter absorbs whatever the belief got wrong. The difference in the
# annual bill is the value of the forecast.
#
# Needs ENV["ENTSOE_API_TOKEN"]; downloads and simulations are both cached.

using HEMSSimulator
using DataFrames
using Dates
using Printf: @sprintf
using Statistics: mean

include(joinpath(@__DIR__, "..", "common.jl"))
include(joinpath(@__DIR__, "run-config.jl"))
const DATA = data_dir(@__FILE__)
const SOLVED = joinpath(DATA, "solved.txt")

println("fetching inputs")
weather = openmeteo_weather(SITE, YEAR)
prices = entsoe_prices(YEAR)
load = synthetic_load(YEAR; annual_kwh = HOUSEHOLD_KWH)
save_inputs(DATA, YEAR, weather, prices, load)
contract = tibber_contract(YEAR, prices)

configs = vec([
    (;
        forecast = f,
        window_hours = w,
        kwp,
        kwh,
        name = config_name(f.name, w, kwp, kwh),
    ) for f in FORECASTS, w in WINDOWS, kwp in PV_KWP, kwh in BATTERY_KWH
])
println(
    "\n",
    length(FORECASTS), " forecasts x ", length(WINDOWS), " windows x ",
    length(PV_KWP), " arrays x ", length(BATTERY_KWH), " batteries = ",
    length(configs), " annual simulations on ", Threads.nthreads(), " threads",
)

# Inputs depend on the array and the contract only — not on the forecast, which is applied per window
# inside the driver, and not on the window length, which is a run option.
prepared = Dict(
    kwp => prepare(home(kwp), weather, load, contract; options = OPTIONS(first(WINDOWS)))
    for kwp in PV_KWP
)

log_lock = ReentrantLock()
open(SOLVED, "a") do io
    println(io, "# run started ", Dates.format(Dates.now(), dateformat"yyyy-mm-dd HH:MM:SS"))
    println(io, "# name\tseconds\timported_kwh\tannual_bill_eur")
end

function solve(config)
    system = home(config.kwp)
    config.kwh > 0 &&
        (system = with_assets(system, vcat(system.assets, [battery(config.kwh)])))
    options = OPTIONS(config.window_hours)
    elapsed = @elapsed result = simulate(
        system,
        prepared[config.kwp];
        options,
        forecast = config.forecast.forecast,
        cache = true,
    )
    bill = settle(result, contract)
    Base.@lock log_lock open(SOLVED, "a") do io
        println(io, @sprintf("%-38s\t%7.1f\t%8.1f\t%9.2f", config.name, elapsed,
            bill.imported_kwh, annualise(bill)))
    end
    return (;
        name = config.name,
        forecast = config.forecast.name,
        window_hours = config.window_hours,
        pv_kwp = config.kwp,
        battery_kwh = config.kwh,
        annual_bill = annualise(bill),
        imported_kwh = bill.imported_kwh,
        exported_kwh = bill.exported_kwh,
        curtailed_kwh = sum(result.frame.curtail_kw) * hours(YEAR),
        battery_discharge_kwh = config.kwh > 0 ?
                                sum(result.frame.battery_discharge_kw) * hours(YEAR) : 0.0,
        cycles_per_year = cycles_per_year(result),
        self_consumption = self_consumption(result),
        self_sufficiency = self_sufficiency(result),
    ),
    bill
end

# Phase 1: the no-battery homes, one per (forecast, window, array). A battery's saving is measured
# against the same house with the same controller and the same blindness — otherwise the comparison
# would credit the battery with the forecast's effect on the base case.
baselines = filter(c -> c.kwh == 0, configs)
cases = filter(c -> c.kwh > 0, configs)
println("\nphase 1: ", length(baselines), " no-battery baselines")
bar = ProgressBar(length(baselines); label = "baselines")
baseline_rows = Vector{NamedTuple}(undef, length(baselines))
bills = Dict{Tuple{String,Float64,Float64},Any}()
lk = ReentrantLock()
Threads.@threads for i in eachindex(baselines)
    c = baselines[i]
    row, bill = solve(c)
    baseline_rows[i] = row
    Base.@lock lk bills[(c.forecast.name, c.window_hours, float(c.kwp))] = bill
    step!(bar)
end

println("\nphase 2: ", length(cases), " battery cases")
bar = ProgressBar(length(cases); label = "cases     ")
case_rows = Vector{NamedTuple}(undef, length(cases))
Threads.@threads for i in eachindex(cases)
    c = cases[i]
    row, bill = solve(c)
    base = bills[(c.forecast.name, c.window_hours, float(c.kwp))]
    k = kpis(base, bill, INVESTMENT(c.kwh))
    case_rows[i] = merge(row, (; annual_savings = k.annual_savings, npv = k.npv))
    step!(bar)
end

baseline_rows =
    [merge(r, (; annual_savings = 0.0, npv = NaN)) for r in baseline_rows]
results = sort(
    DataFrame(vcat(baseline_rows, case_rows)),
    [:forecast, :window_hours, :pv_kwp, :battery_kwh],
)
save_table(DATA, "results", results)
println("\nsimulation done — run summary.jl to read it")
