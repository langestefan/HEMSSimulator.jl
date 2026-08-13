"""
    Investment(; capex, kwargs...)

The financial side of a battery (or any other asset) whose business case is being tested.

# Fields

  - `capex::Float64`: installed cost in euros, paid at year zero.
  - `opex_per_year::Float64`: recurring cost in euros per year.
  - `lifetime_years::Int`: analysis horizon.
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
    discount_rate::Float64 = 0.04
    capacity_fade::Float64 = 0.02
    savings_escalation::Float64 = 0.0
    residual_value::Float64 = 0.0
end

"""
    cashflows(annual_savings, investment::Investment) -> Vector{Float64}

Nominal cash flows by year, starting at year zero. Year zero is `-capex`; each later year is the
saving, faded and escalated, less operating cost. The residual value lands in the final year.
"""
function cashflows(annual_savings::Real, inv::Investment)
    flows = zeros(Float64, inv.lifetime_years + 1)
    flows[1] = -inv.capex
    for year = 1:inv.lifetime_years
        saving =
            annual_savings *
            (1 - inv.capacity_fade)^(year - 1) *
            (1 + inv.savings_escalation)^(year - 1)
        flows[year+1] = saving - inv.opex_per_year
    end
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

Returns `annual_savings`, `npv`, `irr`, `payback_years`, and — when a [`SimulationResult`](@ref) is
passed — `self_consumption`, `self_sufficiency` and `cycles_per_year`.
"""
function kpis(baseline::Bill, case::Bill, investment::Investment; result = nothing)
    annual_savings = annualise(baseline) - annualise(case)
    flows = cashflows(annual_savings, investment)
    base = (;
        annual_savings,
        npv = npv(flows, investment.discount_rate),
        irr = irr(flows),
        payback_years = payback(flows),
    )
    result === nothing && return base
    return merge(
        base,
        (;
            self_consumption = self_consumption(result),
            self_sufficiency = self_sufficiency(result),
            cycles_per_year = cycles_per_year(result),
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
