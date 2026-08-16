# Every input to experiment 001, in one place, so `run.jl` and `explore.jl` cannot drift apart.
# If a number matters to the answer it is here, not buried in a default.

using HEMSSimulator
using Dates

const SITE = Site(52.1, 5.18)                       # Utrecht
const YEAR = TimeGrid(DateTime(2025, 1, 1), DateTime(2026, 1, 1))

# The tariff calibration lives one directory up, shared with every other study, so two studies
# cannot quietly price the same electricity differently and then be compared.
include(joinpath(@__DIR__, "..", "tibber.jl"))

const PV = [PVArray(dc_capacity_kwp = 5.0, ac_capacity_kw = 4.5, tilt = 35, azimuth = 180)]
const HOUSEHOLD_KWH = 3500.0         # base load, excluding the car
const EV_KWH_PER_WORKDAY = 10.0

const CAPACITIES = [2.5, 5.0, 7.5, 10.0, 15.0]
const CAPEX = capacity -> 400 + 400 * capacity      # EUR, installed
const DEGRADATION = 0.02                            # EUR/kWh of throughput, dispatch objective only

# The discount rate is deliberately **zero**. This study asks what the battery saves, not whether the
# money would have done better somewhere else, so a euro saved in year 15 counts the same as one
# saved in year 1 and the NPV column reduces to *lifetime saving minus what it cost*. The parameter
# stays in place rather than being removed: set it to a real (inflation-excluded) rate to turn the
# same table back into an investment comparison, and `irr` still reports the rate at which the case
# breaks even whatever this is set to.
#
# Zero flatters larger batteries, because their extra saving is spread thinly over all the years
# while their extra capex lands entirely at year zero. Read the sizing optimum with that in mind.
const DISCOUNT_RATE = 0.0
const LIFETIME_YEARS = 15

# Calendar life is not the only thing that ends a battery, and in a sizing sweep the two limits pull
# against each other: a small candidate stores the same daily surplus as a large one, so it cycles
# far more times *per kWh installed* and wears out sooner. Holding the horizon at 15 years for every
# candidate therefore flatters exactly the ones that will need replacing first.
#
# 6000 full-equivalent cycles is a representative warranty for a home LFP pack. Whether it binds is
# an output, not an assumption — `lifetime_years` in the sweep table says which candidates were
# cycle-limited and which ran out of calendar.
const RATED_CYCLES = 6000.0

# One definition for both `run.jl` and `explore.jl`, so the sweep's NPV and the dashboard's NPV card
# cannot quietly disagree.
const INVESTMENT =
    b -> Investment(
        capex = CAPEX(b.capacity_kwh),
        lifetime_years = LIFETIME_YEARS,
        rated_cycles = RATED_CYCLES,
        discount_rate = DISCOUNT_RATE,
    )

# 24 h of perfect foresight, re-optimised every interval — a real MPC controller. Terminal value is
# off deliberately: it exists to stop the horizon emptying storage at a window boundary, but with a
# 15-minute step that boundary is never implemented, so the credit only makes the optimizer hoard.
# Measured on a June week: leaving it on costs about 10% of the savings.
const OPTIONS =
    (strategy) -> RunOptions(
        window_hours = 24,
        step_hours = 0.25,
        terminal_value = false,
        strategy = strategy,
    )

const STRATEGIES = (economic = EconomicStrategy(), green = GreenStrategy())

# The battery kept in detail for the dispatch figures and the degeneracy audit, and the three-day
# windows drawn from it. Day numbers are 1-based within the horizon.
const REFERENCE_KWH = 10.0
const WINDOWS = (("winter", 15), ("spring", 105), ("summer", 190))
