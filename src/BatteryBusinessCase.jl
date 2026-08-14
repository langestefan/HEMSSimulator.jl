"""
    BatteryBusinessCase

A home energy management system simulator for Dutch households, built on JuMP.

The package answers one question well: **what battery is worth buying**. It dispatches a home's
assets at 15-minute resolution over a year, bills the result the way a Dutch supplier would, and
tabulates the business case across candidate battery sizes.

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
module BatteryBusinessCase

using CSV: CSV
using DataFrames: DataFrame, DataFrameRow, nrow
using Dates: Dates, Date, DateTime, Hour, Millisecond, Minute, Period, dayofweek, dayofyear
using ENTSOE: ENTSOE
using HTTP: HTTP
using HiGHS: HiGHS
using JSON: JSON
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
include("core/types.jl")        # asset contract, run options, dispatch context, constants

include("solar/weather.jl")     # site, weather series, GHI decomposition
include("solar/irradiance.jl")  # angle of incidence, transposition, clear-sky reference
include("solar/pv.jl")          # arrays, cell temperature, DC to AC with clipping
include("solar/resample.jl")    # hourly to 15-minute irradiance through the clearness index

include("assets/battery.jl")    # the first controllable asset

include("market/tariff.jl")     # contracts and network tariffs

include("model/system.jl")      # the home and its precomputed exogenous series
include("model/dispatch.jl")    # the JuMP model for one window
include("model/results.jl")     # what a simulation produces
include("model/rolling.jl")     # the receding-horizon driver

include("market/settlement.jl") # the Dutch bill, computed from the flows
include("market/economics.jl")  # NPV, IRR, payback

include("analysis/sizing.jl")   # the sizing sweep

include("io/cache.jl")          # on-disk response cache, so a sweep downloads once
include("io/openmeteo.jl")      # ERA5 reanalysis weather
include("io/entsoe.jl")         # day-ahead wholesale prices
include("io/csv.jl")            # measured inputs from a file
include("io/synthetic.jl")      # generators so examples and tests need no data files

include("core/show.jl")

# Time and weather
export TimeGrid, Site, Weather
export hours,
    timestamps, timestamp, window, intervals_per_day, extraterrestrial, decompose, Erbs

# Solar
export AbstractTranspositionModel, Isotropic, HayDavies, Perez
export PVArray, aoi, airmass, poa, sky_diffuse, cell_temperature
export production, annual_yield, solar_positions, observer

# Assets and system
export AbstractAsset, Battery, HomeSystem, RunOptions, SimulationInputs
export prepare, with_assets, supports_binary, supports_v2g, initial_state
export add_variables!,
    add_constraints!, power_terms, cost_terms, carry_state, result_columns

# Simulation
export SimulationResult, simulate, build_window, solve_window
export imported_kwh, exported_kwh, produced_kwh, consumed_kwh
export self_consumption, self_sufficiency, balance_residual, onsite_sinks, onsite_supply

# Tariffs and settlement
export AbstractGridTariff, FixedCapacityTariff, TimeVaryingGridTariff, Contract
export retail_price, export_price, dispatch_prices, Bill, settle, annualise

# Economics and sizing
export Investment, cashflows, npv, irr, payback, kpis, cycles_per_year, sweep, best

# Resampling
export AbstractResampler, StepHold, LinearInterp
export resample, source_step, upsample_irradiance

# Data loaders
export openmeteo_weather, openmeteo_url, openmeteo_parse, resample_weather
export entsoe_prices, parse_entsoe_prices
export read_inputs, validate_inputs, INPUT_COLUMNS
export get_cache, set_cache, clear_cache!

# Synthetic inputs
export synthetic_weather, synthetic_load, synthetic_prices, clearsky_ghi

end
