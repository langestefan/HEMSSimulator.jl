# Every input to experiment 001, in one place, so `run.jl` and `explore.jl` cannot drift apart.
# If a number matters to the answer it is here, not buried in a default.

using HEMSSimulator
using Dates

const SITE = Site(52.1, 5.18)                       # Utrecht
const YEAR = TimeGrid(DateTime(2025, 1, 1), DateTime(2026, 1, 1))

# Both consumer prices are calibrated against a VRM "Energy prices" panel for 2026-08-14, read with
# net metering off, and against the *fetched* ENTSO-E day-ahead prices for the same day rather than
# an assumed series. The anchor is VRM's own tooltip, which gives an exact pair for one hour:
#
#     local 20:00-20:59  buy EUR 0.4753   sell EUR 0.2881
#     ENTSO-E mean for that hour (UTC 18:00-19:00)      EUR 0.26279 / kWh
#
#     buy  = (day-ahead + 0.13002) * 1.21      1.21 being VAT
#     sell =  day-ahead + 0.02531
#
# VRM plots local time and this package works in UTC throughout, so the hour had to be shifted by
# CEST's +2 before comparing; without that the fit is out by two hours and looks like noise.
#
# Reading the other 23 steps off the chart supports both constants (the five clearest hours give buy
# additives of 0.1299-0.1316) but cannot refine them: a step chart read from a screenshot carries
# about an hour of assignment error, which in the steep 15:00-19:00 stretch swamps the constant being
# fitted. One exact pair beats twenty-four approximate ones, so these come from the tooltip alone.
#
# This supersedes an earlier fit of 0.1121 taken from a Tibber app screenshot of the same day. The
# two disagree by 1.8 ct/kWh excluding VAT and the difference is not explained here; VRM is what this
# house actually reports, so VRM wins.
const TIBBER_ADDITIVE = 0.13002      # EUR/kWh excluding VAT
const ENERGY_TAX = 0.0989            # nominal split
const MARKUP = TIBBER_ADDITIVE - ENERGY_TAX

# The sell price *tracks the day-ahead price* — it is not a fixed feed-in tariff. This matters more
# than the constant does: at a flat 0.04 the battery can never earn anything by exporting into the
# evening peak, and every kWh it holds is worth only what it displaces. Spot-linked, the same kWh is
# worth 0.29 at 20:00, and exporting becomes a strategy rather than a leftover.
const FEED_IN_ADDER = 0.02531        # EUR/kWh on top of the day-ahead price

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
