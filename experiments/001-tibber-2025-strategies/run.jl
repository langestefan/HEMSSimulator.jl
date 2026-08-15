# Battery sizing for a Dutch home on a Tibber-style dynamic tariff, 2025, under two dispatch
# strategies: minimise cost, or minimise grid imports.
#
#     julia --project=. -t auto experiments/001-tibber-2025-strategies/run.jl
#
# **Simulation only.** Everything this produces is a CSV in `data/`; not a single plot is drawn,
# and Makie is never loaded — the package environment is enough. Figures are `figures.jl`, which
# reads those CSVs back, so a figure can be redrawn in seconds without re-solving a year and an
# hour of solver time is never hostage to a typo in an axis label.
#
# Needs ENV["ENTSOE_API_TOKEN"]. Downloads are cached, so a re-run does not re-fetch and does not
# silently drift when ERA5 is reanalysed.

using HEMSSimulator
using DataFrames
using Dates
using Statistics: mean

include(joinpath(@__DIR__, "..", "common.jl"))
include(joinpath(@__DIR__, "run-config.jl"))
const DATA = data_dir(@__FILE__)

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

# No net metering, flat capacity tariff — the regime the Netherlands is moving to, and the regime
# the calibration in `run-config.jl` was read under. Both prices are spot-linked; the sell price is a
# series rather than a constant, which is the whole reason exporting into the evening peak can pay.
contract = Contract(
    YEAR;
    commodity = prices .+ MARKUP,
    feed_in = prices .+ FEED_IN_ADDER,
    energy_tax = ENERGY_TAX,
    net_metering_fraction = 0.0,
    grid = FixedCapacityTariff(),
)

# The car is part of the household in both arms, so what the sweep reports is what the *battery*
# adds on top of a car that was already shifting its own load.
home = HomeSystem(
    site = SITE,
    pv = PV,
    assets = AbstractAsset[ElectricVehicle(
        YEAR;
        capacity_kwh = 60.0,
        charge_power_kw = 11.0,
        kwh_per_day = EV_KWH_PER_WORKDAY,
        weekdays_only = true,
    ),],
)
candidates = [Battery(kwh, kwh / 2; degradation_cost = DEGRADATION) for kwh in CAPACITIES]
investment =
    b ->
        Investment(capex = CAPEX(b.capacity_kwh), lifetime_years = 15, discount_rate = 0.04)

# ---------------------------------------------------------------------------------------------
# The sweep: one row per candidate per strategy.

tables = DataFrame[]
for (name, strategy) in pairs(STRATEGIES)
    println(
        "running ",
        name,
        ": ",
        length(candidates),
        " candidates plus a baseline, ",
        YEAR.n,
        " solves each",
    )
    elapsed = @elapsed table = sweep(
        home,
        weather,
        load,
        contract,
        candidates;
        investment,
        options = OPTIONS(strategy),
    )
    println("  ", round(elapsed / 60, digits = 1), " min")
    insertcols!(table, 1, :strategy => fill(name, nrow(table)))
    save_table(DATA, "sweep-$(name)", table)
    push!(tables, table)
end
comparison = reduce(vcat, tables)
save_table(DATA, "comparison", comparison)

# ---------------------------------------------------------------------------------------------
# The reference home at one battery size, kept in detail so the figures have something to draw and
# the audit something to check. One simulation per strategy, reused for everything below.

reference = with_assets(
    home,
    vcat(
        home.assets,
        [Battery(REFERENCE_KWH, REFERENCE_KWH / 2; degradation_cost = DEGRADATION)],
    ),
)
baselines = DataFrame(
    strategy = Symbol[],
    imported_kwh = Float64[],
    exported_kwh = Float64[],
    annual_bill = Float64[],
    self_sufficiency = Float64[],
)
audit = DataFrame(strategy = Symbol[], intervals = Int[], overlap_kwh = Float64[])

for (name, strategy) in pairs(STRATEGIES)
    options = OPTIONS(strategy)

    # The no-battery case. Both strategies dispatch the car differently, so it is worth recording
    # rather than inferring from the sweep.
    bare = simulate(home, weather, load, contract; options)
    bill = settle(bare, contract)
    push!(
        baselines,
        (
            name,
            bill.imported_kwh,
            bill.exported_kwh,
            annualise(bill),
            self_sufficiency(bare),
        ),
    )

    result = simulate(reference, weather, load, contract; options)

    # Window data for the figures, in the long form `flow_table` and `state_table` produce. Three
    # days is what a dispatch plot can show; a year of 15-minute flows would be a CSV nobody reads.
    for (label, day) in WINDOWS
        save_table(DATA, "flows-$(label)-$(name)", flow_table(result; days = day:(day+2)))
        save_table(DATA, "states-$(label)-$(name)", state_table(result; days = day:(day+2)))
    end

    # 2025 had thousands of negative quarter-hours, and at a negative retail price it becomes
    # *profitable* for the LP to import and export at once — the degeneracy `check_degeneracy`
    # warns about. A meter cannot physically do both, so any interval where it happens is a flow
    # the bill should not trust. Count them rather than take the warnings on faith.
    both = findall(
        k -> result.frame.import_kw[k] > 1e-6 && result.frame.export_kw[k] > 1e-6,
        1:length(result),
    )
    overlap =
        sum(min.(result.frame.import_kw[both], result.frame.export_kw[both]); init = 0.0) *
        hours(YEAR)
    push!(audit, (name, length(both), overlap))

    itemised = bill_components(settle(result, contract))
    save_table(
        DATA,
        "bill-$(name)",
        DataFrame(component = first.(itemised), eur = last.(itemised)),
    )
end

save_table(DATA, "baselines", baselines)
save_table(DATA, "degeneracy-audit", audit)

println("\nsimultaneous import and export, a flow a meter cannot produce:")
println(audit)
println("\nbaselines, no battery:")
println(baselines)
println("\nsweep:")
println(
    select(
        comparison,
        :strategy,
        :capacity_kwh,
        :annual_savings,
        :savings_per_kwh,
        :imported_kwh,
        :npv,
        :cycles_per_year,
    ),
)
println("\nsimulation done — run figures.jl to draw")
