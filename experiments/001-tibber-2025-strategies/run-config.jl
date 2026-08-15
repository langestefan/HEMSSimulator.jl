# Every input to experiment 001, in one place, so `run.jl` and `explore.jl` cannot drift apart.
# If a number matters to the answer it is here, not buried in a default.

using HEMSSimulator
using Dates

const SITE = Site(52.1, 5.18)                       # Utrecht
const YEAR = TimeGrid(DateTime(2025, 1, 1), DateTime(2026, 1, 1))

# Tibber resells the day-ahead price. Fitted against a Tibber app screenshot for 2026-08-14: the
# consumer price is (day-ahead + 0.1121) x 1.21, where 1.21 is VAT. The extrema landed on the same
# quarter-hours and the additive constant agreed to 0.008 ct whether solved from the day's mean, its
# maximum or its minimum — so the *total* below is measured. Its split into supplier markup and
# energiebelasting is a label, not a measurement, and does not affect this study: with net metering
# off, tax is charged on every imported kWh, so only the sum enters the bill.
const TIBBER_ADDITIVE = 0.1121       # EUR/kWh excluding VAT
const ENERGY_TAX = 0.0989            # nominal split
const MARKUP = TIBBER_ADDITIVE - ENERGY_TAX
const FEED_IN = 0.04                 # terugleververgoeding, EUR/kWh

const PV = [PVArray(dc_capacity_kwp = 5.0, ac_capacity_kw = 4.5, tilt = 35, azimuth = 180)]
const HOUSEHOLD_KWH = 3500.0         # base load, excluding the car
const EV_KWH_PER_WORKDAY = 10.0

const CAPACITIES = [2.5, 5.0, 7.5, 10.0, 15.0]
const CAPEX = capacity -> 400 + 400 * capacity      # EUR, installed
const DEGRADATION = 0.02                            # EUR/kWh of throughput, dispatch objective only

# 24 h of perfect foresight, re-optimised every interval — a real MPC controller. Terminal value is
# off deliberately: it exists to stop the horizon emptying storage at a window boundary, but with a
# 15-minute step that boundary is never implemented, so the credit only makes the optimizer hoard.
# Measured on a June week: leaving it on costs about 10% of the savings.
const OPTIONS = (strategy) -> RunOptions(
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
