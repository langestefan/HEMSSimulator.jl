"""
    AbstractGridTariff

Supertype for network operator charges. Concrete types are [`FixedCapacityTariff`](@ref) — today's
Dutch *capaciteitstarief*, a flat annual fee that no amount of load shifting reduces — and
[`TimeVaryingGridTariff`](@ref), the time-of-use transport tariff being trialled as a congestion
signal. Switching between them is a configuration change, not a code path.
"""
abstract type AbstractGridTariff end

"""
    FixedCapacityTariff(; annual_eur = 400.0)

Flat annual network charge in euros, excluding VAT, set by the connection size rather than by
consumption. The default is representative of a 3×25 A residential connection.
"""
Base.@kwdef struct FixedCapacityTariff <: AbstractGridTariff
    annual_eur::Float64 = 400.0
end

"""
    TimeVaryingGridTariff(; import_eur_per_kwh, export_eur_per_kwh, annual_eur = 0.0)

A transport tariff with a per-kWh component that varies by interval, plus an optional residual fixed
part. Both per-kWh series are excluding VAT and have one element per interval of the simulation
horizon.
"""
Base.@kwdef struct TimeVaryingGridTariff <: AbstractGridTariff
    import_eur_per_kwh::Vector{Float64}
    export_eur_per_kwh::Vector{Float64} = zeros(length(import_eur_per_kwh))
    annual_eur::Float64 = 0.0
end

"""
    grid_import_price(tariff, n) -> Vector{Float64}

Per-interval variable network charge on imported energy, €/kWh excluding VAT.
"""
grid_import_price(::FixedCapacityTariff, n::Integer) = zeros(Float64, n)
grid_import_price(tariff::TimeVaryingGridTariff, ::Integer) = tariff.import_eur_per_kwh

"""
    grid_export_price(tariff, n) -> Vector{Float64}

Per-interval variable network charge on exported energy, €/kWh excluding VAT.
"""
grid_export_price(::FixedCapacityTariff, n::Integer) = zeros(Float64, n)
grid_export_price(tariff::TimeVaryingGridTariff, ::Integer) = tariff.export_eur_per_kwh

"""
    fixed_grid_cost(tariff) -> Float64

Annual fixed network charge in euros, excluding VAT.
"""
fixed_grid_cost(tariff::FixedCapacityTariff) = tariff.annual_eur
fixed_grid_cost(tariff::TimeVaryingGridTariff) = tariff.annual_eur

"""
    Contract(; commodity, feed_in, kwargs...)

A Dutch electricity supply contract, as seen by a household. This is the input to the settlement
engine; it is deliberately separate from the dispatch model, because annual netting couples the
whole year and cannot be expressed in a receding-horizon objective.

# Fields

  - `commodity::Vector{Float64}`: energy price excluding tax and VAT, €/kWh per interval. A fixed
    contract is a constant vector; a dynamic contract is the day-ahead price plus a supplier markup.
  - `feed_in::Vector{Float64}`: *terugleververgoeding*, €/kWh paid for exported energy that is not
    netted.
  - `energy_tax::Float64`: *energiebelasting*, €/kWh excluding VAT. The ODE surcharge was folded
    into this levy in 2023, so it is a single number.
  - `tax_credit::Float64`: *vermindering energiebelasting*, a fixed annual credit in euros
    excluding VAT.
  - `vat::Float64`: VAT rate applied to everything a household pays.
  - `feed_in_vat::Bool`: whether the feed-in compensation is paid including VAT. Usually `false`.
  - `net_metering_fraction::Float64`: fraction of exported energy eligible for annual netting.
    `1.0` is full *salderen*, `0.0` is its abolition, and values in between express a phase-out
    year. This is a parameter, not a hardcoded schedule.
  - `standing_charge::Float64`: supplier fixed fee, €/year excluding VAT.
  - `feed_in_fee::Float64`: *terugleverkosten*, €/year excluding VAT, charged by some suppliers to
    customers who export.
  - `grid::AbstractGridTariff`: network charges.

The physical connection limit is a property of the home, not the contract; it lives on
[`HomeSystem`](@ref).
"""
Base.@kwdef struct Contract{G<:AbstractGridTariff}
    commodity::Vector{Float64}
    feed_in::Vector{Float64}
    energy_tax::Float64 = 0.1088
    tax_credit::Float64 = 524.95
    vat::Float64 = 0.21
    feed_in_vat::Bool = false
    net_metering_fraction::Float64 = 1.0
    standing_charge::Float64 = 0.0
    feed_in_fee::Float64 = 0.0
    grid::G = FixedCapacityTariff()
end

"""
    Contract(grid::TimeGrid; commodity, feed_in, kwargs...)

Convenience constructor accepting scalars for `commodity` and `feed_in`, expanded to the grid.
"""
function Contract(grid::TimeGrid; commodity, feed_in, kwargs...)
    expand(x) = x isa Real ? fill(float(x), grid.n) : collect(Float64, x)
    return Contract(; commodity = expand(commodity), feed_in = expand(feed_in), kwargs...)
end

"""
    retail_price(contract::Contract) -> Vector{Float64}

All-in price of one imported kWh, €/kWh including energy tax, variable network charges and VAT.
This is what a netted kWh is worth.
"""
function retail_price(contract::Contract)
    n = length(contract.commodity)
    transport = grid_import_price(contract.grid, n)
    return @. (contract.commodity + contract.energy_tax + transport) * (1 + contract.vat)
end

"""
    export_price(contract::Contract) -> Vector{Float64}

Value of one exported kWh *beyond* what annual netting absorbs, €/kWh.
"""
function export_price(contract::Contract)
    n = length(contract.feed_in)
    transport = grid_export_price(contract.grid, n)
    vat = contract.feed_in_vat ? (1 + contract.vat) : 1.0
    return @. contract.feed_in * vat - transport * (1 + contract.vat)
end

"""
    dispatch_prices(contract::Contract, options::RunOptions) -> (buy, sell)

The marginal price signal the controller optimizes against, €/kWh per interval.

Import is valued at the full retail price. Export is valued at a blend of the retail price and the
feed-in price weighted by `net_metering_fraction`: under full netting an exported kWh really is
worth a retail kWh, so a controller that ignored netting would self-consume when it should not.

`options.price_epsilon` is subtracted from the sell price. Under full netting buy and sell prices
are otherwise identical, which makes simultaneous import and export cost-neutral and lets the solver
return an arbitrary split of a degenerate optimum. The nudge costs nothing in accuracy — the
settlement engine, not this objective, produces the reported bill.
"""
function dispatch_prices(contract::Contract, options::RunOptions)
    buy = retail_price(contract)
    surplus = export_price(contract)
    f = contract.net_metering_fraction
    sell = @. f * buy + (1 - f) * surplus - options.price_epsilon
    return buy, sell
end
