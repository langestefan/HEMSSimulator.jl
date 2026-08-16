# What a kWh costs and what a kWh earns, on a Dutch dynamic tariff, without net metering.
#
# Shared by every study in this directory, so two studies cannot quietly price the same electricity
# differently and then be compared.
#
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
# An earlier calibration used 0.1300 taken from a Victron VRM panel. That was a *different supplier*
# — the two are not reconcilable and should not have been compared.
const MARKUP = 0.0205                # inkoopvergoeding, EUR/kWh excluding VAT
const ENERGY_TAX = 0.0916            # energiebelasting, EUR/kWh excluding VAT
const TIBBER_ADDITIVE = MARKUP + ENERGY_TAX

# With netting off, energiebelasting and BTW are charged on every imported kWh and refunded on none,
# so an exported kWh is worth the commodity price alone — `Marktprijs + Inkoopverg.`, no tax, no VAT.
# That is the whole of the import/export spread: 0.35 against 0.20 at midnight on the table above.
#
# The consequence for a battery is the point of these studies. The sell price is *spot-linked*, so a
# kWh held until the evening peak is worth what the evening peak pays; but it is also always below
# the buy price by tax and VAT, so a round trip through the grid can never pay for itself. Storing to
# self-consume and storing to export are both worth doing, and buying to export never is.
feed_in_price(prices) = prices .+ MARKUP

"""
    tibber_contract(grid, prices) -> Contract

No net metering, flat capacity tariff — the regime the Netherlands is moving to, and the one the
calibration above was read under. Both prices are spot-linked and the sell price is a series rather
than a constant, which is what makes exporting into the evening peak worth doing.
"""
tibber_contract(grid, prices) = Contract(
    grid;
    commodity = prices .+ MARKUP,
    feed_in = feed_in_price(prices),
    energy_tax = ENERGY_TAX,
    net_metering_fraction = 0.0,
    grid = FixedCapacityTariff(),
)
