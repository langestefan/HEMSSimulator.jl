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

# Installed cost, split into the part that scales with capacity and the part that does not — the
# inverter, the wall bracket, the electrician's day. Splitting it is what lets `capex.jl` sweep the
# cell price without also pretending a 2.5 kWh pack installs itself for a quarter of the cost.
#
# **Capex reaches nothing but the investment arithmetic.** It is absent from the dispatch objective,
# absent from the bill, and absent from the simulation cache key, so changing it re-prices a study
# without re-solving a single window. `capex.jl` sweeps it from 100 to 400 EUR/kWh on exactly that
# basis, and `RESULTS_PER_KWH` is only the value `results.csv` happens to have been written at.
const FIXED_CAPEX = 400.0
const RESULTS_PER_KWH = 400.0
const CAPEX_LADDER = [100.0, 150.0, 200.0, 250.0, 300.0, 350.0, 400.0]
const CAPEX = capacity -> FIXED_CAPEX + RESULTS_PER_KWH * capacity
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
# A full factorial over every factor below would be 4320 runs and, at the throughput this machine
# actually reaches with every core loaded, about 27 hours. So the scenarios are **sampled in waves**
# instead, each wave chosen in the light of what the previous one found.
#
# Waves are cumulative and the whole list is always run. That costs nothing to re-run: every
# simulation is cached by content, so a wave already solved comes back from disk and only the new one
# goes to the solver. Adding a wave is therefore an append here and nothing else.

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

# Wave 1 — one factor at a time. This is what buys the *sensitivity* of the sizing answer to each
# factor, which is the thing the factorial was wanted for, at a fifteenth of the cost.
const WAVE_1 = [
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

# Wave 2 — the interactions wave 1 structurally cannot see, plus the one commute level it skipped.
#
# One-at-a-time answers "how much does this factor matter, on its own". It cannot answer "does a
# slow charger matter *more* when the connection is small", and that is exactly the question a
# household with both would be asking. Each pair here is one wave-1 factor combined with another
# that plausibly reinforces it.
const WAVE_2 = [
    # Completes the commute ladder: 5, 10, 15, 20 kWh per workday.
    scenario("mid-mileage"; ev_kwh_per_day = 15.0),
    # Both limits on charging power at once. A 4 kW charger behind a 9.2 kW connection has almost no
    # room to chase a cheap hour, and the battery is the only thing left that can.
    scenario("slow-charger+small-connection"; ev_charge_kw = 4.0, connection_kw = 9.2),
    # 20 kWh a day through a 4 kW charger is 5 hours of charging that must fit inside the plugged-in
    # window whatever the price does. This is where flexibility runs out.
    scenario("high-mileage+slow-charger"; ev_kwh_per_day = 20.0, ev_charge_kw = 4.0),
    scenario("high-mileage+small-connection"; ev_kwh_per_day = 20.0, connection_kw = 9.2),
    # East-west spreads generation across the day instead of piling it at noon, which should relieve
    # an export cap. Wave 1 shows the cap binding at 12 kWp south; this asks whether the roof layout
    # is a cheaper answer to that than the battery is.
    scenario("east-west+small-connection"; orientation = :east_west, connection_kw = 9.2),
    # The efficiency penalty where the throughput is largest.
    scenario(
        "lossy+high-mileage";
        ev_kwh_per_day = 20.0,
        battery_efficiency = 0.90,
        ev_efficiency = 0.85,
    ),
]

const SCENARIOS = vcat(WAVE_1, WAVE_2)

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
