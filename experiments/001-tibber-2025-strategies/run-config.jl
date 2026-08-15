# Every input to experiment 001, in one place, so `run.jl` and `explore.jl` cannot drift apart.
# If a number matters to the answer it is here, not buried in a default.

using HEMSSimulator
using Dates

const SITE = Site(52.1, 5.18)                       # Utrecht
const YEAR = TimeGrid(DateTime(2025, 1, 1), DateTime(2026, 1, 1))

# Read off Tibber's own itemised price table for 2026-08-15, which breaks a consumer kWh into its
# four parts — so these are not fitted constants, they are the supplier's own line items:
#
#     Marktprijs   Inkoopverg.   Energiebel.   BTW      Totaal
#     0.1777       0.0205        0.0916        0.0609   0.3507   (local 00:00)
#
#     import = (Marktprijs + 0.0205 + 0.0916) * 1.21
#
# Checked against all 24 quarter-hours of the table: the model reproduces both the BTW and the Totaal
# columns to 4.8e-5 EUR/kWh, which is the rounding of a four-decimal display.
#
# Two things this settles that a fit could not:
#
#   - **Marktprijs is the raw ENTSO-E day-ahead price.** Fetched for the same quarter-hours, the two
#     agree to 4e-5 EUR/kWh across all 24 — again display rounding. No supplier index, no smoothing.
#   - **Local time is CEST, +2 on the UTC this package works in.** Confirmed on every quarter-hour.
#     Compare without shifting and the alignment is out by two hours, which reads as noise rather
#     than as an error.
#
# An earlier calibration here used 0.1300 taken from a Victron VRM panel. That was a *different
# supplier* — the two are not reconcilable and should not have been compared.
const MARKUP = 0.0205                # inkoopvergoeding, EUR/kWh excluding VAT
const ENERGY_TAX = 0.0916            # energiebelasting, EUR/kWh excluding VAT
const TIBBER_ADDITIVE = MARKUP + ENERGY_TAX

# With netting off, energiebelasting and BTW are charged on every imported kWh and refunded on none,
# so an exported kWh is worth the commodity price alone — `Marktprijs + Inkoopverg.`, no tax, no VAT.
# That is the whole of the import/export spread: 0.35 against 0.20 at midnight on the table above.
#
# The consequence for a battery is the point of the study. The sell price is *spot-linked*, so a kWh
# held until the evening peak is worth what the evening peak pays; but it is also always below the
# buy price by tax and VAT, so a round trip through the grid can never pay for itself. Storing to
# self-consume and storing to export are both worth doing, and buying to export never is.
feed_in_price(prices) = prices .+ MARKUP

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

# One definition for both `run.jl` and `explore.jl`, so the sweep's NPV and the dashboard's NPV card
# cannot quietly disagree.
const INVESTMENT =
    b -> Investment(
        capex = CAPEX(b.capacity_kwh),
        lifetime_years = LIFETIME_YEARS,
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
