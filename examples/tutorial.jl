# Sizing a home battery — a runnable walkthrough of the whole package.
#
#     julia --project=. examples/tutorial.jl
#
# It runs on synthetic weather and prices, so it needs no data files and no credentials. Every
# number it prints is computed here; swap in `openmeteo_weather` and `entsoe_prices` for measured
# inputs (see the docstrings, and the note at the bottom of this file).

using HEMSSimulator
using DataFrames
using Dates
using Statistics

header(title) = println("\n", "="^78, "\n", title, "\n", "="^78)

# ---------------------------------------------------------------------------------------------
# The home
#
# A home is a location, some PV arrays, and whatever the optimizer controls.

site = Site(52.1, 5.18)                     # Utrecht
grid = TimeGrid(DateTime(2024, 3, 1), DateTime(2024, 4, 1))

home = HomeSystem(
    site = site,
    pv = [PVArray(dc_capacity_kwp = 4.0, ac_capacity_kw = 3.6, tilt = 35, azimuth = 180)],
)

# Azimuth follows the solar convention used by SolarPosition.jl: 0° is north and angles increase
# clockwise, so 180° is south. Several arrays are allowed and each is clipped at its own inverter
# rating — which is why an east/west pair can beat a single south array on a small inverter.

# ---------------------------------------------------------------------------------------------
# Inputs
#
# Weather, base load and wholesale prices. The synthetic generators exist so that examples and
# tests never need an external file; swap in measured data when you have it.

weather = synthetic_weather(grid, site)
load = synthetic_load(grid; annual_kwh = 3500)
prices = synthetic_prices(grid)

header("Inputs")
println("irradiation this month: ", round(sum(weather.ghi) * hours(grid) / 1000, digits = 1),
        " kWh/m²")

# The contract turns wholesale prices into what the household actually pays and receives.

contract = Contract(
    grid;
    commodity = prices .+ 0.02,        # supplier markup, €/kWh
    feed_in = 0.04,                    # terugleververgoeding, €/kWh
    net_metering_fraction = 1.0,       # full salderen
)

# ---------------------------------------------------------------------------------------------
# Simulating
#
# `simulate` runs a receding horizon: each solve optimizes 48 hours with perfect foresight, keeps
# the first 24, carries the asset states forward and advances. The overlap is what stops the
# optimizer emptying storage at every boundary — and it is the structure a forecast model plugs
# into later, because switching off perfect foresight means changing the data sliced into each
# window, not the loop.

result = simulate(home, weather, load, contract)

header("Simulating")
println(result)
println()
println(first(select(result.frame, :timestamp, :load_kw, :pv_available_kw, :import_kw, :export_kw), 4))

# ---------------------------------------------------------------------------------------------
# Billing
#
# Dispatch and settlement are deliberately separate. The optimizer sees a simple per-interval
# price; the bill is computed afterwards from the flows, because annual netting couples the whole
# year and no receding-horizon objective can represent it.

header("Billing")
println(settle(result, contract))

# Turning off net metering is a change to the contract, not to any code path. The same parameter
# expresses a phase-out: `net_metering_fraction = 0.36` is a year in which just over a third of
# exported energy is still netted.

without_netting = Contract(
    grid;
    commodity = prices .+ 0.02,
    feed_in = 0.04,
    net_metering_fraction = 0.0,
)
println()
println(settle(simulate(home, weather, load, without_netting), without_netting))

# ---------------------------------------------------------------------------------------------
# The four scenarios
#
# A Dutch household faces two policy questions at once — whether annual netting still applies, and
# whether transport is billed as a flat capacity charge or by time of use. `scenarios` builds all
# four combinations from one set of prices.
#
# The axes are not two versions of the same lever. Netting absorbs the commodity price and the
# energy tax; transport is charged on *physical* flow and is never netted. So a time-of-use tariff
# pays a battery whether or not netting applies, while ending netting changes what an exported kWh
# is worth at all.
#
# Defaults for tax, the tax credit and VAT come from `NL_TARIFFS_2025` — read its docstring before
# quoting any of the numbers below, because two of those figures are representative rather than
# published.

regimes = scenarios(grid; commodity = prices .+ 0.02, feed_in = 0.04)

header("The four scenarios")
println(keys(regimes))

# ---------------------------------------------------------------------------------------------
# A bound before you sweep
#
# A sweep costs one full simulation per candidate, so it helps to know roughly where to look
# first. `size_lp` makes capacity and power continuous variables in a single linear program over
# the whole horizon.
#
# Treat it as a reference point, not an answer. It is optimistic in three specific ways: perfect
# foresight over the entire horizon rather than 48 hours, the linear dispatch price rather than
# the bill — annual netting cannot be written into its objective, which is the whole reason
# `settle` exists — and continuous sizing, while batteries come in fixed sizes.
#
# `c_rate` ties power to capacity at 0.5 by default, matching how the candidates below are built.
# Without it, and with power unpriced, the LP answers with a tiny very fast battery nobody sells.
#
# One trap: leave the template's `degradation_cost` at zero when comparing against a sweep. It is
# a control-shaping term that appears in the dispatch objective but never in a `Bill`, so charging
# it here and not there makes the LP under-size. Wear belongs in `Investment`.

header("A bound before you sweep")
println(size_lp(home, weather, load, without_netting; capex_per_kwh = 450.0, capex_fixed = 1000.0))

# ---------------------------------------------------------------------------------------------
# Sizing the battery
#
# Sizing is done by simulating each candidate rather than by making capacity a decision variable.
# That costs more solves, but every candidate is then judged under the real billing rules —
# including the annual netting cap, which an investment LP cannot see.

candidates = [Battery(kwh, kwh / 2; degradation_cost = 0.05) for kwh in 2.5:2.5:15.0]
investment =
    b -> Investment(
        capex = 1000 + 450 * b.capacity_kwh,
        lifetime_years = 15,
        discount_rate = 0.04,
    )

table = sweep(home, weather, load, without_netting, candidates; investment)

header("Sizing the battery")
println(select(table, :capacity_kwh, :annual_savings, :npv, :payback_years, :cycles_per_year))

# `best` returns the winning row and warns when the optimum sits at the edge of the candidate
# range, which usually means the range did not bracket it. Over a full year with these assumptions
# the optimum lands around 5 kWh at roughly a 9-year payback; a month is not a year, so treat these
# numbers as a demonstration of the mechanics.
println("\noptimum: ", best(table).capacity_kwh, " kWh")

# ---------------------------------------------------------------------------------------------
# Sizing across all four scenarios
#
# Pass the whole scenario set instead of one contract and the sweep stacks a block per regime.
# Each is simulated independently, because the contract changes the price signal the controller
# sees and therefore the flows — not just the bill computed from them.

across = sweep(
    home,
    weather,
    load,
    regimes,
    [Battery(kwh, kwh / 2; degradation_cost = 0.05) for kwh in 2.5:2.5:10.0];
    investment,
)

header("Sizing across all four scenarios")
println(select(across, :scenario, :capacity_kwh, :annual_savings, :npv))

# `best_by_scenario` picks the winner within each regime — use it rather than `best` on a stacked
# table, which would return the single globally best row and say nothing about the others.
#
# That table is the deliverable. What a battery is worth is not one number but four, and on the
# package's own synthetic data they differ by more than any single modelling assumption in it.
println()
println(select(best_by_scenario(across), :scenario, :capacity_kwh, :annual_savings, :payback_years))

# ---------------------------------------------------------------------------------------------
# Adding a car
#
# An EV is not a second battery. It is away when the sun is up on exactly the days its owner
# commutes, it must be full enough to leave in the morning, and unless V2G is switched on the
# energy that goes into it never comes back out to the house.

ev = ElectricVehicle(
    grid;
    capacity_kwh = 60.0,
    charge_power_kw = 11.0,
    km_per_day = 45,          # or kwh_per_day, or a function of the Date
    departure_hour = 7.5,
    return_hour = 17.5,
    target_soc = 0.8,         # required before each departure
)

with_car = HomeSystem(site = site, pv = home.pv, assets = [ev])
car_run = simulate(with_car, weather, load, without_netting)

header("Adding a car")
println("driven  ", round(sum(ev.trip_kwh), digits = 1), " kWh")
println("charged ", round(ev_energy_kwh(car_run), digits = 1), " kWh")

# The charging is flexible; the departure is not. That is the whole reason to model a car rather
# than adding its consumption to the base load — the optimizer moves the charging to the cheap
# hours, but only within the window before each deadline.

paid = sum(car_run.frame.ev_charge_kw .* car_run.frame.price_buy) / sum(car_run.frame.ev_charge_kw)
println("paid ", round(paid, digits = 4), " €/kWh against an average of ",
        round(mean(car_run.frame.price_buy[ev.connected]), digits = 4), " while plugged in")

# Sizing a battery for this home keeps the car in both arms of the comparison, so what is reported
# is what the battery adds on top of a car that was already shifting its own load.
#
# Compare that column of savings against the one without a car. On its own a battery saturates —
# past a point there is no more PV surplus or price spread for extra capacity to capture. The car
# is a large shiftable load that keeps the marginal kWh of storage earning, so the savings keep
# climbing. Sizing for a household that is about to buy an EV, without modelling the EV,
# understates what the larger battery would do.

println()
println(select(
    sweep(with_car, weather, load, without_netting, candidates; investment),
    :capacity_kwh, :annual_savings, :npv,
))

# ---------------------------------------------------------------------------------------------
# Heating the house
#
# A battery stores kWh. A house stores °C, in mass that is already there and paid for. That makes
# the heat pump the asset the receding horizon earns its keep on — but only if the model has
# somewhere to put the heat, which is what the RC network is for.
#
# `BuildingSpec` derives the resistances and capacities from two figures a homeowner actually has:
# floor area, and heat loss at the design outdoor temperature. Those are rules of thumb, not a
# fitted model; pass your own parameters to the keyword form if you have them.

building = BuildingSpec(120.0; heat_loss_kw = 6.0)     # 120 m², 6 kW at ΔT = 30 K

header("Heating the house")
println("conductance ", round(heat_loss_coefficient(building), digits = 3), " kW/K,  envelope ",
        round(building.C_e, digits = 1), " kWh/K")

# The flexibility is the comfort band. Inside `setpoint ± band` the optimizer may put the
# temperature wherever it likes, so it can warm the fabric through a cheap mild afternoon and coast
# through the evening peak.

heated(mode) = simulate(
    HomeSystem(
        site = site,
        pv = home.pv,
        assets = [
            HeatPump(
                grid;
                building,
                setpoint = 20.0,
                band = 1.0,
                max_power_kw = 4.0,
                control = mode,
            ),
        ],
    ),
    weather,
    load,
    without_netting,
)

smart = heated(:optimized)
dumb = heated(:thermostat)
cost(run) = sum(run.frame.heatpump_kw .* run.frame.price_buy) * hours(grid)

println("thermostat ", round(heat_demand_kwh(dumb), digits = 1), " kWh for €",
        round(cost(dumb), digits = 2))
println("optimized  ", round(heat_demand_kwh(smart), digits = 1), " kWh for €",
        round(cost(smart), digits = 2))

# Over this March the optimizer buys about 8% fewer kWh and pays about 24% less for them. The two
# effects are separable and both real: it heats when the COP is better, and it heats when
# electricity is cheap. Neither is available to a controller that only knows the current indoor
# temperature.
#
# The thermostat also overshoots, because the emitter keeps giving off heat after it switches off —
# the lag the third RC node exists to represent.

println("thermostat holds ", round.(extrema(dumb.frame.indoor_temp), digits = 2), " °C")
println("optimized  holds ", round.(extrema(smart.frame.indoor_temp), digits = 2), " °C")

# The band is *soft*, and asymmetric. Falling below it is discomfort and is priced at
# `comfort_penalty`; rising above it costs an order of magnitude less, because a house coasting
# down to a night setback is above its band and nobody minds. `discomfort_kh` reports the two sides
# separately, and an undersized heat pump in a cold snap therefore returns a number of degree-hours
# rather than INFEASIBLE.
#
# A night setback is a change to the setpoint, not to the model.

setback = [(Dates.hour(t) >= 23 || Dates.hour(t) < 6) ? 17.0 : 20.0 for t in timestamps(grid)]
night = simulate(
    HomeSystem(
        site = site,
        pv = home.pv,
        assets = [
            HeatPump(grid; building, setpoint = setback, band = 1.0, max_power_kw = 4.0),
        ],
    ),
    weather,
    load,
    without_netting,
)

println("steady  ", round(heat_demand_kwh(smart), digits = 1), " kWh")
println("setback ", round(heat_demand_kwh(night), digits = 1), " kWh, ",
        round(discomfort_kh(night; side = :cold), digits = 3), " cold degree-hours")

# ---------------------------------------------------------------------------------------------
# Hot water
#
# The tank is the smallest store in the house and the one with the least freedom: a few kWh, drawn
# twice a day at times set by human habit rather than by price. It earns its place because its heat
# is the most expensive in the building — reaching 60 °C instead of the 40 °C a radiator needs
# roughly halves the COP.

tank = WaterTank(grid; litres_per_day = 120.0)
tank_run = simulate(
    HomeSystem(site = site, pv = home.pv, assets = [tank]),
    weather,
    load,
    without_netting,
)

header("Hot water")
println("capacity  ", round(tank_capacity_kwh(tank), digits = 2), " kWh")
println("drawn     ", round(sum(tank.draw_kwh), digits = 1), " kWh of heat")
println("bought    ", round(dhw_energy_kwh(tank_run), digits = 1), " kWh of electricity")
println("shortfall ", round(dhw_shortfall_kwh(tank_run), digits = 3), " kWh")

# The gap between the heat drawn and the electricity bought is the COP; the gap between heat *in*
# and heat drawn is standing loss. And as with the car, the flexibility shows up in what it pays.

println("paid ", round(sum(tank_run.frame.dhw_kw .* tank_run.frame.price_buy) /
                       sum(tank_run.frame.dhw_kw), digits = 4),
        " €/kWh against an average of ", round(mean(tank_run.frame.price_buy), digits = 4))

# `dhw_draw` builds the profile — two Gaussian peaks and a trickle — and you can pass your own
# series instead. The same type models a resistive immersion tank with
# `cop_model = LinearCOP(reference = 1.0, slope = 0.0, cop_min = 1.0)`; mind that `cop_min`,
# because the COP models clamp at 1.5 by default and would otherwise turn your element into a poor
# heat pump.
#
# Two failure modes are reported separately, because they are not equally bad.
# `dhw_shortfall_kwh` is water delivered below the minimum temperature — a lukewarm shower.
# `dhw_unserved_kwh` is water not delivered at all. Without that second term an empty tank would
# make the window infeasible rather than telling you the household went without.

# ---------------------------------------------------------------------------------------------
# Things worth knowing
#
# **Negative prices break the linear program.** The LP avoids charging and discharging at once only
# because wasting energy costs money. When prices go negative — routine on the Dutch market —
# burning energy becomes profitable and the LP will cycle storage to dump kWh.
# `RunOptions(check_degeneracy = true)` (the default) warns when this happens;
# `RunOptions(exclusive = true)` adds the binaries that fix it, at the cost of a slower solve.
#
# **Under full salderen a battery arbitrages the retail price, tax included.** That makes storage
# look extremely attractive and drives very high cycle counts. Set `degradation_cost` on the
# battery to make the optimizer trade cycling against margin, and check `cycles_per_year` against
# what the warranty allows.
#
# **Self-consumption is attributed per interval**, as `min(PV, on-site demand)`. Once a battery can
# export energy it charged from the grid, total export stops being a proxy for un-consumed PV.
#
# **Measured inputs** replace the three synthetic series and nothing else:
#
#     weather = openmeteo_weather(site, grid)              # ERA5 reanalysis, cached on disk
#     prices  = entsoe_prices(grid)                        # day-ahead, €/kWh
#     inputs  = read_inputs("home.csv", grid, site)        # or your own file
#
# Open-Meteo stamps radiation at the *end* of its hour while stamping temperature instantaneously,
# and defaults wind to km/h; the loader handles both. Its annual irradiation for Utrecht tracks
# KNMI, but its diffuse fraction is about 0.41 against the ~0.55 of ground measurements, so a
# south-facing 35° array models near 1090 kWh/kWp — the top of the usual 900–1000 range. Treat it
# as an optimistic case and size against a range.
