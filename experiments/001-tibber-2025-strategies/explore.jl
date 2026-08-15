# The same study as `run.jl`, opened in the interactive dashboard instead of written to disk.
#
#     julia --project=examples -t auto experiments/001-tibber-2025-strategies/explore.jl
#
# Needs GLMakie and a display. It does **not** need a network or an ENTSO-E token: every input
# comes from `data/inputs.csv`, which `run.jl` wrote — so this explores exactly the run that
# produced the committed results, not a fresh download that might differ.
#
# The layout follows Victron's VRM portal: prices on top, the energy stack below, asset states under
# that, and the window's totals on cards along the bottom. The **theme** menu switches dark to light
# — dark uses VRM's own colours, light the colour-blind-safe ones, so screenshot from light if the
# picture is going to someone else.
#
# The strategy menu is the point: pick a battery, then flip between economic and green on the same
# week and watch the dispatch stack change. The economic controller charges from the grid overnight;
# the green one never does, because importing to store can only add to the import it is minimising.
#
# All ten (scenario, battery, strategy) combinations are simulated before the window opens, threaded
# — so **start Julia with `-t auto`**, or they run one at a time. That is several minutes of staring
# at a terminal, and it is the right trade: a solve started from a menu click would run on the thread
# that draws, freezing the window until it finished. Once the window is up, every menu and every
# slider is instant.

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
    feed_in = feed_in_price(prices),
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
    investment = b -> Investment(
        capex = CAPEX(b.capacity_kwh),
        lifetime_years = 15,
        discount_rate = 0.04,
    ),
)

display(app.figure)
println(
    "dashboard open — first selection of each combination runs a year of solves. Ctrl-C to quit.",
)
isinteractive() || wait(GLMakie.Screen(app.figure.scene))
