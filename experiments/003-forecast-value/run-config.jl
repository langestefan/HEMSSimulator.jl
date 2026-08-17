# Every input to experiment 003, in one place.
#
# The question: **how much of a battery's value depends on knowing the future?** Every result in
# experiments 001 and 002 was produced with perfect foresight inside each window. That is the right
# way to measure what an asset is physically worth, and it is an upper bound on what a controller can
# actually deliver. This study measures the gap.

using HEMSSimulator
using Dates
using Printf: @sprintf

include(joinpath(@__DIR__, "..", "tibber.jl"))

const SITE = Site(52.1, 5.18)
const YEAR = TimeGrid(DateTime(2025, 1, 1), DateTime(2026, 1, 1))
const HOUSEHOLD_KWH = 3500.0
const EV_KWH_PER_WORKDAY = 10.0

# The decision grid, narrower than experiment 002's: this study varies foresight, and needs only
# enough of the sizing grid to see whether foresight changes *which battery to buy* as well as what
# it earns.
const PV_KWP = [0.0, 6.0, 12.0]
const BATTERY_KWH = [0.0, 5.0, 10.0, 15.0, 20.0]

const INVERTER_RATIO = 0.9
const DEGRADATION = 0.02
const FIXED_CAPEX = 400.0
const RESULTS_PER_KWH = 400.0
const DISCOUNT_RATE = 0.0
const LIFETIME_YEARS = 15
const RATED_CYCLES = 6000.0
const INVESTMENT =
    capacity -> Investment(
        capex = FIXED_CAPEX + RESULTS_PER_KWH * capacity,
        lifetime_years = LIFETIME_YEARS,
        rated_cycles = RATED_CYCLES,
        discount_rate = DISCOUNT_RATE,
    )

# ---------------------------------------------------------------------------------------------
# The foresight ladder.
#
# `sigma` is the relative error each series reaches at long lead times. Prices are *not* perturbed at
# any level: the Dutch day-ahead auction clears around midday for all of the next day, so at any
# moment prices are known 12 to 36 hours ahead — longer than the window being optimized. Degrading
# them would price information the controller already has.
#
# The two single-source levels matter as much as the combined ones. If the loss comes almost entirely
# from one of weather or load, then "buy a better forecast" has a specific and much cheaper meaning
# than improving both.

const FORECASTS = [
    (name = "perfect", forecast = PerfectForecast()),
    (name = "good", forecast = NoisyForecast(pv_sigma = 0.10, load_sigma = 0.20, seed = 1)),
    (name = "typical", forecast = NoisyForecast(pv_sigma = 0.20, load_sigma = 0.35, seed = 1)),
    (name = "poor", forecast = NoisyForecast(pv_sigma = 0.40, load_sigma = 0.60, seed = 1)),
    # One source at a time, at the "typical" level, to apportion the loss.
    (name = "pv-only", forecast = NoisyForecast(pv_sigma = 0.20, load_sigma = 0.0, seed = 1)),
    (name = "load-only", forecast = NoisyForecast(pv_sigma = 0.0, load_sigma = 0.35, seed = 1)),
]

# ---------------------------------------------------------------------------------------------
# How far ahead the controller plans.
#
# This is the other half of the question and the one a household can actually change. A long window
# needs a long forecast and is exposed to its error; a short one is blind to tonight's peak but
# barely cares what the forecast says. Somewhere between the two is the window that is best *given*
# a forecast of a certain quality — and it is almost certainly not the same window that is best under
# perfect foresight, which is the only case anyone has measured.
const WINDOWS = [6.0, 12.0, 24.0, 48.0]

const OPTIONS =
    (window_hours) -> RunOptions(
        window_hours = window_hours,
        step_hours = 0.25,
        # Off for the same reason as in 002: with a 15-minute step the window end is never
        # implemented, so crediting it only makes the optimizer hoard. It matters more here, because
        # the window length is the thing being varied.
        terminal_value = false,
        strategy = EconomicStrategy(),
    )

home(kwp::Real) = HomeSystem(
    site = SITE,
    pv = kwp > 0 ?
         [PVArray(
        dc_capacity_kwp = kwp,
        ac_capacity_kw = kwp * INVERTER_RATIO,
        tilt = 35,
        azimuth = 180,
    )] : PVArray[],
    assets = AbstractAsset[ElectricVehicle(
        YEAR;
        capacity_kwh = 60.0,
        charge_power_kw = 12.0,
        kwh_per_day = EV_KWH_PER_WORKDAY,
        weekdays_only = true,
    )],
    connection_kw = 17.25,
)

battery(kwh::Real) = Battery(kwh, kwh / 2; degradation_cost = DEGRADATION)

config_name(forecast_name, window_hours, kwp, kwh) = string(
    forecast_name,
    "|w=",
    @sprintf("%04.1f", window_hours),
    "|pv=",
    @sprintf("%04.1f", kwp),
    "|bat=",
    @sprintf("%04.1f", kwh),
)
