"""
    Bill

An itemised electricity bill for one simulation, in euros. Positive numbers are costs to the
household, so `total` is what it pays over the period.

# Fields

  - `commodity_cost`: energy charge on imported kWh, excluding tax and VAT.
  - `netting_credit`: value of exported kWh absorbed by annual netting, credited at the market price
    of the interval they were exported in.
  - `feed_in_revenue`: payment for exported kWh *beyond* netting, at the feed-in rate.
  - `energy_tax`: *energiebelasting* on net consumption, excluding VAT.
  - `tax_credit`: *vermindering energiebelasting*, a negative-signed cost.
  - `transport_cost`: network charges, fixed plus any per-kWh component, excluding VAT.
  - `fixed_cost`: supplier standing charge and feed-in fee, excluding VAT.
  - `vat`: VAT charged on everything above.
  - `total`: the sum.
  - `imported_kwh`, `exported_kwh`, `netted_kwh`: the volumes the bill was computed from.
  - `years`: length of the settled period in years, used to prorate the annual fixed items.
"""
Base.@kwdef struct Bill
    commodity_cost::Float64
    netting_credit::Float64
    feed_in_revenue::Float64
    energy_tax::Float64
    tax_credit::Float64
    transport_cost::Float64
    fixed_cost::Float64
    vat::Float64
    total::Float64
    imported_kwh::Float64
    exported_kwh::Float64
    netted_kwh::Float64
    years::Float64
end

"""
    settle(result::SimulationResult, contract::Contract) -> Bill

Bill the simulated flows.

This is where Dutch regulation lives, deliberately outside the optimizer. Annual netting
(*salderen*) is a constraint on the *year*, not on any 48-hour window, so a receding-horizon
objective structurally cannot represent it. Keeping settlement here also means the four headline
scenarios — netting on or off, fixed or time-varying transport tariff — are four
[`Contract`](@ref) values rather than four code paths.

# Netting model

Exported energy is netted against imported energy up to
`contract.net_metering_fraction × min(import, export)`. The netted share of each exported kWh is
credited at the commodity price of the interval it was exported in; the remainder is paid at the
feed-in rate. Energy tax is charged on consumption net of the netted volume. Fixed items — the tax
credit, standing charge, capacity tariff — are prorated to the length of the simulated period, so a
one-week run is not billed a full year of standing charges.
"""
function settle(result::SimulationResult, contract::Contract)
    grid = result.grid
    dt = hours(grid)
    frame = result.frame
    checkseries(grid, contract.commodity, "contract.commodity")

    import_kwh = frame.import_kw .* dt
    export_kwh = frame.export_kw .* dt
    total_import = sum(import_kwh)
    total_export = sum(export_kwh)

    netted = min(total_import, total_export) * contract.net_metering_fraction
    share = total_export > 0 ? netted / total_export : 0.0

    commodity_cost = sum(contract.commodity .* import_kwh)
    netting_credit = share * sum(contract.commodity .* export_kwh)
    feed_in_revenue = (1 - share) * sum(contract.feed_in .* export_kwh)

    energy_tax = contract.energy_tax * max(0.0, total_import - netted)

    transport =
        sum(grid_import_price(contract.grid, grid.n) .* import_kwh) +
        sum(grid_export_price(contract.grid, grid.n) .* export_kwh)

    years = grid.n * dt / 8760
    transport_cost = transport + years * fixed_grid_cost(contract.grid)
    tax_credit = -years * contract.tax_credit
    fixed_cost =
        years * (contract.standing_charge + (total_export > 0 ? contract.feed_in_fee : 0.0))

    taxable =
        commodity_cost - netting_credit +
        energy_tax +
        tax_credit +
        transport_cost +
        fixed_cost - (contract.feed_in_vat ? feed_in_revenue : 0.0)
    vat = contract.vat * taxable
    total = taxable + vat - (contract.feed_in_vat ? 0.0 : feed_in_revenue)

    return Bill(;
        commodity_cost,
        netting_credit,
        feed_in_revenue,
        energy_tax,
        tax_credit,
        transport_cost,
        fixed_cost,
        vat,
        total,
        imported_kwh = total_import,
        exported_kwh = total_export,
        netted_kwh = netted,
        years,
    )
end

"""
    annualise(bill::Bill) -> Float64

The bill's total scaled to a full year. A simulation of a representative week can then be compared
against an annual investment cost, with the obvious caveat that a week is not a year.
"""
annualise(bill::Bill) = bill.years > 0 ? bill.total / bill.years : NaN
