# Do the 2025 findings survive 2026?
#
#     julia --project=. -t auto experiments/004-year-on-year/run.jl
#
# 2 years x 12 scenarios x 5 arrays x 10 batteries = 1200 simulations over 1 January to 15 August.
# Needs ENV["ENTSOE_API_TOKEN"].

using HEMSSimulator
using DataFrames
using Dates
using Printf: @sprintf
using Statistics: mean, quantile

include(joinpath(@__DIR__, "..", "common.jl"))
include(joinpath(@__DIR__, "run-config.jl"))
const DATA = data_dir(@__FILE__)
const SOLVED = joinpath(DATA, "solved.txt")

inputs_of = Dict{Int,Any}()
println("fetching inputs")
for year in YEARS
    g = window_for(year)
    w = openmeteo_weather(SITE, g)
    p = entsoe_prices(g)
    l = synthetic_load(g; annual_kwh = HOUSEHOLD_KWH)
    inputs_of[year] = (; grid = g, weather = w, prices = p, load = l)
    @printf(
        "  %d: %.0f kWh/m2, spot mean %.2f ct/kWh, %d negative quarter-hours, p90-p10 %.2f ct\n",
        year, sum(w.ghi) * hours(g) / 1000, 100mean(p), count(<(0), p),
        100 * (quantile(p, 0.9) - quantile(p, 0.1)),
    )
    save_table(DATA, "inputs-$year", DataFrame(timestamp = timestamps(g), day_ahead_eur_kwh = p,
        load_kw = l, ghi_w_m2 = w.ghi, dni_w_m2 = w.dni, dhi_w_m2 = w.dhi,
        t_amb_c = w.t_amb, wind_m_s = w.wind))
end

configs = vec([
    (; year, scenario = s, kwp, kwh, name = config_name(year, s, kwp, kwh))
    for year in YEARS, s in SCENARIOS, kwp in PV_KWP, kwh in BATTERY_KWH
])
println("\n", length(configs), " simulations on ", Threads.nthreads(), " threads")

# Contracts and prepared inputs, per year and per distinct contract. The load series differs by
# household size, which only one scenario changes.
contracts = Dict((y, contract_key(s)) => contract_for(s, inputs_of[y].grid, inputs_of[y].prices)
                 for y in YEARS, s in SCENARIOS)
loads = Dict((y, size) => synthetic_load(inputs_of[y].grid; annual_kwh = size)
             for y in YEARS, size in unique(s.household_kwh for s in SCENARIOS))
prepared = Dict{Any,SimulationInputs}()
for y in YEARS, s in SCENARIOS, kwp in PV_KWP
    key = (y, s.orientation, s.tilt, float(kwp), s.household_kwh, contract_key(s))
    haskey(prepared, key) && continue
    ref = HomeSystem(site = SITE, pv = arrays(kwp, s.orientation, s.tilt))
    prepared[key] = prepare(ref, inputs_of[y].weather, loads[(y, s.household_kwh)],
                            contracts[(y, contract_key(s))]; options = OPTIONS)
end
inputs_for(c) = prepared[(c.year, c.scenario.orientation, c.scenario.tilt, float(c.kwp),
                          c.scenario.household_kwh, contract_key(c.scenario))]

log_lock = ReentrantLock()
open(SOLVED, "a") do io
    println(io, "# run started ", Dates.format(Dates.now(), dateformat"yyyy-mm-dd HH:MM:SS"))
end

function solve(c, baseline_bill)
    sys = home(c.scenario, c.kwp, inputs_of[c.year].grid)
    c.kwh > 0 && (sys = with_assets(sys, vcat(sys.assets, [battery(c.scenario, c.kwh)])))
    elapsed = @elapsed r = simulate(sys, inputs_for(c); options = OPTIONS, cache = true)
    bill = settle(r, contracts[(c.year, contract_key(c.scenario))])
    dt = hours(inputs_of[c.year].grid)
    metrics = c.kwh > 0 ? kpis(baseline_bill, bill, INVESTMENT(c.kwh); result = r) :
              (; annual_savings = 0.0, npv = NaN, irr = NaN, payback_years = NaN,
                 lifetime_years = NaN, self_consumption = self_consumption(r),
                 self_sufficiency = self_sufficiency(r), cycles_per_year = NaN)
    Base.@lock log_lock open(SOLVED, "a") do io
        println(io, @sprintf("%-44s\t%7.1f\t%9.2f", c.name, elapsed, annualise(bill)))
    end
    return merge((; name = c.name, year = c.year, scenario = c.scenario.name, pv_kwp = c.kwp,
        battery_kwh = c.kwh, annual_bill = annualise(bill), imported_kwh = bill.imported_kwh,
        exported_kwh = bill.exported_kwh,
        curtailed_kwh = sum(r.frame.curtail_kw) * dt,
        battery_discharge_kwh = c.kwh > 0 ? sum(r.frame.battery_discharge_kw) * dt : 0.0),
        metrics), bill
end

baselines = filter(c -> c.kwh == 0, configs)
cases = filter(c -> c.kwh > 0, configs)
println("\nphase 1: ", length(baselines), " baselines")
bar = ProgressBar(length(baselines); label = "baselines")
brows = Vector{NamedTuple}(undef, length(baselines))
bills = Dict{Tuple{Int,String,Float64},Any}(); lk = ReentrantLock()
Threads.@threads for i in eachindex(baselines)
    c = baselines[i]; row, bill = solve(c, nothing); brows[i] = row
    Base.@lock lk bills[(c.year, c.scenario.name, float(c.kwp))] = bill
    step!(bar)
end
println("\nphase 2: ", length(cases), " battery cases")
bar = ProgressBar(length(cases); label = "cases     ")
crows = Vector{NamedTuple}(undef, length(cases))
Threads.@threads for i in eachindex(cases)
    c = cases[i]
    crows[i], _ = solve(c, bills[(c.year, c.scenario.name, float(c.kwp))])
    step!(bar)
end
results = sort(DataFrame(vcat(brows, crows)), [:year, :scenario, :pv_kwp, :battery_kwh])
save_table(DATA, "results", results)
println("\ndone — run summary.jl")
