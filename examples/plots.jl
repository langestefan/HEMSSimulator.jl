# Every plot the package provides, rendered to PNG.
#
# Needs a Makie backend, which is deliberately *not* a dependency of the package or of its test
# environment — the Makie stack takes about three minutes to precompile and CI should not pay that.
# Set up an environment for it once:
#
#     julia -e 'using Pkg; Pkg.activate("plotenv"; shared = true);
#               Pkg.develop(path = "."); Pkg.add("GLMakie")'
#     julia --project=@plotenv examples/plots.jl figs/
#
# GLMakie needs a GPU and a display. On a headless box swap it for CairoMakie — the extension is on
# `Makie`, so nothing else changes.
#
# This script is also the smoke test for the Makie extension. There are no automated plotting tests,
# so if you change `src/plots.jl` or `ext/HEMSSimulatorMakieExt.jl`, run this and look at the output.

using HEMSSimulator
using GLMakie
using Dates

output = isempty(ARGS) ? mktempdir(; cleanup = false) : ARGS[1]
mkpath(output)

# A fortnight in January with every asset the package has, so each plot has something to show.
site = Site(52.1, 5.18)
grid = TimeGrid(DateTime(2024, 1, 8), 96 * 14)
weather = synthetic_weather(grid, site; seed = 31)
load = synthetic_load(grid; annual_kwh = 3000)
prices = synthetic_prices(grid; seed = 33)
pv = [PVArray(dc_capacity_kwp = 4.0, ac_capacity_kw = 3.6, tilt = 35, azimuth = 180)]
contract =
    Contract(grid; commodity = prices .+ 0.02, feed_in = 0.04, net_metering_fraction = 0.0)

full_house = HomeSystem(
    site = site,
    pv = pv,
    assets = AbstractAsset[
        Battery(10.0, 5.0; degradation_cost = 0.05),
        ElectricVehicle(grid; capacity_kwh = 60.0, charge_power_kw = 11.0, km_per_day = 45),
        HeatPump(grid; building = BuildingSpec(120.0), setpoint = 20.0),
        WaterTank(grid),
    ],
)
result = simulate(full_house, weather, load, contract)
println("meter balance residual: ", maximum(abs, balance_residual(result)))

# Dispatch. Sources stack up, sinks stack down, so the balance is visible as symmetry. Which series
# exist comes from the assets themselves — add a fifth asset and it appears here unaided.
save(joinpath(output, "dispatch.png"), dispatch_plot(result; days = 1:3))

# The same over the whole fortnight. Past `PLOT_MAX_POINTS` the series are averaged into blocks and
# the axis label says so, rather than drawing 35 000 unreadable points.
save(joinpath(output, "dispatch-fortnight.png"), dispatch_plot(result; days = :))

# State, one panel per stored quantity against the limits it has to respect: SoC bounds, the EV's
# departure targets and away periods, the comfort band, the tank's reserve. This is the picture of
# what the integration tests assert numerically.
save(joinpath(output, "state.png"), state_plot(result; days = 1:3))

# The business case. A filled marker is an interior optimum; a hollow one sits at the edge of the
# candidate range, which means the range did not bracket it.
bare = HomeSystem(site = site, pv = pv)
candidates = [Battery(kwh, kwh / 2; degradation_cost = 0.05) for kwh = 2.5:2.5:15.0]
investment = b -> Investment(capex = 1000 + 450 * b.capacity_kwh)
table = sweep(bare, weather, load, contract, candidates; investment)
save(joinpath(output, "sweep.png"), sweep_plot(table))

# One series per regulatory scenario — the comparison the four scenarios exist to make.
regimes = scenarios(grid; commodity = prices .+ 0.02, feed_in = 0.04)
save(
    joinpath(output, "sweep-scenarios.png"),
    sweep_plot(sweep(bare, weather, load, regimes, candidates[1:4]; investment)),
)

# The bill as a waterfall, with ticks showing where each component sat without the battery.
baseline = settle(simulate(bare, weather, load, contract), contract)
with_battery = settle(
    simulate(
        HomeSystem(site = site, pv = pv, assets = [Battery(10.0, 5.0)]),
        weather,
        load,
        contract,
    ),
    contract,
)
save(joinpath(output, "bill.png"), bill_plot(with_battery; baseline))

# The theme is opt-in and nothing applies it for you.
set_theme!(hems_theme())
save(joinpath(output, "sweep-themed.png"), sweep_plot(table))
set_theme!()

println("wrote ", length(readdir(output)), " figures to ", output)
