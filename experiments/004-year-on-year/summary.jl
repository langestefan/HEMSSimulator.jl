# Does 2025 hold up in 2026? Reads data/results.csv; no solver.
#
#     julia --project=. experiments/004-year-on-year/summary.jl

using DataFrames
using Printf: @printf, @sprintf

include(joinpath(@__DIR__, "..", "common.jl"))
include(joinpath(@__DIR__, "run-config.jl"))
const DATA = data_dir(@__FILE__)

r = read_table(DATA, "results")
const NAMES = [s.name for s in SCENARIOS if s.name in r.scenario]
cell(y, s, kwp) = r[(r.year .== y) .& (r.scenario .== s) .& (r.pv_kwp .== kwp) .& (r.battery_kwh .> 0), :]
best(f) = isempty(f) ? nothing : f[argmax(f.npv), :]

println("\n", "="^94)
println("Optimal battery and its NPV, 1 Jan - 15 Aug, by year")
println("(NPV over 15 years on a part-year saving, so levels are low; the comparison is like-for-like)")
println("="^94)
@printf("%-20s", "scenario")
for kwp in PV_KWP, y in YEARS
    @printf("%13s", "$(Int(kwp))kWp $(y-2000)")
end
println()
for s in NAMES
    @printf("%-20s", s)
    for kwp in PV_KWP, y in YEARS
        p = best(cell(y, s, kwp))
        p === nothing ? @printf("%13s", "-") :
        @printf("%13s", @sprintf("%.1f(%.0f)", p.battery_kwh, p.npv))
    end
    println()
end

# The question that matters: does a finding *reverse*, or only move?
println("\n", "="^94)
println("Did the sizing answer move between years? (best kWh, 2025 -> 2026)")
println("="^94)
moved = 0
total = 0
for s in NAMES, kwp in PV_KWP
    a, b = best(cell(2025, s, kwp)), best(cell(2026, s, kwp))
    (a === nothing || b === nothing) && continue
    total += 1
    a.battery_kwh == b.battery_kwh && continue
    moved += 1
    @printf("  %-20s %5s kWp   %.1f -> %.1f kWh   (NPV %.0f -> %.0f)\n",
            s, string(Int(kwp)), a.battery_kwh, b.battery_kwh, a.npv, b.npv)
end
@printf("\n%d of %d (scenario, array) pairs changed their optimal size.\n", moved, total)

println("\n", "="^94)
println("Battery saving at the 2025 optimum, both years — does the ranking of scenarios survive?")
println("="^94)
@printf("%-20s%14s%14s%12s%10s\n", "scenario", "2025 saving", "2026 saving", "change", "%")
for s in NAMES
    a, b = best(cell(2025, s, 6.0)), best(cell(2026, s, 6.0))
    (a === nothing || b === nothing) && continue
    @printf("%-20s%14.0f%14.0f%12.0f%9.0f%%\n", s, a.annual_savings, b.annual_savings,
            b.annual_savings - a.annual_savings,
            100 * (b.annual_savings - a.annual_savings) / a.annual_savings)
end
println()
