# The interactive dashboard.
#
#     julia --project=@plotenv examples/dashboard.jl
#
# Needs GLMakie and a display — it opens a window. See `examples/plots.jl` for how to set up an
# environment with a Makie backend; plotting is a package extension, so Makie is never a dependency
# of HEMSSimulator itself.
#
# Controls, once the window is up:
#
#   day / width sliders  move the window over the horizon. Free — no resimulation.
#   scenario menu        the four Dutch regulatory regimes.
#   battery menu         the candidate sizes. Each combination simulates once, then caches.
#   toggles              filter the dispatch stack.
#
# The KPI block on the right recomputes for whatever window is on screen.

using HEMSSimulator
using GLMakie
using Dates

site = Site(52.1, 5.18)
grid = TimeGrid(DateTime(2024, 1, 1), DateTime(2024, 4, 1))     # a quarter, so scrubbing has room
weather = synthetic_weather(grid, site; seed = 31)
load = synthetic_load(grid; annual_kwh = 3000)
prices = synthetic_prices(grid; seed = 33)

# A house with a car, a heat pump and a tank already in it. The battery menu adds a candidate on
# top of these, exactly as `sweep` does — so what you are looking at is what the battery adds.
home = HomeSystem(
    site = site,
    pv = [PVArray(dc_capacity_kwp = 4.0, ac_capacity_kw = 3.6, tilt = 35, azimuth = 180)],
    assets = AbstractAsset[
        ElectricVehicle(grid; capacity_kwh = 60.0, charge_power_kw = 11.0, km_per_day = 45),
        HeatPump(grid; building = BuildingSpec(120.0), setpoint = 20.0),
        WaterTank(grid),
    ],
)

regimes = scenarios(grid; commodity = prices .+ 0.02, feed_in = 0.04)
candidates =
    [Battery(kwh, kwh / 2; degradation_cost = 0.05) for kwh in (2.5, 5.0, 10.0, 15.0)]

app = dashboard(home, weather, load, regimes, candidates)

# `dashboard` returns the figure and its widgets, so a script can drive it too — which is how the
# interaction is verified without a human dragging anything.
display(app.figure)

println("dashboard open. Ctrl-C to quit.")
isinteractive() || wait(GLMakie.Screen(app.figure.scene))
