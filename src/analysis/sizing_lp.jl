"""
    capital_recovery_factor(rate, years) -> Float64

The annuity factor turning a lump-sum capital cost into an equal annual payment over `years` at
discount rate `rate`. At a zero rate it degenerates to `1 / years`.
"""
function capital_recovery_factor(rate::Real, years::Integer)
    years > 0 || throw(ArgumentError("years must be positive, got $years"))
    rate == 0 && return 1 / years
    return rate / (1 - (1 + rate)^(-years))
end

"""
    size_lp(system, inputs, contract; kwargs...) -> NamedTuple

Solve for battery capacity and power as **continuous decision variables** in one linear program over
the whole horizon, minimising annualised capital cost plus energy cost.

This is an upper bound, not an answer, and the gap between it and [`sweep`](@ref) is the point of
having both. It is optimistic in three specific ways:

 1. **Perfect foresight over the entire horizon**, not 48 hours. A year of prices known in advance
    is worth real money that no controller can capture.
 2. **The linear dispatch price, not the bill.** Annual netting couples all 35 040 intervals and
    cannot be written into this objective — the same reason [`settle`](@ref) exists. Under
    *salderen* this bound is badly optimistic; without it, closer.
 3. **Continuous sizing.** Batteries come in discrete sizes.

It is a bound only on a like-for-like basis, and there is one trap. `Battery.degradation_cost` is a
*control-shaping* parameter: it appears in the dispatch objective, so it is charged here, but it
never appears in a [`Bill`](@ref), so [`sweep`](@ref)'s savings ignore it. Wear is priced in
[`Investment`](@ref) instead, through `lifetime_years` and `capacity_fade` — charging it twice would
be the error. So leave `template.degradation_cost` at zero when comparing against a sweep. On the
package's own synthetic month the LP returns 5.12 kWh against a sweep optimum of 5.0 with it zero,
and 3.14 kWh with it at 5 ct/kWh.

What it is good for is a fast sanity check on a sweep: if the sweep's optimum sits far below this,
the candidate grid is probably too narrow or the sweep's assumptions differ. Run it first, then
sweep the range it points at.

# Keyword arguments

  - `capex_per_kwh`, `capex_per_kw`, `capex_fixed`: the linear cost model, €. Only a linear one can
    go in the objective; a real quote with volume breaks belongs in [`sweep`](@ref).
  - `c_rate`: power as a multiple of capacity, matching how batteries are actually built and how
    [`sweep`](@ref) constructs its candidates. Set it to `Inf` to size power independently — but
    then price it with `capex_per_kw`, or the LP will take `max_power_kw` for free and answer with
    a tiny, very fast battery that no one sells.
  - `lifetime_years`, `discount_rate`: annualise the capital cost.
  - `max_capacity_kwh`, `max_power_kw`: bounds on the search, so an unbounded problem is impossible.
  - `template::Battery`: where the efficiencies, SoC limits and degradation cost come from. Its
    `capacity_kwh` and power ratings are ignored — those are what is being solved for.
  - `options::RunOptions`: the optimizer factory and `silent`.
"""
function size_lp(
    system::HomeSystem,
    inputs::SimulationInputs,
    contract::Contract;
    capex_per_kwh::Real = 450.0,
    capex_per_kw::Real = 0.0,
    capex_fixed::Real = 1000.0,
    lifetime_years::Integer = 15,
    discount_rate::Real = 0.04,
    max_capacity_kwh::Real = 100.0,
    max_power_kw::Real = 50.0,
    c_rate::Real = 0.5,
    template::Battery = Battery(1.0, 1.0),
    options::RunOptions = RunOptions(),
)
    grid = inputs.grid
    n = grid.n
    dt = hours(grid)
    years = n * dt / 8760
    isempty(system.assets) || throw(
        ArgumentError(
            "size_lp sizes the only storage in the system, but `system` already has " *
            "$(length(system.assets)) asset(s). Pass a home with no assets.",
        ),
    )

    model = Model(options.optimizer)
    options.silent && set_silent(model)

    capacity = @variable(model, lower_bound = 0, upper_bound = max_capacity_kwh)
    power = @variable(model, lower_bound = 0, upper_bound = max_power_kw)
    charge = @variable(model, [1:n], lower_bound = 0)
    discharge = @variable(model, [1:n], lower_bound = 0)
    energy = @variable(model, [1:n], lower_bound = 0)
    limit = system.connection_kw
    imported = @variable(model, [1:n], lower_bound = 0, upper_bound = limit)
    exported = @variable(model, [1:n], lower_bound = 0, upper_bound = limit)
    curtail = @variable(model, [k = 1:n], lower_bound = 0, upper_bound = inputs.pv_kw[k])

    @constraint(model, [k = 1:n], charge[k] <= power)
    @constraint(model, [k = 1:n], discharge[k] <= power)
    isfinite(c_rate) && @constraint(model, power <= c_rate * capacity)
    @constraint(model, [k = 1:n], energy[k] >= template.soc_min * capacity)
    @constraint(model, [k = 1:n], energy[k] <= template.soc_max * capacity)

    loss(k) = dt * template.self_discharge * capacity
    gain(k) =
        dt * (
            template.charge_efficiency * charge[k] -
            discharge[k] / template.discharge_efficiency
        )
    # The horizon is cyclic: the battery must end where it started, so the bound cannot be inflated
    # by selling a full battery's worth of energy on the last day and never buying it back.
    @constraint(model, energy[1] == energy[n] + gain(1) - loss(1))
    @constraint(model, [k = 2:n], energy[k] == energy[k-1] + gain(k) - loss(k))

    @constraint(
        model,
        [k = 1:n],
        imported[k] - exported[k] + inputs.pv_kw[k] - curtail[k] + discharge[k] ==
        inputs.load_kw[k] + charge[k]
    )

    objective = AffExpr(0.0)
    for k = 1:n
        add_to_expression!(objective, dt * inputs.price_buy[k], imported[k])
        add_to_expression!(objective, -dt * inputs.price_sell[k], exported[k])
        if template.degradation_cost > 0
            add_to_expression!(
                objective,
                dt * template.degradation_cost,
                charge[k] + discharge[k],
            )
        end
    end
    crf = capital_recovery_factor(discount_rate, lifetime_years)
    # Capital is annualised, then prorated to the simulated period so it is comparable with the
    # energy cost of that period rather than of a year.
    add_to_expression!(objective, years * crf * capex_per_kwh, capacity)
    add_to_expression!(objective, years * crf * capex_per_kw, power)
    objective += years * crf * capex_fixed

    @objective(model, Min, objective)
    optimize!(model)
    is_solved_and_feasible(model) ||
        error("the sizing LP did not solve: $(termination_status(model))")

    sized = value(capacity)
    rated = value(power)
    return (;
        capacity_kwh = sized,
        power_kw = rated,
        annual_cost = objective_value(model) / years,
        capex = capex_fixed + capex_per_kwh * sized + capex_per_kw * rated,
        at_bound = sized >= max_capacity_kwh - 1e-6 || rated >= max_power_kw - 1e-6,
    )
end

"""
    size_lp(system, weather, load_kw, contract; kwargs...)

Convenience form that calls [`prepare`](@ref) first.
"""
function size_lp(
    system::HomeSystem,
    weather::Weather,
    load_kw::AbstractVector,
    contract::Contract;
    options::RunOptions = RunOptions(),
    kwargs...,
)
    inputs = prepare(system, weather, load_kw, contract; options)
    return size_lp(system, inputs, contract; options, kwargs...)
end
