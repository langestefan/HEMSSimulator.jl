"""
    peak_intervals(grid::TimeGrid; hours = 16:20, weekdays_only = true) -> BitVector

Which intervals of `grid` fall in the network peak. `hours` is a range of clock hours in the
interval-beginning convention, so `16:20` means 16:00 up to but not including 21:00.

Timestamps in this package are UTC while a Dutch tariff is defined on local clock time. Over a
winter month the two differ by an hour and over a summer month by two, so for a full-year study
convert the boundary yourself rather than accepting the default silently.
"""
function peak_intervals(
    grid::TimeGrid;
    hours::AbstractVector{<:Integer} = 16:20,
    weekdays_only::Bool = true,
)
    return BitVector(
        Dates.hour(t) in hours && !(weekdays_only && isweekend(t)) for t in timestamps(grid)
    )
end

"""
    peak_transport_tariff(grid::TimeGrid; kwargs...) -> TimeVaryingGridTariff

A two-block time-of-use transport tariff: one €/kWh rate inside the network peak, another outside.

This is the shape Dutch network operators are trialling as a congestion signal, and it is the second
axis of the four headline scenarios. Whether it helps or hurts a household depends entirely on the
levels, which is why every one of them is a keyword — there is no national tariff to hard-code, and
the numbers below are illustrative.

# Keyword arguments

  - `peak_eur_per_kwh`, `offpeak_eur_per_kwh`: import charge, excluding VAT.
  - `export_peak_eur_per_kwh`, `export_offpeak_eur_per_kwh`: charge on export, excluding VAT. Zero
    by default; set them to model a feed-in transport charge.
  - `annual_eur`: residual fixed component, excluding VAT. A real time-of-use proposal keeps some of
    the capacity tariff rather than replacing all of it.
  - `hours`, `weekdays_only`: passed to [`peak_intervals`](@ref).
"""
function peak_transport_tariff(
    grid::TimeGrid;
    peak_eur_per_kwh::Real = 0.06,
    offpeak_eur_per_kwh::Real = 0.01,
    export_peak_eur_per_kwh::Real = 0.0,
    export_offpeak_eur_per_kwh::Real = 0.0,
    annual_eur::Real = NL_TARIFFS_2025.capacity_tariff / 2,
    hours::AbstractVector{<:Integer} = 16:20,
    weekdays_only::Bool = true,
)
    peak = peak_intervals(grid; hours, weekdays_only)
    block(on, off) = [p ? float(on) : float(off) for p in peak]
    return TimeVaryingGridTariff(;
        import_eur_per_kwh = block(peak_eur_per_kwh, offpeak_eur_per_kwh),
        export_eur_per_kwh = block(export_peak_eur_per_kwh, export_offpeak_eur_per_kwh),
        annual_eur = float(annual_eur),
    )
end

"""
    SCENARIO_NAMES

The four headline regulatory scenarios, in the order [`scenarios`](@ref) returns them:
`:netting_fixed`, `:netting_variable`, `:no_netting_fixed`, `:no_netting_variable`.

The two axes are the two policy questions a Dutch household faces at once — whether annual netting
(*salderen*) still applies, and whether transport is billed as a flat capacity charge or by time of
use.

They are not two versions of the same lever. Netting absorbs the commodity price and the energy tax;
transport is charged on *physical* flow and is never netted (see [`settle`](@ref)). So a time-of-use
tariff pays a battery in both netting regimes — every avoided peak-hour import avoids its transport
charge either way — while ending netting changes what an exported kWh is worth at all. On the
package's own synthetic fortnight the two effects are roughly +20% and +65% on annual savings
respectively, and they compound: `:no_netting_variable` is the cell where storage looks best.
"""
const SCENARIO_NAMES =
    (:netting_fixed, :netting_variable, :no_netting_fixed, :no_netting_variable)

"""
    scenarios(grid::TimeGrid; commodity, feed_in, kwargs...) -> NamedTuple

Build the four headline [`Contract`](@ref)s named in [`SCENARIO_NAMES`](@ref) from one set of prices.

```julia
regimes = scenarios(grid; commodity = prices .+ 0.02, feed_in = 0.04)
settle(result, regimes.no_netting_fixed)
```

There is no `if` anywhere in the settlement engine for any of this: netting is the scalar
`net_metering_fraction` and transport is a type. The four scenarios are four values, which is what
makes a scenario × size study a `vcat` rather than a fork.

# Keyword arguments

  - `commodity`, `feed_in`: as on [`Contract`](@ref); scalars are expanded to the grid.
  - `netting_fraction`: what "netting on" means. `1.0` is full *salderen*; an intermediate value
    expresses a phase-out year, so a ramp is a sweep over this number rather than a fifth scenario.
  - `fixed_tariff`, `variable_tariff`: the two transport tariffs forming the second axis.
  - everything else is forwarded to `Contract`, so `energy_tax`, `vat`, `standing_charge`,
    `feed_in_fee` and the rest are set once and apply to all four.
"""
function scenarios(
    grid::TimeGrid;
    commodity,
    feed_in,
    netting_fraction::Real = 1.0,
    fixed_tariff::AbstractGridTariff = FixedCapacityTariff(),
    variable_tariff::AbstractGridTariff = peak_transport_tariff(grid),
    kwargs...,
)
    0 <= netting_fraction <= 1 || throw(
        ArgumentError("netting_fraction must be in [0, 1], got $netting_fraction"),
    )
    build(fraction, tariff) = Contract(
        grid;
        commodity,
        feed_in,
        net_metering_fraction = float(fraction),
        grid = tariff,
        kwargs...,
    )
    return (;
        netting_fixed = build(netting_fraction, fixed_tariff),
        netting_variable = build(netting_fraction, variable_tariff),
        no_netting_fixed = build(0.0, fixed_tariff),
        no_netting_variable = build(0.0, variable_tariff),
    )
end
