"""
    HEMSSimulator

A home energy management system simulator for Dutch households, built on JuMP.

It dispatches a home's controllable assets — battery, electric vehicle, heat pump, hot water tank —
at 15-minute resolution over a year, and bills the result the way a Dutch supplier would. The
headline application is **what battery is worth buying**, under a given tariff and regulatory
scenario, but the dispatch and settlement layers stand on their own.

# How it fits together

```
weather + prices + load
      ↓  prepare
SimulationInputs        exogenous series, computed once
      ↓  simulate       rolling horizon: solve 48 h, keep 24 h, carry state
SimulationResult        every flow, every interval
      ↓  settle         annual netting, energy tax, transport, VAT
Bill
      ↓  kpis / sweep
business case
```

Two separations carry the design. Dispatch and settlement are distinct: the optimizer sees a simple
per-interval price, while the bill — where annual netting (*salderen*) couples the whole year — is
computed afterwards from the flows. And sizing is a sweep of full simulations rather than an
investment variable, so every candidate is judged under the real billing rules.

The rolling horizon exists from the first version so that replacing perfect foresight with a
forecast later means substituting the data sliced into each window, not restructuring the model.
"""
module HEMSSimulator

using CSV: CSV
using DataFrames: DataFrame, DataFrameRow, insertcols!, nrow
using Dates:
    Dates,
    Date,
    DateTime,
    Hour,
    Millisecond,
    Minute,
    Period,
    @dateformat_str,
    dayofweek,
    dayofyear
using ENTSOE: ENTSOE
using HTTP: HTTP
using HiGHS: HiGHS
using JSON: JSON
using LinearAlgebra: LinearAlgebra
using JuMP:
    JuMP,
    AffExpr,
    Model,
    @constraint,
    @objective,
    @variable,
    add_to_expression!,
    is_solved_and_feasible,
    objective_value,
    optimize!,
    set_silent,
    termination_status,
    value
using Printf: @printf
using Random: MersenneTwister
using SHA: sha256
using Scratch: Scratch
using SolarPosition: Observer, solar_position
using Statistics: median

# Include order is significant: each directory only depends on the ones above it.
include("core/timegrid.jl")     # the uniform 15-minute grid everything is aligned to
include("core/resample.jl")     # putting a source series on that grid
include("core/forecast.jl")     # what a controller believes; `RunOptions` carries one
include("core/types.jl")        # asset contract, run options, dispatch context, constants
include("core/progress.jl")     # terminal progress bar for the long-running simulations

include("solar/weather.jl")     # site, weather series, GHI decomposition
include("solar/irradiance.jl")  # angle of incidence, transposition, clear-sky reference
include("solar/pv.jl")          # arrays, cell temperature, DC to AC with clipping
include("solar/resample.jl")    # hourly to 15-minute irradiance through the clearness index

include("building/rc.jl")       # the house as a thermal network

include("assets/battery.jl")    # the first controllable asset
include("assets/ev.jl")         # a car: storage with a departure deadline
include("assets/heatpump.jl")   # storage in the fabric of the building itself
include("assets/dhw.jl")        # the smallest store, facing the sharpest price swing

include("market/tariff.jl")     # contracts and network tariffs
include("market/scenarios.jl")  # the four headline regulatory regimes

include("model/system.jl")      # the home and its precomputed exogenous series
include("model/dispatch.jl")    # the JuMP model for one window
include("model/results.jl")     # what a simulation produces
include("model/rolling.jl")     # the receding-horizon driver
include("model/forecast.jl")    # what the controller believes, as against what happens
include("model/attribution.jl") # where each kWh came from and went

include("market/settlement.jl") # the Dutch bill, computed from the flows
include("market/economics.jl")  # NPV, IRR, payback

include("analysis/sizing.jl")   # the sizing sweep
include("analysis/sizing_lp.jl")# the idealised bound the sweep is checked against

include("io/cache.jl")          # on-disk response cache, so a sweep downloads once
include("io/simcache.jl")       # on-disk simulation cache, so a study solves each case once
include("io/openmeteo.jl")      # ERA5 reanalysis weather
include("io/entsoe.jl")         # day-ahead wholesale prices
include("io/csv.jl")            # measured inputs from a file
include("io/synthetic.jl")      # generators so examples and tests need no data files

include("core/show.jl")
include("plots.jl")         # stubs; the methods live in ext/HEMSSimulatorMakieExt.jl

__init__() = _register_plot_hint()

# Time and weather
export TimeGrid, Site, Weather
export ProgressBar, step!
export hours,
    timestamps, timestamp, window, intervals_per_day, extraterrestrial, decompose, Erbs

# Solar
export AbstractTranspositionModel, Isotropic, HayDavies, Perez
export PVArray, aoi, airmass, poa, sky_diffuse, cell_temperature
export production, annual_yield, solar_positions, observer

# Assets and system
export AbstractAsset, Battery, ElectricVehicle, ev_schedule, ev_energy_kwh
# `continuous`, `discretize` and `nstates` stay unexported: too generic to put in a user's
# namespace, and reachable as `HEMSSimulator.discretize` when needed.
export RCSpec, BuildingSpec, heat_loss_coefficient
export AbstractCOPModel, CarnotCOP, LinearCOP, HeatPump
export thermostat_profile, heat_demand_kwh, discomfort_kh
export WaterTank, dhw_draw, dhw_energy_kwh, dhw_shortfall_kwh, dhw_unserved_kwh
export tank_capacity_kwh, tank_reserve_kwh, WATER_KWH_PER_LITRE_K
export HomeSystem, RunOptions, SimulationInputs
export AbstractStrategy, EconomicStrategy, GreenStrategy, objective_weights
export prepare, with_assets, supports_binary, supports_v2g, initial_state
export add_variables!,
    add_constraints!, power_terms, cost_terms, carry_state, result_columns
export consumption_columns, production_columns

# Simulation
export SimulationResult, simulate, build_window, solve_window
export AbstractForecast, PerfectForecast, NoisyForecast, forecast_window
export imported_kwh, exported_kwh, produced_kwh, consumed_kwh
export self_consumption, self_sufficiency, balance_residual, onsite_sinks, onsite_supply
export energy_flows, solar_use, source_mix

# Tariffs and settlement
export AbstractGridTariff, FixedCapacityTariff, TimeVaryingGridTariff, Contract
export retail_price, export_price, dispatch_prices, Bill, settle, annualise
export NL_TARIFFS_2025, SCENARIO_NAMES, scenarios, peak_intervals, peak_transport_tariff

# Economics and sizing
export Investment, cashflows, npv, irr, payback, kpis, cycles_per_year, effective_lifetime
export sweep, best, best_by_scenario, size_lp, capital_recovery_factor

# Resampling
export AbstractResampler, StepHold, LinearInterp
export resample, source_step, upsample_irradiance

# Data loaders
export openmeteo_weather, openmeteo_url, openmeteo_parse, resample_weather
export entsoe_prices, parse_entsoe_prices
export read_inputs, validate_inputs, INPUT_COLUMNS
export get_cache, set_cache, clear_cache!
export simulation_key, simulation_cache_dir, clear_simulation_cache!

# Plotting (methods require Makie, e.g. `using CairoMakie`)
export dispatch_plot, dispatch_plot!, state_plot, state_plot!, price_plot, price_plot!
export sweep_plot, sweep_plot!, bill_plot, bill_plot!
export dashboard
export hems_theme, StatePanel, state_panels, flow_series, bill_components
export flow_table, state_table
export ASSET_COLOURS,
    SERIES_COLOURS, series_colour, interval_range, Intervals, time_ticks, TIME_TICK_FORMAT
export VRM_COLOURS, PlotTheme, DARK_THEME, LIGHT_THEME, plot_theme

# Synthetic inputs
export synthetic_weather, synthetic_load, synthetic_prices, baseload, clearsky_ghi

end
