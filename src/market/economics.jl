"""
    Investment(; capex, kwargs...)

The financial side of a battery (or any other asset) whose business case is being tested.

# Fields

  - `capex::Float64`: installed cost in euros, paid at year zero.
  - `opex_per_year::Float64`: recurring cost in euros per year.
  - `lifetime_years::Int`: calendar life, and the analysis horizon when nothing else binds.
  - `rated_cycles::Float64`: full-equivalent cycles the asset is warranted for. `Inf` (the default)
    means only the calendar matters. Set it and the horizon becomes whichever of the two runs out
    first — see [`effective_lifetime`](@ref).
  - `discount_rate::Float64`: annual real discount rate.
  - `capacity_fade::Float64`: annual fraction by which the achievable saving shrinks as the battery
    ages. A crude but honest stand-in for degradation at the business-case level.
  - `savings_escalation::Float64`: annual real growth of energy prices, which grows the saving.
  - `residual_value::Float64`: value recovered in the final year, euros.
"""
Base.@kwdef struct Investment
    capex::Float64
    opex_per_year::Float64 = 0.0
    lifetime_years::Int = 15
    rated_cycles::Float64 = Inf
    discount_rate::Float64 = 0.04
    capacity_fade::Float64 = 0.02
    savings_escalation::Float64 = 0.0
    residual_value::Float64 = 0.0
end

"""
    effective_lifetime(inv::Investment, cycles_per_year) -> Float64

How long the asset actually lasts: the shorter of its calendar life and the time it takes to spend
`rated_cycles` at `cycles_per_year`.

A battery that is worked harder wears out sooner, and in a sizing sweep the small candidates are
worked hardest — they cycle more times per kWh installed than the large ones, because the surplus
they are storing is the same either way. Holding the horizon fixed at `lifetime_years` therefore
flatters exactly the candidates that will need replacing first.

`cycles_per_year` may be `nothing` or `NaN` (no battery, or nothing measured), in which case only the
calendar applies. So does an `Inf` `rated_cycles`, which is the default — this refinement is opt-in,
and a study that does not set a cycle rating gets the behaviour it had before.

```jldoctest
julia> inv = Investment(capex = 2400.0, lifetime_years = 15, rated_cycles = 4000.0);

julia> round(effective_lifetime(inv, 334.1); digits = 2)     # cycled hard: wears out first
11.97

julia> effective_lifetime(inv, 228.6)                        # cycled gently: calendar binds
15.0
```
"""
function effective_lifetime(inv::Investment, cycles_per_year)
    calendar = float(inv.lifetime_years)
    isfinite(inv.rated_cycles) || return calendar
    cycles_per_year === nothing && return calendar
    (isnan(cycles_per_year) || cycles_per_year <= 0) && return calendar
    return min(calendar, inv.rated_cycles / cycles_per_year)
end

"""
    cashflows(annual_savings, investment::Investment; cycles_per_year = nothing) -> Vector{Float64}

Nominal cash flows by year, starting at year zero. Year zero is `-capex`; each later year is the
saving, faded and escalated, less operating cost. The residual value lands in the final year.

`cycles_per_year` shortens the horizon when the asset wears out before its calendar life; see
[`effective_lifetime`](@ref). A part-year at the end is **pro-rated** rather than rounded, so that a
life of 12.99 and one of 13.01 years do not differ by a whole year of savings.
"""
function cashflows(annual_savings::Real, inv::Investment; cycles_per_year = nothing)
    life = effective_lifetime(inv, cycles_per_year)
    whole = floor(Int, life)
    part = life - whole
    yearly(year) =
        annual_savings *
        (1 - inv.capacity_fade)^(year - 1) *
        (1 + inv.savings_escalation)^(year - 1) - inv.opex_per_year
    flows = zeros(Float64, whole + (part > 0 ? 2 : 1))
    flows[1] = -inv.capex
    for year = 1:whole
        flows[year+1] = yearly(year)
    end
    part > 0 && (flows[end] = part * yearly(whole + 1))
    flows[end] += inv.residual_value
    return flows
end

"""
    npv(flows, rate) -> Float64

Net present value of a cash flow vector whose first element is at year zero.
"""
npv(flows::AbstractVector, rate::Real) =
    sum(cf / (1 + rate)^(t - 1) for (t, cf) in enumerate(flows))

"""
    irr(flows; tol = 1e-8, bounds = (-0.99, 10.0)) -> Float64

Internal rate of return by bisection, or `NaN` when the cash flows never cross zero within `bounds`
— which is the honest answer for an investment that never pays back.
"""
function irr(
    flows::AbstractVector;
    tol::Real = 1.0e-8,
    bounds::Tuple{Real,Real} = (-0.99, 10.0),
)
    low, high = float(bounds[1]), float(bounds[2])
    f_low, f_high = npv(flows, low), npv(flows, high)
    sign(f_low) == sign(f_high) && return NaN
    for _ = 1:200
        mid = (low + high) / 2
        f_mid = npv(flows, mid)
        abs(f_mid) < tol && return mid
        if sign(f_mid) == sign(f_low)
            low, f_low = mid, f_mid
        else
            high = mid
        end
    end
    return (low + high) / 2
end

"""
    payback(flows) -> Float64

Simple (undiscounted) payback period in years, interpolated within the year in which cumulative
cash flow turns positive. `Inf` when it never does.
"""
function payback(flows::AbstractVector)
    cumulative = flows[1]
    for year = 2:length(flows)
        previous = cumulative
        cumulative += flows[year]
        if cumulative >= 0
            flows[year] == 0 && return float(year - 1)
            return (year - 2) + (-previous / flows[year])
        end
    end
    return Inf
end

"""
    kpis(baseline::Bill, case::Bill, investment::Investment; result = nothing) -> NamedTuple

The business case for one configuration, measured against a baseline bill (usually the same home
without a battery).

Returns `annual_savings`, `npv`, `irr`, `payback_years`, `lifetime_years` — and, when a
[`SimulationResult`](@ref) is passed — `self_consumption`, `self_sufficiency` and `cycles_per_year`.

`result` is what lets the horizon respond to how hard the asset is worked: without it the cycle
rating has nothing to bite on and the calendar life applies. `lifetime_years` is reported so a table
shows *which* candidates were cycle-limited rather than leaving it to be inferred.
"""
function kpis(baseline::Bill, case::Bill, investment::Investment; result = nothing)
    annual_savings = annualise(baseline) - annualise(case)
    cycles = result === nothing ? nothing : cycles_per_year(result)
    flows = cashflows(annual_savings, investment; cycles_per_year = cycles)
    base = (;
        annual_savings,
        npv = npv(flows, investment.discount_rate),
        irr = irr(flows),
        payback_years = payback(flows),
        lifetime_years = effective_lifetime(investment, cycles),
    )
    result === nothing && return base
    return merge(
        base,
        (;
            self_consumption = self_consumption(result),
            self_sufficiency = self_sufficiency(result),
            cycles_per_year = cycles,
        ),
    )
end

"""
    cycles_per_year(result::SimulationResult) -> Float64

Equivalent full cycles per year: battery discharge energy divided by capacity, annualised. `NaN`
when the system has no battery. This is the number battery warranties are written against.
"""
function cycles_per_year(result::SimulationResult)
    hasproperty(result.frame, :battery_discharge_kw) || return NaN
    batteries = filter(asset -> asset isa Battery, result.system.assets)
    isempty(batteries) && return NaN
    capacity = sum(battery.capacity_kwh for battery in batteries)
    capacity <= 0 && return NaN
    discharged = sum(result.frame.battery_discharge_kw) * hours(result.grid)
    years = result.grid.n * hours(result.grid) / 8760
    return discharged / capacity / years
end
