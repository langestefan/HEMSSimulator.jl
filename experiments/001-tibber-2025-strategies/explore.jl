# The same study as `run.jl`, opened in the interactive dashboard instead of written to disk.
#
#     julia --project=examples -t auto experiments/001-tibber-2025-strategies/explore.jl
#
# Needs GLMakie and a display. It does **not** need a network or an ENTSO-E token: every input
# comes from `data/inputs.csv`, which `run.jl` wrote — so this explores exactly the run that
# produced the committed results, not a fresh download that might differ.
#
# The strategy menu is the point: pick a battery, then flip between economic and green on the same
# week and watch the dispatch stack change. The economic controller charges from the grid overnight;
# the green one never does, because importing to store can only add to the import it is minimising.
#
# Each (scenario, battery, strategy) combination simulates once on first selection and is then
# cached, so the first click on a new combination costs a few minutes of solves and every later one
# is instant. Scrubbing the window is always free.

using HEMSSimulator
using GLMakie
using Dates

include(joinpath(@__DIR__, "..", "common.jl"))
include(joinpath(@__DIR__, "run-config.jl"))

inputs = load_inputs(data_dir(@__FILE__))
grid, weather, prices, load = inputs.grid, inputs.weather, inputs.prices, inputs.load

contract = Contract(
    grid;
    commodity = prices .+ MARKUP,
    feed_in = FEED_IN,
    energy_tax = ENERGY_TAX,
    net_metering_fraction = 0.0,
    grid = FixedCapacityTariff(),
)

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

app = dashboard(
    home,
    weather,
    load,
    contract,
    [Battery(kwh, kwh / 2; degradation_cost = DEGRADATION) for kwh in CAPACITIES];
    options = OPTIONS(EconomicStrategy()),
    strategies = STRATEGIES,
)

display(app.figure)
println(
    "dashboard open — first selection of each combination runs a year of solves. Ctrl-C to quit.",
)
isinteractive() || wait(GLMakie.Screen(app.figure.scene))
