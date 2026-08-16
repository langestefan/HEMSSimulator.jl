# Every input to experiment 002, in one place, so `run.jl` and anything that reads its output cannot
# drift apart. If a number matters to the answer it is here, not buried in a default.

using HEMSSimulator
using Dates
using Printf: @sprintf

# The tariff calibration is shared with experiment 001 — same supplier, same year, same regime.
include(joinpath(@__DIR__, "..", "tibber.jl"))

const SITE = Site(52.1, 5.18)                       # Utrecht
const YEAR = TimeGrid(DateTime(2025, 1, 1), DateTime(2026, 1, 1))
const HOUSEHOLD_KWH = 3500.0         # base load, excluding the car

# ---------------------------------------------------------------------------------------------
# Decisions: what the household actually chooses to buy.
#
# These two vary *within* every scenario, because they are the question. Everything else varies
# across scenarios, because it is context.

const PV_KWP = [0.0, 3.0, 6.0, 9.0, 12.0]
const BATTERY_KWH = [0.0, 2.5, 5.0, 7.5, 10.0, 12.5, 15.0, 20.0, 25.0, 30.0]

# All candidates are two-hour batteries, so power scales with capacity the way home products do.
const BATTERY_HOURS = 2.0
const INVERTER_RATIO = 0.9           # AC rating as a fraction of DC, typical for a NL rooftop

const DEGRADATION = 0.02             # EUR/kWh of throughput, dispatch objective only
const CAPEX = capacity -> 400 + 400 * capacity      # EUR, installed
const DISCOUNT_RATE = 0.0            # see 001: this study asks what is saved, not what it could earn
const LIFETIME_YEARS = 15
const RATED_CYCLES = 6000.0          # a representative home-LFP warranty; whether it binds is output

const INVESTMENT =
    capacity -> Investment(
        capex = CAPEX(capacity),
        lifetime_years = LIFETIME_YEARS,
        rated_cycles = RATED_CYCLES,
        discount_rate = DISCOUNT_RATE,
    )

# PV capex is deliberately absent. Every candidate battery is compared against the *same* home with
# the *same* array and no battery, so the cost of the panels cancels out of `annual_savings` and out
# of the NPV. This table says what a battery is worth given an array, not whether the array was worth
# buying.

# ---------------------------------------------------------------------------------------------
# Scenarios: the context the decision is made in.
#
# A full factorial over every factor below would be 4320 runs and most of a day. These eight are
# one-at-a-time deviations from a single base case, which buys the *sensitivity* of the sizing
# answer to each factor — the thing the factorial was wanted for — at a fifteenth of the cost. What
# it does not buy is interactions: this design cannot see whether a slow charger matters *more* on a
# small connection. Where a scenario moves the optimum a long way, that pair is worth a follow-up
# grid of its own.

const BASE_CASE = (;
    orientation = :south,            # :south, or :east_west split across two roof faces
    ev_kwh_per_day = 10.0,           # on workdays only
    ev_charge_kw = 12.0,
    connection_kw = 17.25,           # 3x25 A at 230 V. Single phase is not modelled: this is the
    #                                  total power available, which is what the LP needs.
    battery_efficiency = 0.95,       # one-way, so 0.9025 round trip
    ev_efficiency = 0.92,
)

scenario(name; kwargs...) = merge((; name = name), BASE_CASE, NamedTuple(kwargs))

const SCENARIOS = [
    scenario("base"),
    # Azimuth alone: tilt stays at 35 degrees so the comparison isolates orientation. A real
    # east-west system is usually laid flatter than that, which would flatter it slightly.
    scenario("east-west"; orientation = :east_west),
    scenario("low-mileage"; ev_kwh_per_day = 5.0),
    scenario("high-mileage"; ev_kwh_per_day = 20.0),
    scenario("slow-charger"; ev_charge_kw = 4.0),
    scenario("small-connection"; connection_kw = 9.2),   # 1x40 A at 230 V
    scenario("lossy"; battery_efficiency = 0.90, ev_efficiency = 0.85),
    scenario("efficient"; battery_efficiency = 0.975, ev_efficiency = 0.95),
]

# ---------------------------------------------------------------------------------------------
# The controller, identical to experiment 001 so the two studies are comparable.
#
# 24 h of perfect foresight, re-optimised every interval — a real MPC controller. Terminal value is
# off deliberately: it exists to stop the horizon emptying storage at a window boundary, but with a
# 15-minute step that boundary is never implemented, so the credit only makes the optimizer hoard.

const OPTIONS = RunOptions(
    window_hours = 24,
    step_hours = 0.25,
    terminal_value = false,
    strategy = EconomicStrategy(),
)

# ---------------------------------------------------------------------------------------------
# Building the home a configuration describes.

function arrays(kwp::Real, orientation::Symbol)
    kwp > 0 || return PVArray[]
    ac(dc) = dc * INVERTER_RATIO
    orientation === :south && return [
        PVArray(dc_capacity_kwp = kwp, ac_capacity_kw = ac(kwp), tilt = 35, azimuth = 180),
    ]
    orientation === :east_west && return [
        PVArray(
            dc_capacity_kwp = kwp / 2,
            ac_capacity_kw = ac(kwp / 2),
            tilt = 35,
            azimuth = azimuth,
        ) for azimuth in (90, 270)
    ]
    throw(ArgumentError("unknown orientation $orientation"))
end

function home(scenario, kwp::Real; grid::TimeGrid = YEAR)
    car = ElectricVehicle(
        grid;
        capacity_kwh = 60.0,
        charge_power_kw = scenario.ev_charge_kw,
        kwh_per_day = scenario.ev_kwh_per_day,
        weekdays_only = true,
        charge_efficiency = scenario.ev_efficiency,
        discharge_efficiency = scenario.ev_efficiency,
    )
    return HomeSystem(
        site = SITE,
        pv = arrays(kwp, scenario.orientation),
        assets = AbstractAsset[car],
        connection_kw = scenario.connection_kw,
    )
end

battery(scenario, kwh::Real) = Battery(
    kwh,
    kwh / BATTERY_HOURS;
    charge_efficiency = scenario.battery_efficiency,
    discharge_efficiency = scenario.battery_efficiency,
    degradation_cost = DEGRADATION,
)

# One name per configuration: the row key of the results table, and the line written to `solved.txt`
# as each one finishes. Zero-padded so a sort is a sort. Resuming a crashed run does not read these
# back — the simulation cache does that, keyed by the run's actual content rather than by a label.
config_name(scenario, kwp, kwh) =
    string(scenario.name, "|pv=", @sprintf("%04.1f", kwp), "|bat=", @sprintf("%04.1f", kwh))
